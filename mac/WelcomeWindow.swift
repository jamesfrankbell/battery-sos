import Cocoa

// First-run and reopen surface. Three short cards, not a modal wall of text.
enum WelcomeWindow {
    private static var controller: WelcomePanelController?

    static func show(onTest: @escaping () -> Void) {
        let panel = controller ?? WelcomePanelController()
        controller = panel
        panel.onTest = onTest
        panel.onClose = { controller = nil }
        panel.present()
    }
}

private final class WelcomePanelController: NSWindowController, NSWindowDelegate {
    var onTest: (() -> Void)?
    var onClose: (() -> Void)?
    private var didClose = false

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 460),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = FirstRunOnboarding.title
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = .windowBackgroundColor
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        window.contentView = WelcomeRootView(onGotIt: { [weak self] in self?.close() }, onTest: { [weak self] in self?.tryTest() })
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func present() {
        guard let window else { return }
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard !didClose else { return }
        didClose = true
        FirstRunOnboarding.markComplete(defaults: .standard)
        onClose?()
    }

    private func tryTest() {
        let action = onTest
        close()
        action?()
    }
}

private final class WelcomeRootView: NSView {
    private let proxies: [ActionProxy]

    init(onGotIt: @escaping () -> Void, onTest: @escaping () -> Void) {
        let testProxy = ActionProxy(onTest)
        let doneProxy = ActionProxy(onGotIt)
        proxies = [testProxy, doneProxy]
        super.init(frame: NSRect(x: 0, y: 0, width: 700, height: 460))
        let title = NSTextField(labelWithString: FirstRunOnboarding.title)
        title.font = .systemFont(ofSize: 28, weight: .bold)
        title.textColor = .labelColor
        let accent = WelcomeAccent()
        let note = NSTextField(wrappingLabelWithString: FirstRunOnboarding.menuBarNote)
        note.font = .systemFont(ofSize: 13, weight: .medium)
        note.textColor = .secondaryLabelColor
        note.maximumNumberOfLines = 2

        let cards = NSStackView()
        cards.orientation = .horizontal
        cards.distribution = .fillEqually
        cards.spacing = 12
        cards.alignment = .top
        for card in FirstRunOnboarding.cards {
            cards.addArrangedSubview(WelcomeCardView(card: card))
        }

        let test = NSButton(title: "Try Test SOS", target: testProxy, action: #selector(ActionProxy.perform))
        test.bezelStyle = .rounded
        let done = NSButton(title: "Got it", target: doneProxy, action: #selector(ActionProxy.perform))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"

        let buttons = NSStackView(views: [test, done])
        buttons.orientation = .horizontal
        buttons.spacing = 10
        buttons.alignment = .centerY

        for view in [title, accent, note, cards, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 36),
            accent.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            accent.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 8),
            accent.widthAnchor.constraint(equalToConstant: 36),
            accent.heightAnchor.constraint(equalToConstant: 4),
            note.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            note.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            note.topAnchor.constraint(equalTo: accent.bottomAnchor, constant: 10),
            cards.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            cards.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            cards.topAnchor.constraint(equalTo: note.bottomAnchor, constant: 22),
            cards.heightAnchor.constraint(equalToConstant: 230),
            buttons.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            buttons.topAnchor.constraint(equalTo: cards.bottomAnchor, constant: 22),
            buttons.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -24),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class ActionProxy: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func perform() { action() }
}

private final class WelcomeCardView: NSView {
    init(card: WelcomeCard) {
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay

        let badge = WelcomeBadge(text: card.badge)
        let headline = NSTextField(labelWithString: card.headline)
        headline.font = .systemFont(ofSize: 16, weight: .bold)
        headline.textColor = .labelColor
        headline.maximumNumberOfLines = 2
        headline.cell?.truncatesLastVisibleLine = true
        let line = NSTextField(wrappingLabelWithString: card.line)
        line.font = .systemFont(ofSize: 13)
        line.textColor = .secondaryLabelColor
        line.maximumNumberOfLines = 4

        for view in [badge, headline, line] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            badge.topAnchor.constraint(equalTo: topAnchor, constant: 18),
            badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            badge.widthAnchor.constraint(equalToConstant: 72),
            badge.heightAnchor.constraint(equalToConstant: 72),
            headline.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            headline.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            headline.topAnchor.constraint(equalTo: badge.bottomAnchor, constant: 16),
            line.leadingAnchor.constraint(equalTo: headline.leadingAnchor),
            line.trailingAnchor.constraint(equalTo: headline.trailingAnchor),
            line.topAnchor.constraint(equalTo: headline.bottomAnchor, constant: 6),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = 16
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 1
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

private final class WelcomeAccent: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = 2
        layer?.backgroundColor = NSColor.systemRed.cgColor
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

private final class WelcomeBadge: NSView {
    private let label: NSTextField
    init(text: String) {
        label = NSTextField(labelWithString: text)
        super.init(frame: .zero)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        label.font = .systemFont(ofSize: text.count > 2 ? 18 : 28, weight: .heavy)
        label.textColor = .white
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.cornerRadius = 16
        layer?.backgroundColor = NSColor.systemRed.cgColor
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
