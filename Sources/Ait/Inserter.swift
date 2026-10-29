import AppKit

/// Вставляет текст в активное поле любого приложения: через буфер обмена и ⌘V,
/// после чего возвращает в буфер то, что там было.
enum Inserter {
    private static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")

    static func insert(_ text: String) {
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.reduce(into: [NSPasteboard.PasteboardType: Data]()) { dict, type in
                dict[type] = item.data(forType: type)
            }
        }

        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: transientType)  // менеджеры буфера обмена не сохранят это в историю
        pasteboard.clearContents()
        pasteboard.writeObjects([item])
        let ourChange = pasteboard.changeCount

        pressCommandV()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            guard pasteboard.changeCount == ourChange else { return }  // пользователь уже скопировал что-то своё
            pasteboard.clearContents()
            let items = saved.map { dict in
                let restored = NSPasteboardItem()
                dict.forEach { restored.setData($1, forType: $0) }
                return restored
            }
            if !items.isEmpty { pasteboard.writeObjects(items) }
        }
    }

    private static func pressCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let keyV: CGKeyCode = 9
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: keyV, keyDown: isDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }
}
