import Foundation

enum ModelSize: String, CaseIterable {
    case base, large

    var title: String {
        switch self {
        case .base: "GigaAM обычная — быстрее (~0.3 GB)"
        case .large: "GigaAM Large — точнее (~0.6 GB)"
        }
    }

    /// Файл весов модели относительно папки models — по нему видно, что модель скачана.
    var weightsFile: String {
        switch self {
        case .base: "gigaam-base/multilingual_ctc.int8.onnx.data"
        case .large: "gigaam-large/multilingual_large_ctc.int8.onnx.data"
        }
    }
}

enum StartMode: String {
    /// Модель выгружается после простоя и загружается снова при нажатии клавиши.
    case cold
    /// Модель всё время в памяти — распознавание без задержки.
    case hot
}

enum Hotkey: String, CaseIterable {
    case rightOption, rightCommand, rightControl, rightShift

    var title: String {
        switch self {
        case .rightOption: "Правый ⌥ Option"
        case .rightCommand: "Правый ⌘ Command"
        case .rightControl: "Правый ⌃ Control"
        case .rightShift: "Правый ⇧ Shift"
        }
    }

    var symbol: String {
        switch self {
        case .rightOption: "правый ⌥"
        case .rightCommand: "правый ⌘"
        case .rightControl: "правый ⌃"
        case .rightShift: "правый ⇧"
        }
    }

    var keyCode: UInt16 {
        switch self {
        case .rightOption: 61
        case .rightCommand: 54
        case .rightControl: 62
        case .rightShift: 60
        }
    }

    /// Аппаратный флаг конкретной (правой) клавиши в NSEvent.modifierFlags (NX_DEVICER*KEYMASK).
    var deviceMask: UInt {
        switch self {
        case .rightOption: 0x40
        case .rightCommand: 0x10
        case .rightControl: 0x2000
        case .rightShift: 0x04
        }
    }
}

final class Settings {
    static let shared = Settings()
    private let defaults = UserDefaults.standard

    var enabled: Bool {
        get { defaults.object(forKey: "enabled") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "enabled") }
    }

    var model: ModelSize {
        get { ModelSize(rawValue: defaults.string(forKey: "model") ?? "") ?? .base }
        set { defaults.set(newValue.rawValue, forKey: "model") }
    }

    var punctuation: Bool {
        get { defaults.bool(forKey: "punctuation") }
        set { defaults.set(newValue, forKey: "punctuation") }
    }

    var hotkey: Hotkey {
        get { Hotkey(rawValue: defaults.string(forKey: "hotkey") ?? "") ?? .rightOption }
        set { defaults.set(newValue.rawValue, forKey: "hotkey") }
    }

    var startMode: StartMode {
        get { StartMode(rawValue: defaults.string(forKey: "startMode") ?? "") ?? .cold }
        set { defaults.set(newValue.rawValue, forKey: "startMode") }
    }

    /// Через сколько минут простоя выгружать модель в холодном режиме (0 — сразу после распознавания).
    var unloadMinutes: Int {
        get { defaults.object(forKey: "unloadMinutes") as? Int ?? 5 }
        set { defaults.set(newValue, forKey: "unloadMinutes") }
    }
}
