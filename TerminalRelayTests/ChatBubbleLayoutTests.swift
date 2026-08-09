import AppKit
import SwiftUI
import XCTest
@testable import TerminalRelay

/// The hosted transcript row paints its own bubble, so its width is only
/// observable in the rendered pixels: SwiftUI draws text into the hosting
/// layer instead of into child views.
@MainActor
final class ChatBubbleLayoutTests: XCTestCase {
    private static let transcriptWidth: CGFloat = 760
    /// The widest a user bubble may paint, text padding included.
    private static let bubbleLimit: CGFloat = 640
    private static var retainedWindows: [NSWindow] = []

    func testHostedUserBubbleHugsShortContent() throws {
        XCTAssertLessThan(
            try bubbleWidth(text: "hello"),
            120,
            "A short user message must not paint a full-width bar."
        )
        XCTAssertLessThan(
            try bubbleWidth(text: "hello **there**"),
            200,
            "Inline Markdown must not widen the bubble past its text."
        )
        XCTAssertLessThan(
            try bubbleWidth(text: "```swift\nlet x = 1\n```"),
            300,
            "A short code block must not widen the bubble past its text."
        )
    }

    func testHostedUserBubbleWrapsAtTheBubbleLimit() throws {
        let width = try bubbleWidth(
            text: String(repeating: "wrap this sentence a lot ", count: 12)
        )
        XCTAssertGreaterThan(
            width,
            560,
            "Text longer than the bubble must wrap at the limit, not earlier."
        )
        XCTAssertLessThanOrEqual(
            width,
            Self.bubbleLimit,
            "Text longer than the bubble must never overflow it."
        )
    }

    func testHostedTableSizesToItsColumns() throws {
        XCTAssertLessThan(
            try bubbleWidth(text: "| a | b |\n| --- | --- |\n| 1 | 2 |"),
            300,
            "A narrow table must not stretch its scroller across the bubble."
        )
        let columns = (0..<12).map { "column \($0)" }
        let wideTable = """
        | \(columns.joined(separator: " | ")) |
        | \(columns.map { _ in "---" }.joined(separator: " | ")) |
        | \(columns.map { _ in "value" }.joined(separator: " | ")) |
        """
        XCTAssertEqual(
            try bubbleWidth(text: wideTable),
            Self.bubbleLimit,
            accuracy: 2,
            "A table wider than the bubble must fill it and scroll."
        )
    }

    /// Renders one hosted user row into a bitmap and returns the width of the
    /// painted bubble in points.
    private func bubbleWidth(text: String) throws -> CGFloat {
        let message = ChatMessage(
            id: "user",
            role: .user,
            text: text,
            occurredAt: 1
        )
        let hosting = NSHostingView(
            rootView: ChatMessageView(message: message, showsFooter: false)
                .frame(width: Self.transcriptWidth)
                .background(Color.white)
                .environment(\.colorScheme, .light)
        )
        let window = NSWindow(
            contentRect: NSRect(
                x: 0,
                y: 0,
                width: Self.transcriptWidth,
                height: 400
            ),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.orderFront(nil)
        Self.retainedWindows.append(window)
        hosting.needsLayout = true
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        hosting.layoutSubtreeIfNeeded()

        let rep = try XCTUnwrap(
            hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)
        )
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        let image = try XCTUnwrap(rep.cgImage)
        let width = image.width
        let height = image.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: width, height: height)
        )
        var minX = width
        var maxX = -1
        for y in 0..<height {
            for x in 0..<width {
                let offset = ((y * width) + x) * 4
                let isBackground = pixels[offset] > 250
                    && pixels[offset + 1] > 250
                    && pixels[offset + 2] > 250
                if isBackground { continue }
                minX = min(minX, x)
                maxX = max(maxX, x)
            }
        }
        XCTAssertGreaterThanOrEqual(maxX, minX, "The row painted nothing.")
        let scale = CGFloat(width) / Self.transcriptWidth
        return CGFloat(maxX - minX + 1) / scale
    }
}
