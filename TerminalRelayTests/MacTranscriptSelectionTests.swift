import AppKit
import XCTest

@testable import TerminalRelay

/// Cross-transcript selection foundations.
///
/// Spike (task 1.1) — VERDICT: GO, with one documented adapter. The fast
/// plain tiles (`MacConversationWrappingTextField`, borderless,
/// byCharWrapping, boundingRect-measured) have no public hit-test API, so
/// selection hit-testing runs a throwaway TextKit stack over
/// `attributedStringValue`. Findings this spike pins:
/// - Line BREAKS agree exactly between the stack and NSStringDrawing at every
///   probed width/scale/script mix, but per-line HEIGHT does not (SF 13:
///   NSStringDrawing 16.0/line, TextKit 17.0/line) — raw-y hit tests drift a
///   full line ~16 lines into a tile. Fast tiles are single-font by
///   construction, so line heights are uniform and a linear y-scale
///   (stackHeight / fieldHeight) maps field points onto stack points exactly;
///   `characterIndex(atFieldPoint:fieldHeight:)` is the adapter WP3 must use.
/// - `boundingRect(forGlyphRange:)` is NOT a valid probe/highlight primitive
///   for mixed-script text (it reports enclosing run rects tens of points
///   wide); `location(forGlyphAt:)` + line fragments are.
/// - Nearest-insertion hit tests are grapheme-faithful on both surfaces,
///   including emoji, ZWJ sequences, and combining marks.
@MainActor
final class MacTranscriptSelectionTests: XCTestCase {
    private struct ThrowawayStack {
        let storage: NSTextStorage
        let layoutManager: NSLayoutManager
        let container: NSTextContainer

        init(_ string: NSAttributedString, width: CGFloat) {
            storage = NSTextStorage(attributedString: string)
            layoutManager = NSLayoutManager()
            container = NSTextContainer(
                containerSize: NSSize(
                    width: width,
                    height: CGFloat.greatestFiniteMagnitude
                )
            )
            container.lineFragmentPadding = 0
            storage.addLayoutManager(layoutManager)
            layoutManager.addTextContainer(container)
            layoutManager.ensureLayout(for: container)
        }

        var usedHeight: CGFloat {
            layoutManager.usedRect(for: container).height
        }

        var lineFragmentCount: Int {
            var count = 0
            var glyphIndex = 0
            let glyphCount = layoutManager.numberOfGlyphs
            while glyphIndex < glyphCount {
                var effectiveRange = NSRange(location: 0, length: 0)
                _ = layoutManager.lineFragmentRect(
                    forGlyphAt: glyphIndex,
                    effectiveRange: &effectiveRange
                )
                count += 1
                glyphIndex = NSMaxRange(effectiveRange)
            }
            return count
        }

        /// The WP3 adapter: a point in the FIELD's coordinate space maps to
        /// the stack by scaling y with the ratio of total heights. Exact for
        /// fast tiles because they are single-font, so every line shares one
        /// height in both layouts and the breaks are identical.
        func characterIndex(
            atFieldPoint point: NSPoint,
            fieldHeight: CGFloat
        ) -> Int {
            let scale = fieldHeight > 0 ? usedHeight / fieldHeight : 1
            return characterIndex(
                at: NSPoint(x: point.x, y: point.y * scale)
            )
        }

        func characterIndex(at point: NSPoint) -> Int {
            var fraction: CGFloat = 0
            return layoutManager.characterIndex(
                for: point,
                in: container,
                fractionOfDistanceBetweenInsertionPoints: &fraction
            )
        }

        func probePoint(forCharacterAt index: Int) -> NSPoint {
            Self.probePoint(
                forCharacterAt: index,
                layoutManager: layoutManager,
                container: container
            )
        }

