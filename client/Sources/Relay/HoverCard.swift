// A tooltip that can align things: a two-column grid of label / value pairs
// in a tooltip-material panel, shown after the usual hover delay. NSView's
// string tooltips cannot line up columns, which is all this exists for.

import AppKit

final class HoverCard {
    static let shared = HoverCard()

    private var panel: NSPanel?
    private var pending: DispatchWorkItem?
    private weak var anchor: NSView?

    /// Show `rows` beneath `view` after a short delay (cancelled by `hide`).
    func schedule(rows: [(label: String, value: String)], for view: NSView) {
        cancel()
        anchor = view
        let work = DispatchWorkItem { [weak self, weak view] in
            guard let self, let view, view.window != nil else { return }
            self.show(rows: rows, for: view)
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func hide() {
        cancel()
        panel?.orderOut(nil)
        panel = nil
        anchor = nil
    }

    private func cancel() {
        pending?.cancel()
        pending = nil
    }

    private func show(rows: [(label: String, value: String)], for view: NSView) {
        guard let window = view.window, !rows.isEmpty else { return }
        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 3
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading
        for row in rows {
            let label = NSTextField(labelWithString: row.label)
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = .secondaryLabelColor
            let value = NSTextField(labelWithString: row.value)
            value.font = .systemFont(ofSize: 11)
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
            grid.topAnchor.constraint(equalTo: background.topAnchor, constant: 8),
            grid.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -8),
            grid.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 10),
            grid.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -10),
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

        // Below the row, aligned to its leading edge, kept on the row's screen.
        let rowInWindow = view.convert(view.bounds, to: nil)
        let rowOnScreen = window.convertToScreen(rowInWindow)
        var origin = NSPoint(x: rowOnScreen.minX + 44, y: rowOnScreen.minY - size.height - 4)
        if let screen = window.screen?.visibleFrame {
            origin.x = min(origin.x, screen.maxX - size.width - 8)
            if origin.y < screen.minY { origin.y = rowOnScreen.maxY + 4 }
        }
        panel.setFrameOrigin(origin)
        self.panel?.orderOut(nil)
        self.panel = panel
        panel.orderFront(nil)
    }
}
