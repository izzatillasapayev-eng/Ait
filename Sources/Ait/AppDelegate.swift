import AppKit
import AVFoundation
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum Phase { case idle, holding, toggled, transcribing }

    /// Нажатие короче этого — «короткое»: запись продолжается до следующего нажатия.
    private static let tapThreshold: TimeInterval = 0.35
    private static let escKeyCode: UInt16 = 53

    private let settings = Settings.shared
    private let hotkeys = HotkeyMonitor()
    private let recorder = Recorder()
    private let engine = Engine()
    private let installer = EngineInstaller()
    private let hud = HUD()
    private var statusItem: NSStatusItem!
    private var trustTimer: Timer?
    private var pressedAt = Date.distantPast
    private var phase: Phase = .idle { didSet { updateIcon() } }

    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        if let i = CommandLine.arguments.firstIndex(of: "--selftest"), i + 1 < CommandLine.arguments.count {
            runSelfTest(CommandLine.arguments[i + 1])
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--install-engine") {
            runInstallFromCommandLine(Array(CommandLine.arguments[(i + 1)...]))
            return
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        engine.onStateChange = { [weak self] state in
            guard let self else { return }
            if state == .ready, self.phase == .transcribing { self.hud.show(.processing) }
            self.updateIcon()
        }
        recorder.onLevel = { [weak self] level in
            DispatchQueue.main.async { self?.hud.setLevel(level) }
        }
        hotkeys.onPress = { [weak self] in self?.hotkeyPressed() }
        hotkeys.onRelease = { [weak self] in self?.hotkeyReleased() }
        hotkeys.onOtherKey = { [weak self] in self?.otherKeyPressed($0) }
        installer.onProgress = { [weak self] percent, text in
            self?.hud.show(.progress("Установка движка: \(percent)% — \(text)"))
        }

        updateIcon()
        applyHotkey()
        if Engine.isInstalled {
            requestPermissions()
            engine.applySettings(restart: false)
            if !UserDefaults.standard.bool(forKey: "welcomed") {
                UserDefaults.standard.set(true, forKey: "welcomed")
                hud.show(.message("Ait в строке меню. Удерживай \(settings.hotkey.symbol) и говори"))
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.offerInstall() }
        }
    }

    /// Открыли Ait из Launchpad, когда он уже запущен, — показываем меню.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItem?.button?.performClick(nil)
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.stop()
    }

    // MARK: - Диктовка

    private func hotkeyPressed() {
        guard settings.enabled else { return }
        switch phase {
        case .idle: startRecording()
        case .toggled: finishRecording()
        case .holding, .transcribing: break
        }
    }

    private func hotkeyReleased() {
        guard phase == .holding else { return }
        if Date().timeIntervalSince(pressedAt) < Self.tapThreshold {
            phase = .toggled
            hud.show(.listening(toggle: true))
        } else {
            finishRecording()
        }
    }

    private func otherKeyPressed(_ keyCode: UInt16) {
        switch phase {
        case .holding:
            cancelRecording()  // клавишу зажали ради сочетания, а не для диктовки
        case .toggled where keyCode == Self.escKeyCode:
            cancelRecording()
            hud.show(.message("Отменено"))
        default:
            break
        }
    }

    private func startRecording() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            hud.show(.message("Нет доступа к микрофону — разреши в меню Ait"))
            requestPermissions()
            return
        }
        guard Engine.isInstalled else {
            offerInstall()
            return
        }
        engine.warmUp()  // модель грузится, пока ты говоришь
        do {
            try recorder.start()
        } catch {
            Engine.log("микрофон: \(error)")
            hud.show(.message("Не удалось включить микрофон"))
            return
        }
        pressedAt = Date()
        phase = .holding
        hud.show(.listening(toggle: false))
    }

    private func cancelRecording() {
        _ = recorder.stop()
        phase = .idle
        hud.hide()
    }

    private func finishRecording() {
        let samples = recorder.stop()
        guard Double(samples.count) / Recorder.sampleRate >= 0.3 else {
            phase = .idle
            hud.hide()
            return
        }
        phase = .transcribing
        hud.show(engine.state == .ready ? .processing : .loading)

        let wav = FileManager.default.temporaryDirectory.appendingPathComponent("ait-\(UUID().uuidString).wav")
        do {
            try Recorder.writeWav(samples, to: wav)
        } catch {
            phase = .idle
            hud.show(.message("Не удалось сохранить запись"))
            return
        }
        engine.transcribe(wav) { [weak self] result in
            try? FileManager.default.removeItem(at: wav)
            guard let self else { return }
            self.phase = .idle
            switch result {
            case .success(let text) where !text.isEmpty:
                self.hud.hide()
                Inserter.insert(text)
            case .success:
                self.hud.show(.message("Речь не распознана"))
            case .failure(let error):
                self.hud.show(.message("Ошибка: \(error.localizedDescription)"))
            }
        }
    }

    // MARK: - Установка движка

    private func offerInstall() {
        guard !installer.isRunning else { return }
        let alert = NSAlert()
        alert.messageText = "Ait нужно скачать движок распознавания"
        alert.informativeText = """
        Будут скачаны Python-окружение и модели GigaAM с пунктуацией — около 470 MB. \
        Всё ляжет в ~/Library/Application Support/Ait, а после установки распознавание работает без интернета.
        """
        alert.addButton(withTitle: "Скачать")
        alert.addButton(withTitle: "Позже")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        installEngine([]) { [weak self] in
            guard let self else { return }
            self.requestPermissions()
            self.engine.applySettings(restart: false)
            self.hud.show(.message("Готово! Удерживай \(self.settings.hotkey.symbol) и говори"))
        }
    }

    private func installEngine(_ arguments: [String], onSuccess: @escaping () -> Void) {
        hud.show(.progress("Установка движка: подготовка…"))
        installer.run(arguments) { [weak self] result in
            guard let self else { return }
            self.updateIcon()
            switch result {
            case .success:
                onSuccess()
            case .failure(let error):
                self.hud.show(.message("Установка не удалась: \(error.localizedDescription)"))
            }
        }
        updateIcon()
    }

    // MARK: - Разрешения

    private var micGranted: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    private func requestPermissions() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async { self.updateIcon() }
            }
        }
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
            waitForAccessibility()
        }
    }

    /// Мониторы клавиатуры начинают работать только после выдачи доступа — переустанавливаем их.
    private func waitForAccessibility() {
        guard trustTimer == nil else { return }
        trustTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] timer in
            guard AXIsProcessTrusted() else { return }
            timer.invalidate()
            self?.trustTimer = nil
            self?.applyHotkey()
            self?.updateIcon()
        }
    }

    private func applyHotkey() {
        hotkeys.hotkey = settings.hotkey
        if settings.enabled { hotkeys.start() } else { hotkeys.stop() }
    }

    // MARK: - Строка меню

    private func updateIcon() {
        guard let button = statusItem?.button else { return }
        let symbol: String
        var tint: NSColor?
        if installer.isRunning {
            symbol = "arrow.down.circle"
        } else if !settings.enabled {
            symbol = "mic.slash"
        } else if !AXIsProcessTrusted() || !micGranted || !Engine.isInstalled {
            symbol = "exclamationmark.triangle"
        } else {
            switch phase {
            case .holding, .toggled: symbol = "mic.fill"; tint = .systemRed
            case .transcribing: symbol = "waveform"; tint = .systemBlue
            case .idle: symbol = "waveform"
            }
        }
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Ait")
        image?.isTemplate = true
        button.image = image
        button.contentTintColor = tint
    }

    private var statusLine: String {
        if installer.isRunning { return "Устанавливаю движок…" }
        guard Engine.isInstalled else { return "Движок распознавания не установлен" }
        guard settings.enabled else { return "Выключено" }
        switch phase {
        case .holding, .toggled: return "Слушаю…"
        case .transcribing: return "Распознаю…"
        case .idle: break
        }
        switch engine.state {
        case .ready: return "Модель в памяти — готово"
        case .loading: return "Загружаю модель…"
        case .stopped: return settings.startMode == .hot ? "Модель не загружена" : "Модель выгружена — загрузится при нажатии"
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(.sectionHeader(title: "Ait — голосовой ввод"))
        menu.addItem(note(statusLine))
        menu.addItem(.separator())
        menu.addItem(option("Включено", checked: settings.enabled, action: #selector(toggleEnabled)))

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Модель"))
        for size in ModelSize.allCases {
            let title = size == .large && !Engine.isInstalled(.large) ? size.title + " — скачать ~430 MB" : size.title
            menu.addItem(option(title, checked: settings.model == size, action: #selector(selectModel(_:)), value: size.rawValue))
        }
        menu.addItem(option("Пунктуация и заглавные буквы (+0.13 GB)", checked: settings.punctuation, action: #selector(togglePunctuation)))

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Запуск модели"))
        menu.addItem(option("Холодный старт — выгружать при простое", checked: settings.startMode == .cold,
                            action: #selector(selectStartMode(_:)), value: StartMode.cold.rawValue))
        let unload = NSMenuItem(title: "Выгружать через: \(unloadTitle(settings.unloadMinutes))", action: nil, keyEquivalent: "")
        unload.submenu = NSMenu()
        for minutes in [0, 1, 5, 15, 60] {
            unload.submenu?.addItem(option(unloadTitle(minutes), checked: settings.unloadMinutes == minutes,
                                           action: #selector(selectUnload(_:)), value: minutes))
        }
        unload.isEnabled = settings.startMode == .cold
        unload.indentationLevel = 1
        menu.addItem(unload)
        menu.addItem(option("Горячий старт — модель всегда в памяти", checked: settings.startMode == .hot,
                            action: #selector(selectStartMode(_:)), value: StartMode.hot.rawValue))

        menu.addItem(.separator())
        let hotkey = NSMenuItem(title: "Горячая клавиша: \(settings.hotkey.title)", action: nil, keyEquivalent: "")
        hotkey.submenu = NSMenu()
        for key in Hotkey.allCases {
            hotkey.submenu?.addItem(option(key.title, checked: settings.hotkey == key, action: #selector(selectHotkey(_:)), value: key.rawValue))
        }
        menu.addItem(hotkey)
        menu.addItem(note("Удерживай — говори, отпусти — текст вставится"))
        menu.addItem(note("Короткое нажатие — запись до следующего нажатия"))

        if installer.isRunning {
            menu.addItem(.separator())
            menu.addItem(note("Установка движка: \(installer.status)"))
        } else if !Engine.isInstalled {
            menu.addItem(.separator())
            menu.addItem(action("⬇︎ Установить движок распознавания (~470 MB)…", #selector(installFromMenu)))
        }
        if !micGranted || !AXIsProcessTrusted() {
            menu.addItem(.separator())
            if !micGranted { menu.addItem(action("⚠︎ Разрешить доступ к микрофону…", #selector(openMicrophoneSettings))) }
            if !AXIsProcessTrusted() { menu.addItem(action("⚠︎ Разрешить Универсальный доступ (для клавиши и вставки)…", #selector(openAccessibilitySettings))) }
        }

        menu.addItem(.separator())
        menu.addItem(option("Запускать при входе в систему", checked: SMAppService.mainApp.status == .enabled, action: #selector(toggleLoginItem)))
        menu.addItem(action("Открыть журнал", #selector(openLog)))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Выйти из Ait", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func unloadTitle(_ minutes: Int) -> String {
        switch minutes {
        case 0: "сразу после распознавания"
        case 1: "1 минуту"
        case 60: "1 час"
        default: "\(minutes) минут"
        }
    }

    private func option(_ title: String, checked: Bool, action: Selector, value: Any? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = checked ? .on : .off
        item.representedObject = value
        return item
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    private func note(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - Действия меню

    @objc private func toggleEnabled() {
        settings.enabled.toggle()
        if !settings.enabled, phase == .holding || phase == .toggled { cancelRecording() }
        applyHotkey()
        engine.applySettings(restart: false)
        updateIcon()
    }

    @objc private func selectModel(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let size = ModelSize(rawValue: raw), size != settings.model else { return }
        guard Engine.isInstalled(size) else {
            offerDownload(size)
            return
        }
        settings.model = size
        engine.applySettings(restart: true)
    }

    private func offerDownload(_ size: ModelSize) {
        guard !installer.isRunning else { return }
        let alert = NSAlert()
        alert.messageText = "Скачать GigaAM Large?"
        alert.informativeText = "Large точнее на казахском и русском, но весит ~430 MB на диске и занимает ~0.6 GB памяти во время диктовки."
        alert.addButton(withTitle: "Скачать")
        alert.addButton(withTitle: "Отмена")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        installEngine(["--model", size.rawValue]) { [weak self] in
            self?.settings.model = size
            self?.engine.applySettings(restart: true)
            self?.hud.show(.message("GigaAM Large скачана и выбрана"))
        }
    }

    @objc private func installFromMenu() {
        offerInstall()
    }

    @objc private func togglePunctuation() {
        settings.punctuation.toggle()
        engine.applySettings(restart: true)
    }

    @objc private func selectStartMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = StartMode(rawValue: raw) else { return }
        settings.startMode = mode
        engine.applySettings(restart: false)
    }

    @objc private func selectUnload(_ sender: NSMenuItem) {
        guard let minutes = sender.representedObject as? Int else { return }
        settings.unloadMinutes = minutes
        engine.applySettings(restart: false)
    }

    @objc private func selectHotkey(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let key = Hotkey(rawValue: raw) else { return }
        settings.hotkey = key
        applyHotkey()
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            hud.show(.message("Автозапуск: \(error.localizedDescription)"))
        }
    }

    @objc private func openMicrophoneSettings() {
        if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            requestPermissions()
        } else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        }
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        waitForAccessibility()
    }

    @objc private func openLog() {
        Engine.log("журнал открыт из меню")
        NSWorkspace.shared.open(Engine.logFile)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Установка из терминала: Ait --install-engine [--model large | --all]

    private func runInstallFromCommandLine(_ arguments: [String]) {
        installer.onProgress = { percent, text in
            print("\(percent)% \(text)")
            fflush(stdout)
        }
        installer.run(arguments) { result in
            switch result {
            case .success: print("OK: движок установлен в \(Engine.home.path)")
            case .failure(let error): print("ERROR: \(error.localizedDescription)")
            }
            exit(Engine.isInstalled ? 0 : 1)
        }
    }

    // MARK: - Самопроверка: Ait --selftest file.wav

    private func runSelfTest(_ path: String) {
        let started = Date()
        engine.transcribe(URL(fileURLWithPath: path)) { result in
            switch result {
            case .success(let text): print("TEXT (\(String(format: "%.2f", Date().timeIntervalSince(started))) s): \(text)")
            case .failure(let error): print("ERROR: \(error.localizedDescription)")
            }
            exit(0)
        }
    }
}
