import AppKit

/// Плашка внизу экрана: «Слушаю…», «Распознаю…» и короткие сообщения. Не забирает фокус.
final class HUD {
    enum Mode {
        case listening(toggle: Bool)
        case loading
        case processing
        /// Висит, пока не придёт следующее состояние (установка движка).
        case progress(String)
        case message(String)
    }

    private lazy var panel = makePanel()
    private let label = NSTextField(labelWithString: "")
    private let dot = LevelDot()
    private var hideWork: DispatchWorkItem?

    func show(_ mode: Mode) {
        hideWork?.cancel()
        switch mode {
        case .listening(let toggle):
            dot.color = .systemRed
            label.stringValue = toggle
                ? "Слушаю… нажми ещё раз, чтобы вставить · Esc — отмена"
                : "Слушаю… отпусти, чтобы вставить"
        case .loading:
            dot.color = .systemOrange
            dot.level = 0.4
            label.stringValue = "Загружаю модель…"
        case .processing:
            dot.color = .systemBlue
            dot.level = 0.4
            label.stringValue = "Распознаю…"
        case .progress(let text):
            dot.color = .systemOrange
            dot.level = 0.4
            label.stringValue = text
        case .message(let text):
            dot.color = .systemGray
            dot.level = 0.2
            label.stringValue = text
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
        }
        position()
        panel.orderFrontRegardless()
    }

    func setLevel(_ level: Float) {
        dot.level = CGFloat(level)
    }

    func hide() {
        hideWork?.cancel()
        panel.orderOut(nil)
    }

    private func position() {
        let size = NSSize(width: label.fittingSize.width + 56, height: 36)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        panel.setFrame(NSRect(x: area.midX - size.width / 2, y: area.minY + 48, width: size.width, height: size.height), display: true)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 18
        background.layer?.masksToBounds = true

        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [dot, label])
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 14, bottom: 0, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        dot.translatesAutoresizingMaskIntoConstraints = false

        background.addSubview(stack)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 16),
            dot.heightAnchor.constraint(equalToConstant: 16),
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
        panel.contentView = background
        return panel
    }
}

/// Кружок, который «дышит» вместе с громкостью голоса.
private final class LevelDot: NSView {
    var color: NSColor = .systemRed { didSet { needsDisplay = true } }
    var level: CGFloat = 0 {
        didSet {
            smoothed = smoothed * 0.6 + level * 0.4
            needsDisplay = true
        }
    }
    private var smoothed: CGFloat = 0

    override func draw(_ dirtyRect: NSRect) {
        let radius = 3.5 + min(smoothed, 1) * 4.5
        let rect = NSRect(x: bounds.midX - radius, y: bounds.midY - radius, width: radius * 2, height: radius * 2)
        color.setFill()
        NSBezierPath(ovalIn: rect).fill()
    }
}
