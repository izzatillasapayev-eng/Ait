import Foundation

/// Запускает встроенный Resources/install-engine.sh и пересказывает его прогресс.
/// Скрипт ставит Python-окружение и модели в ~/Library/Application Support/Ait.
final class EngineInstaller {
    struct InstallError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private(set) var isRunning = false
    private(set) var status = ""
    var onProgress: ((Int, String) -> Void)?

    private var buffer = Data()
    private var lastError: String?

    /// arguments: [] — обычная модель, пунктуация и VAD; ["--model", "large"] — GigaAM Large.
    func run(_ arguments: [String] = [], completion: @escaping (Result<Void, Error>) -> Void) {
        guard !isRunning else { return }
        guard let script = Bundle.main.url(forResource: "install-engine", withExtension: "sh") else {
            completion(.failure(InstallError(message: "в приложении нет скрипта установки")))
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path] + arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Engine.openLog()
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            DispatchQueue.main.async { self?.receive(chunk) }
        }
        process.terminationHandler = { [weak self] process in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRunning = false
                stdout.fileHandleForReading.readabilityHandler = nil
                if process.terminationStatus == 0 {
                    Engine.log("установка завершена: \(arguments)")
                    completion(.success(()))
                } else {
                    let message = self.lastError ?? "установка прервалась (код \(process.terminationStatus))"
                    Engine.log("установка не удалась: \(message)")
                    completion(.failure(InstallError(message: message)))
                }
            }
        }
        lastError = nil
        status = "Подготовка…"
        do {
            try process.run()
            isRunning = true
            Engine.log("установка движка: \(arguments)")
        } catch {
            completion(.failure(InstallError(message: error.localizedDescription)))
        }
    }

    private func receive(_ chunk: Data) {
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...newline)
            if line.hasPrefix("AIT_PROGRESS ") {
                let parts = line.dropFirst(13).split(separator: " ", maxSplits: 1)
                let percent = Int(parts.first ?? "") ?? 0
                status = "\(percent)% — \(parts.count > 1 ? String(parts[1]) : "")"
                onProgress?(percent, parts.count > 1 ? String(parts[1]) : "")
            } else if line.hasPrefix("AIT_ERROR ") {
                lastError = String(line.dropFirst(10))
            }
        }
    }
}
