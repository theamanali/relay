// The picker's visual vocabulary: four type roles, one spacing scale, one
// content margin. Everything in the window draws from these so edges and
// rhythm agree.

import SwiftUI

enum Style {
    enum Font {
        /// Header "Relay".
        static let title = SwiftUI.Font.system(size: 20, weight: .semibold)
        /// Subtitle, host names, empty-state title, and every regular control.
        static let body = SwiftUI.Font.system(size: 13)
        /// Secondary lines: host link, footer status, hints, hover values.
        static let caption = SwiftUI.Font.system(size: 11)
        /// Small labels over groups: section headers, hover labels, popover headings.
        static let section = SwiftUI.Font.system(size: 11, weight: .semibold)
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

    /// Narrow enough that the footer's mode row has even gaps, wide enough
    /// for a full `SessionText.footerLimit` status beside Connect. The height
    /// follows the list (`PickerLayout`).
    static let windowWidth: CGFloat = 410
    static let rowHeight: CGFloat = 52
    static let sectionRowHeight: CGFloat = 28
    /// From the hidden title bar, which stays a safe area above the content
    /// (28 points tall on older SDKs, 32 on the macOS 26+ SDK), to the hero.
    static let headerTopInset: CGFloat = 16
}

/// The picker's list is as tall as its rows, so a single PC leaves no empty
/// band above the footer. Past `maxHostRows` it scrolls, and is half a row
/// taller than that so a partly shown row says there is more below.
enum PickerLayout {
    /// The inset list's own padding above the first row and below the last.
    static let listInsets: CGFloat = 20
    static let maxHostRows = 5

    /// Paired (when any) and Available titles and the PCs; with none at all
    /// the empty state takes the two-row floor.
    static func listHeight(paired: Int, available: Int) -> CGFloat {
        // Never so short that the first PC to appear makes the window jump far.
        let floor = listInsets + Style.sectionRowHeight + 2 * Style.rowHeight
        return min(max(contentHeight(paired: paired, available: available), floor), scrollingHeight)
    }

    /// More rows than fit: only then does the list scroll and show a scroller.
    static func overflows(paired: Int, available: Int) -> Bool {
        contentHeight(paired: paired, available: available) > scrollingHeight
    }

    /// Both titles and `maxHostRows` PCs, plus half a row. A height that ended
    /// on a row boundary hid the overflow: nothing showed there was more.
    private static let scrollingHeight = listInsets + 2 * Style.sectionRowHeight + Style.Space.l
        + (CGFloat(maxHostRows) + 0.5) * Style.rowHeight

    private static func contentHeight(paired: Int, available: Int) -> CGFloat {
        let titles = paired > 0 ? 2 * Style.sectionRowHeight + Style.Space.l : Style.sectionRowHeight
        let rows = CGFloat(max(paired + available, 1))
        return listInsets + titles + rows * Style.rowHeight
    }
}
