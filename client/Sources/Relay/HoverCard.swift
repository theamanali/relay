// A tooltip that can align things: a two-column grid of label / value pairs
// in a tooltip-material panel, shown after a short hover delay. NSView's
// string tooltips cannot line up columns, which is all this exists for.

import AppKit

final class HoverCard {
    static let shared = HoverCard()

    private var panel: NSPanel?
    private var pending: DispatchWorkItem?
    private weak var anchor: NSView?
    /// While a popover is up over the list: a card ordering itself front
    /// would close a transient popover, so hovering shows nothing.
    var isSuspended = false {
        didSet { if isSuspended { hide() } }
    }

    /// Tooltips fade rather than pop; this is about AppKit's own fade.
    static let fade: TimeInterval = 0.15

    /// Shorter than AppKit's 1 s tooltip wait: the card is the row's main
    /// detail, not an aside.
    static let delay: TimeInterval = 0.5

    /// Show `rows` beneath `view` after `delay` (cancelled by `hide`).
    /// `alignedTo` is the view whose left edge the card lines up with (the
    /// host name), so the card reads as belonging to that text.
    func schedule(rows: [(label: String, value: String)], for view: NSView, alignedTo leading: NSView) {
        cancel()
        guard !isSuspended else { return }
        anchor = view
        let work = DispatchWorkItem { [weak self, weak view, weak leading] in
            guard let self, let view, let leading, view.window != nil else { return }
            self.show(rows: rows, for: view, alignedTo: leading)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay, execute: work)
    }

    func hide() {
        cancel()
        if let panel {
            Self.fade(panel, to: 0) { panel.orderOut(nil) }
        }
        panel = nil
        anchor = nil
    }

    private static func fade(_ panel: NSPanel, to alpha: CGFloat, then completion: (() -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = fade
            panel.animator().alphaValue = alpha
        }, completionHandler: completion)
    }

    /// Dismiss only when `view` owns the card. A fading table-row removal can
    /// arrive after the pointer has already moved onto another host.
    func hide(ifAnchoredTo view: NSView) {
        guard anchor === view else { return }
        hide()
    }

    private func cancel() {
        pending?.cancel()
        pending = nil
    }

    private func show(rows: [(label: String, value: String)], for view: NSView, alignedTo leading: NSView) {
        guard let window = view.window, !rows.isEmpty else { return }
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = Style.Space.xs
        grid.columnSpacing = Style.Space.s
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        for row in rows {
            let label = NSTextField(labelWithString: row.label)
            label.font = Style.Font.section
            label.textColor = .secondaryLabelColor
            let value = NSTextField(labelWithString: row.value)
            value.font = Style.Font.caption
            value.textColor = .labelColor
            value.lineBreakMode = .byTruncatingTail
            value.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            grid.addRow(with: [label, value])
        }
        grid.translatesAutoresizingMaskIntoConstraints = false

        let background = NSVisualEffectView()
        background.material = .toolTip
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 6
        background.layer?.borderWidth = 1
        background.layer?.borderColor = NSColor.separatorColor.cgColor
        background.addSubview(grid)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: background.topAnchor, constant: Style.Space.s),
            grid.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -Style.Space.s),
            grid.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: Style.Space.m),
            grid.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -Style.Space.m),
            grid.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])

        let size = background.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = true
        panel.contentView = background
        background.frame = NSRect(origin: .zero, size: size)

        // Below the row, left edge under the host name, kept on the row's screen.
        let rowOnScreen = window.convertToScreen(view.convert(view.bounds, to: nil))
        let nameOnScreen = window.convertToScreen(leading.convert(leading.bounds, to: nil))
        var origin = NSPoint(x: nameOnScreen.minX - Style.Space.m, y: rowOnScreen.minY - size.height - Style.Space.xs)
        if let screen = window.screen?.visibleFrame {
            origin.x = min(origin.x, screen.maxX - size.width - Style.Space.s)
            if origin.y < screen.minY { origin.y = rowOnScreen.maxY + Style.Space.xs }
        }
        panel.setFrameOrigin(origin)
        if let old = self.panel {
            Self.fade(old, to: 0) { old.orderOut(nil) }
        }
        self.panel = panel
        panel.alphaValue = 0
        panel.orderFront(nil)
        Self.fade(panel, to: 1)
    }
}
