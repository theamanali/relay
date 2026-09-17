// The picker's visual vocabulary: four type roles, one spacing scale, one
// content margin. Everything in the window draws from these so edges and
// rhythm agree.

import AppKit

enum Style {
    enum Font {
        /// Header "Relay".
        static let title = NSFont.systemFont(ofSize: 20, weight: .semibold)
        /// Subtitle, host names, empty-state title, and every regular control.
        static let body = NSFont.systemFont(ofSize: 13)
        /// Secondary lines: host link, footer status, hints, hover values.
        static let caption = NSFont.systemFont(ofSize: 11)
        /// Small labels over groups: section headers, hover labels, popover headings.
        static let section = NSFont.systemFont(ofSize: 11, weight: .semibold)
    }

    /// The only gaps used, so nothing is 9 or 11 by accident.
    enum Space {
        /// A title over its subtitle.
        static let tight: CGFloat = 2
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        /// Every content edge in the window.
        static let margin: CGFloat = 20
    }

    static let rowHeight: CGFloat = 52
    static let sectionRowHeight: CGFloat = 28
    /// Room for the traffic lights under a fullSizeContentView title bar.
    static let titleBarClearance: CGFloat = 44
}
