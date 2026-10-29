import Foundation

/// Процесс распознавания (Resources/worker.py) со своими моделями.
/// В холодном режиме он завершается после простоя — вся память моделей возвращается системе.
final class Engine {
    enum State { case stopped, loading, ready }

    struct EngineError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Папка движка. AIT_HOME переопределяет её (так же понимают install-engine.sh и worker.py).
    static let home = ProcessInfo.processInfo.environment["AIT_HOME"].map { URL(fileURLWithPath: $0) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Ait")
    static let python = home.appendingPathComponent("python/bin/python3")
    static let logFile = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Ait/engine.log")
    /// Python-окружение и обычная модель на месте (их ставит install-engine.sh без параметров).
    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: python.path) && isInstalled(.base)
    }

    static func isInstalled(_ size: ModelSize) -> Bool {
        FileManager.default.fileExists(atPath: home.appendingPathComponent("models/\(size.weightsFile)").path)
    }

    var onStateChange: ((State) -> Void)?
    private(set) var state: State = .stopped {
        didSet { if oldValue != state { onStateChange?(state) } }
    }

    private let settings = Settings.shared
    private var process: Process?
    private var input: FileHandle?
    private var buffer = Data()
    private var nextId = 1
    private var waiting: [Int: (Result<String, Error>) -> Void] = [:]
    private var unloadTimer: Timer?

    /// Запускает процесс и сразу грузит модель. Вызывается в момент нажатия клавиши,
    /// так что модель успевает загрузиться, пока ты говоришь.
    func warmUp() {
        unloadTimer?.invalidate()
        guard process == nil, Engine.isInstalled,
              let script = Bundle.main.url(forResource: "worker", withExtension: "py") else { return }

        let process = Process()
        process.executableURL = Engine.python
        process.arguments = ["-u", script.path]
        var env = ProcessInfo.processInfo.environment
        env["HF_HUB_OFFLINE"] = "1"
        env["PYTHONNOUSERSITE"] = "1"
        process.environment = env

        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = Engine.openLog()
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            DispatchQueue.main.async { self?.receive(chunk) }
        }
        process.terminationHandler = { [weak self, weak process] _ in
            DispatchQueue.main.async {
                guard let self, let process, process === self.process else { return }
                self.process = nil
                self.input = nil
                self.failAll("Движок распознавания завершился с ошибкой — подробности в журнале")
                self.state = .stopped
            }
        }

        do {
            try process.run()
        } catch {
            Engine.log("не удалось запустить движок: \(error)")
            return
        }
        self.process = process
        input = stdin.fileHandleForWriting
        state = .loading
        request(["cmd": "load", "model": settings.model.rawValue, "punct": settings.punctuation]) { [weak self] result in
            if case .success = result, self?.process != nil { self?.state = .ready }
        }
    }

    func transcribe(_ wav: URL, completion: @escaping (Result<String, Error>) -> Void) {
        warmUp()
        guard process != nil else {
            completion(.failure(EngineError(message: "движок распознавания не установлен")))
            return
        }
        request(["cmd": "transcribe", "path": wav.path, "model": settings.model.rawValue,
                 "punct": settings.punctuation]) { [weak self] result in
            completion(result)
            self?.scheduleUnload()
        }
    }

    /// Применяет настройки. restart — перезапустить процесс (сменили модель или пунктуацию).
    func applySettings(restart: Bool) {
        if restart || !settings.enabled { stop() }
        guard settings.enabled else { return }
        if settings.startMode == .hot {
            warmUp()
        } else {
            scheduleUnload()
        }
    }

    func stop() {
        unloadTimer?.invalidate()
        guard let process else { return }
        self.process = nil
        send(["cmd": "quit"])
        input = nil
        process.terminate()
        failAll("движок остановлен")
        state = .stopped
    }

    // MARK: - Протокол

    private func request(_ payload: [String: Any], completion: @escaping (Result<String, Error>) -> Void) {
        let id = nextId
        nextId += 1
        waiting[id] = completion
        var message = payload
        message["id"] = id
        send(message)
    }

    private func send(_ payload: [String: Any]) {
        guard let input, var data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        data.append(0x0A)
        do {
            try input.write(contentsOf: data)
        } catch {
            Engine.log("не удалось отправить команду: \(error)")
        }
    }

    private func receive(_ chunk: Data) {
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let json = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = json["id"] as? Int, let completion = waiting.removeValue(forKey: id) else { continue }
            switch json["event"] as? String {
            case "error":
                let message = json["message"] as? String ?? "неизвестная ошибка"
                Engine.log("ошибка движка: \(message)")
                completion(.failure(EngineError(message: message)))
            default:
                completion(.success(json["text"] as? String ?? ""))
            }
        }
    }

    private func failAll(_ message: String) {
        let pending = waiting
        waiting.removeAll()
        pending.values.forEach { $0(.failure(EngineError(message: message))) }
    }

    private func scheduleUnload() {
        unloadTimer?.invalidate()
        guard settings.startMode == .cold, process != nil else { return }
        let delay = max(TimeInterval(settings.unloadMinutes * 60), 1)
        unloadTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self, self.waiting.isEmpty else { return }
            self.stop()
        }
    }

    // MARK: - Журнал

    static func openLog() -> FileHandle {
        let fm = FileManager.default
        try? fm.createDirectory(at: logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = try? fm.attributesOfItem(atPath: logFile.path)[.size] as? Int, size > 1_000_000 {
            try? fm.removeItem(at: logFile)
        }
        if !fm.fileExists(atPath: logFile.path) { fm.createFile(atPath: logFile.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: logFile) else { return .nullDevice }
        handle.seekToEndOfFile()
        return handle
    }

    static func log(_ message: String) {
        let handle = openLog()
        handle.write(Data("[\(Date())] \(message)\n".utf8))
        try? handle.close()
    }
}
