// A tooltip that can align things: a two-column grid of label / value pairs
// in a tooltip-material panel, shown after a short hover delay. A string
// tooltip cannot line up columns, and a popover has an arrow and steals
// clicks, which is all this exists for. The grid is SwiftUI; the panel is
// AppKit because SwiftUI has no borderless, non-activating floating window.

import AppKit
import SwiftUI

@MainActor
final class HoverCard {
    static let shared = HoverCard()

    private var panel: NSPanel?
    private var pending: DispatchWorkItem?
    private weak var anchor: NSView?
    private var clickMonitor: Any?
    /// While a rename or popover is up over the list: a card ordering itself
    /// front would close a transient popover, so hovering shows nothing.
    var isSuspended = false {
        didSet { if isSuspended { hide() } }
    }

    /// Tooltips fade rather than pop; this is about AppKit's own fade.
    static let fade: TimeInterval = 0.15

    /// Shorter than AppKit's 1 s tooltip wait: the card is the row's main
    /// detail, not an aside.
    static let delay: TimeInterval = 0.5

    private init() {
        // Any click (a selection, a context menu, a double-click to connect)
        // puts the card away, as AppKit's tooltips do; a right-click would
        // otherwise let a pending card open over the menu.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            MainActor.assumeIsolated { HoverCard.shared.hide() }
            return event
        }
    }

    /// Show `rows` beneath `view` after `delay` (cancelled by `hide`).
    /// `leadingInset` is where the host name starts inside `view`, so the
    /// card reads as belonging to that text.
    func schedule(rows: [(label: String, value: String)], for view: NSView, leadingInset: CGFloat) {
        cancel()
        guard !isSuspended else { return }
        anchor = view
        let work = DispatchWorkItem { [weak self, weak view] in
            MainActor.assumeIsolated {
                guard let self, let view, view.window != nil, !self.isSuspended else { return }
                self.show(rows: rows, for: view, leadingInset: leadingInset)
            }
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

    /// Dismiss only when `view` owns the card. A row leaving the list can
    /// arrive after the pointer has already moved onto another host.
    func hide(ifAnchoredTo view: NSView) {
        guard anchor === view else { return }
        hide()
    }

    private static func fade(_ panel: NSPanel, to alpha: CGFloat, then completion: (@MainActor () -> Void)? = nil) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = fade
            panel.animator().alphaValue = alpha
        }, completionHandler: { MainActor.assumeIsolated { completion?() } })
    }

    private func cancel() {
        pending?.cancel()
        pending = nil
    }

    private func show(rows: [(label: String, value: String)], for view: NSView, leadingInset: CGFloat) {
        guard let window = view.window, !rows.isEmpty else { return }
        let content = NSHostingView(rootView: HoverCardContent(rows: rows.map { HoverCardContent.Row(label: $0.label, value: $0.value) }))
        let size = content.fittingSize
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = true
        panel.contentView = content

        // Below the row, left edge under the host name, kept on the row's screen.
        let rowOnScreen = window.convertToScreen(view.convert(view.bounds, to: nil))
        var origin = NSPoint(x: rowOnScreen.minX + leadingInset - Style.Space.m, y: rowOnScreen.minY - size.height - Style.Space.xs)
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

private struct HoverCardContent: View {
    struct Row: Identifiable {
        let id = UUID()
        let label: String
        let value: String
    }
    let rows: [Row]

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: Style.Space.s, verticalSpacing: Style.Space.xs) {
            ForEach(rows) { row in
                GridRow {
                    Text(verbatim: row.label).font(Style.Font.section).foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    Text(verbatim: row.value).font(Style.Font.caption).lineLimit(1).truncationMode(.tail)
                }
            }
        }
        .frame(maxWidth: 360, alignment: .leading)
        .fixedSize()
        .padding(.vertical, Style.Space.s)
        .padding(.horizontal, Style.Space.m)
        .background(VisualEffect(material: .toolTip))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color(nsColor: .separatorColor)))
    }
}

/// The tooltip material, which SwiftUI's own materials do not include.
struct VisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.state = .active
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// Put behind a row: owns the row's hover tracking and gives the card a view
/// to anchor to. Tracking areas are not hit-tested, so the row's SwiftUI
/// content above it does not hide the pointer from it.
struct HoverCardAnchor: NSViewRepresentable {
    let rows: [(label: String, value: String)]
    let leadingInset: CGFloat

    func makeNSView(context: Context) -> AnchorView { AnchorView() }
    func updateNSView(_ view: AnchorView, context: Context) {
        view.rows = rows
        view.leadingInset = leadingInset
    }

    final class AnchorView: NSView {
        var rows: [(label: String, value: String)] = []
        var leadingInset: CGFloat = 0
        private var tracking: NSTrackingArea?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow], owner: self)
            addTrackingArea(area)
            tracking = area
        }

        override func mouseEntered(with event: NSEvent) {
            HoverCard.shared.schedule(rows: rows, for: self, leadingInset: leadingInset)
        }

        override func mouseExited(with event: NSEvent) {
            HoverCard.shared.hide(ifAnchoredTo: self)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { HoverCard.shared.hide(ifAnchoredTo: self) }
        }
    }
}
