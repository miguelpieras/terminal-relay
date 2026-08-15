import SwiftUI

/// The transcript's shared type scale. Hosted SwiftUI rows and the native
/// AppKit text path must agree on these sizes: rows swap between the two
/// representations at scroll boundaries and at tool completion, and any size
/// divergence turns that swap into a visible height jump.
enum ChatTypography {
    /// Activity lines: tool headlines, group summaries, reasoning and diff
    /// headers, thinking indicators. macOS matches the 13pt native transcript
    /// body; iOS keeps its compact secondary size.
    static var activityLine: Font {
        #if os(macOS)
        .body
        #else
        .subheadline
        #endif
    }

    /// Monospaced detail inside expanded tools and code blocks. 13pt on
    /// macOS — identical to the native TextKit tiles that replace these rows
    /// when a tool completes.
    static var monospacedDetail: Font {
        #if os(macOS)
        .system(.body, design: .monospaced)
        #else
        .system(.callout, design: .monospaced)
        #endif
    }

    /// Message footers and timestamps. Matches the native footer cell's
    /// 11pt small system font on macOS.
    static var timestamp: Font {
        #if os(macOS)
        .system(size: 11)
        #else
        .caption
        #endif
    }

    /// Fixed height of one compact activity line at the default type size.
    /// Native scroll stand-ins use the same floor so cell-class swaps never
    /// change row height.
    static let activityLineHeight: CGFloat = 22

    /// Vertical padding around one compact activity row; the native
    /// presentation mirrors it in its content insets.
    static let activityLinePadding: CGFloat = 2
}
