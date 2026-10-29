import AppKit

/// Следит за одной модификаторной клавишей (например, правым ⌥) во всей системе.
/// Глобальные мониторы клавиатуры работают только с разрешением «Универсальный доступ».
final class HotkeyMonitor {
    var hotkey: Hotkey = .rightOption
    var onPress: (() -> Void)?
    var onRelease: (() -> Void)?
    /// Нажата другая клавиша: передаём её keyCode (53 — Esc).
    var onOtherKey: ((UInt16) -> Void)?

    private var monitors: [Any] = []
    private var isDown = false

    func start() {
        stop()
        let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] in self?.handle($0) }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] in self?.handle($0); return $0 }) {
            monitors.append(local)
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        isDown = false
    }

    private func handle(_ event: NSEvent) {
        if event.type == .keyDown {
            onOtherKey?(event.keyCode)
            return
        }
        guard event.keyCode == hotkey.keyCode else {
            if isDown { onOtherKey?(event.keyCode) }  // другой модификатор вместе с нашим — это сочетание, не диктовка
            return
        }
        let down = event.modifierFlags.rawValue & hotkey.deviceMask != 0
        if down, !isDown {
            isDown = true
            onPress?()
        } else if !down, isDown {
            isDown = false
            onRelease?()
        }
    }
}