        /// A point just inside the leading edge of the character's glyph, on
        /// its line fragment's vertical center. boundingRect(forGlyphRange:)
        /// is unusable as a probe: for mixed-script/emoji text it reports the
        /// enclosing layout run's rect (tens of points wide), whose midpoint
        /// lands characters away from the probed glyph.
        static func probePoint(
            forCharacterAt index: Int,
            layoutManager: NSLayoutManager,
            container: NSTextContainer
        ) -> NSPoint {
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: index)
            let fragment = layoutManager.lineFragmentRect(
                forGlyphAt: glyphIndex,
                effectiveRange: nil
            )
            let location = layoutManager.location(forGlyphAt: glyphIndex)
            return NSPoint(
                x: fragment.minX + location.x + 1.0,
                y: fragment.midY
            )
        }
    }

    private func makeTextView(
        _ string: NSAttributedString,
        width: CGFloat
    ) -> NSTextView {
        let textView = NSTextView(
            frame: NSRect(x: 0, y: 0, width: width, height: 10)
        )
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.containerSize = NSSize(
            width: width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = false
        textView.textStorage?.setAttributedString(string)
        if let container = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: container)
        }
        return textView
    }

    private func attributedSample(
        _ text: String,
        font: NSFont
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byCharWrapping
        return NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .paragraphStyle: paragraph,
            ]
        )
    }

    private var sampleTexts: [String] {
        [
            (1...220).map(String.init).joined(separator: ", "),
            "Numbers 1, 2, 3 then emoji 🎉👍🏽🧑‍💻 and combining é e\u{0301} "
                + "marks ﬁnal ligatures plus ยาวไทย mixed with more text that "
                + "wraps across several fragments 🚀 and keeps going 400, 401,",
            String(
                repeating: "let value = transcript[index].rowText // 🧵 ",
                count: 12
            ),
        ]
    }

    private var sampleFonts: [NSFont] {
        [
            NSFont.systemFont(ofSize: 13),
            NSFont.systemFont(ofSize: 13 * 1.35),
            NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
        ]
    }

    private let sampleWidths: [CGFloat] = [300, 520, 760]

    func testThrowawayStackMatchesBoundingRectLineBreaks() {
        for text in sampleTexts {
            for font in sampleFonts {
                for width in sampleWidths {
                    let string = attributedSample(text, font: font)
                    let stack = ThrowawayStack(string, width: width)
                    let measured = string.boundingRect(
                        with: NSSize(
                            width: width,
                            height: CGFloat.greatestFiniteMagnitude
                        ),
                        options: [.usesLineFragmentOrigin, .usesFontLeading]
                    )
                    // Per-line heights legitimately differ between
                    // NSStringDrawing and TextKit (16.0 vs 17.0 for SF 13),
                    // so total heights cannot be compared. Line COUNTS can:
                    // equal counts at equal width prove identical wrapping,
                    // which is what makes the y-scaling adapter exact.
                    let singleLine = attributedSample("X", font: font)
                        .boundingRect(
                            with: NSSize(
                                width: width,
                                height: CGFloat.greatestFiniteMagnitude
                            ),
                            options: [
                                .usesLineFragmentOrigin, .usesFontLeading,
                            ]
                        )
                    let fieldLineCount = Int(
                        (measured.height / singleLine.height).rounded()
                    )
                    XCTAssertEqual(
                        stack.lineFragmentCount,
                        fieldLineCount,
                        """
                        Line wrapping diverged between the throwaway TextKit \
                        stack and NSStringDrawing at width \(width), font \
                        \(font.pointSize): the fast-field hit-test strategy \
                        is a NO-GO for this configuration.
                        """
                    )
                }
            }
        }
    }

    func testFieldSpaceProbesResolveThroughTheScalingAdapter() {
        for text in sampleTexts {
            for font in sampleFonts {
                for width in sampleWidths {
                    let string = attributedSample(text, font: font)
                    let stack = ThrowawayStack(string, width: width)
                    let fieldHeight = string.boundingRect(
                        with: NSSize(
                            width: width,
                            height: CGFloat.greatestFiniteMagnitude
                        ),
                        options: [.usesLineFragmentOrigin, .usesFontLeading]
                    ).height

                    var boundaries = text.indices.map {
                        text.utf16.distance(
                            from: text.utf16.startIndex,
                            to: $0.samePosition(in: text.utf16)!
                        )
                    }
                    boundaries.append(text.utf16.count)
                    for position in stride(
                        from: 0,
                        to: boundaries.count - 1,
                        by: 7
                    ) {
                        let start = boundaries[position]
                        let next = boundaries[position + 1]
                        // Build the probe in STACK space, project it into
                        // field space with the inverse scale (what a real
                        // pointer position in the field would be), then
                        // require the adapter to land back in the grapheme.
                        let stackProbe = stack.probePoint(
                            forCharacterAt: start
                        )
                        let scale = stack.usedHeight > 0
                            ? fieldHeight / stack.usedHeight
                            : 1
                        let fieldProbe = NSPoint(
                            x: stackProbe.x,
                            y: stackProbe.y * scale
                        )
                        let hit = stack.characterIndex(
                            atFieldPoint: fieldProbe,
                            fieldHeight: fieldHeight
                        )
                        XCTAssertTrue(
                            (start...next).contains(hit),
                            """
                            Field-space probe missed its grapheme \
                            (\(start)..\(next), got \(hit)) at width \
                            \(width), font \(font.pointSize): the scaling \
                            adapter is a NO-GO for this configuration.
                            """
                        )
                    }
                }
            }
        }
    }

    /// Every selection surface hit-tests with the TextKit stack that renders
    /// it (TextKit cells use their own layout manager; fast fields use the
    /// compatibility-typesetter throwaway stack). The primitive each relies
    /// on is self-fidelity: probing the midpoint of a grapheme's glyphs must
    /// resolve inside that grapheme (insertion-point semantics allow the
    /// following boundary).
    func testHitTestSelfFidelityOnBothSurfaces() {
        for text in sampleTexts {
            for font in sampleFonts {
                for width in sampleWidths {
                    let string = attributedSample(text, font: font)
                    // Grapheme starts in UTF-16, plus the trailing end.
                    var boundaries = text.indices.map {
                        text.utf16.distance(
                            from: text.utf16.startIndex,
                            to: $0.samePosition(in: text.utf16)!
                        )
                    }
                    boundaries.append(text.utf16.count)

                    let stack = ThrowawayStack(string, width: width)
                    let textView = makeTextView(string, width: width)
                    guard let layoutManager = textView.layoutManager,
                          let container = textView.textContainer else {
                        return XCTFail("Text view lost its TextKit stack")
                    }

                    // Probe every 7th grapheme so runs stay fast while
                    // covering emoji, ZWJ sequences, and combining marks.
                    for position in stride(
                        from: 0,
                        to: boundaries.count - 1,
                        by: 7
                    ) {
                        let start = boundaries[position]
                        let next = boundaries[position + 1]

                        let stackIndex = stack.characterIndex(
                            at: stack.probePoint(forCharacterAt: start)
                        )
                        XCTAssertTrue(
                            (start...next).contains(stackIndex),
                            """
                            Fast-field stack hit test left the probed \
                            grapheme (\(start)..\(next), got \(stackIndex)) \
                            at width \(width), font \(font.pointSize): \
                            parity NO-GO.
                            """
                        )

                        var fraction: CGFloat = 0
                        let textViewIndex = layoutManager.characterIndex(
                            for: ThrowawayStack.probePoint(
                                forCharacterAt: start,
                                layoutManager: layoutManager,
                                container: container
                            ),
                            in: container,
                            fractionOfDistanceBetweenInsertionPoints: &fraction
                        )
                        XCTAssertTrue(
                            (start...next).contains(textViewIndex),
                            """
                            NSTextView hit test left the probed grapheme \
                            (\(start)..\(next), got \(textViewIndex)) at \
                            width \(width), font \(font.pointSize): \
                            parity NO-GO.
                            """
                        )
                    }
                }
            }
        }
    }
}
