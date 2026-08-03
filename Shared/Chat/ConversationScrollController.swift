import Foundation
import CoreGraphics

/// The one scroll command a controller event may emit. The view executes it
/// against the transcript's ScrollPosition; nothing else in the app is
/// allowed to move the viewport programmatically.
enum ConversationPinCommand: Equatable {
    /// Transaction-disabled scroll to the content's bottom edge.
    case instant
    /// Animated ease to the bottom edge after a gesture released near it.
    case animatedSettle
    /// Animated ease to the bottom edge for the jump-to-latest control.
    case animatedJump
}

/// Single owner of the transcript's scroll intent.
///
/// The system's `defaultScrollAnchor(.bottom)` is the first-line pinning
/// mechanism; this controller is only the backstop. Its core invariants: it
/// never emits a command while the viewport is measurably at the bottom (so
/// the system anchor stays engaged), never while the user owns the viewport
/// (`.browsing`), and never while a programmatic animation is in flight
/// (`.animating`). State writes are guarded so scroll-frequency inputs cannot
/// invalidate the view when nothing changed.
struct ConversationScrollController: Equatable {
    enum State: Equatable {
        /// Positioning freshly loaded content at the latest item.
        case anchoring
        /// Pinned to the latest content.
        case following
        /// The user owns the viewport; nothing may move it.
        case browsing
        /// A programmatic animated scroll to the bottom is in flight.
        case animating
    }

    static let atBottomTolerance: CGFloat = 8
    static let settleBand: CGFloat = 60

    private(set) var state: State

    /// A transcript whose store already holds items positions correctly on
    /// its first layout (rows parse synchronously and the system anchor
    /// starts at the bottom), so it follows immediately with no anchoring
    /// phase. Anchoring is only for content that loads in while visible.
    init(startsAnchored: Bool = true) {
        state = startsAnchored ? .anchoring : .following
    }

    var isAnchoring: Bool { state == .anchoring }

    var accessibilityValue: String {
        state == .browsing ? "history" : "latest"
    }

    /// Coarse layout change: the at-bottom flag crossed a boundary or the
    /// content height moved. Never fires per scrolled frame.
    mutating func geometryChanged(isAtBottom: Bool) -> ConversationPinCommand? {
        switch state {
        case .anchoring, .following:
            if isAtBottom {
                if state != .following {
                    state = .following
                }
                return nil
            }
            return .instant
        case .animating:
            if isAtBottom {
                state = .following
            }
            return nil
        case .browsing:
            return nil
        }
    }

    /// A user scroll gesture began; the user takes the viewport from any state.
    mutating func userScrollBegan() {
        if state != .browsing {
            state = .browsing
        }
    }

    /// A touch or trackpad gesture (including deceleration) came to rest.
    mutating func userScrollEnded(distanceFromBottom: CGFloat) -> ConversationPinCommand? {
        guard state == .browsing else { return nil }
        if distanceFromBottom <= Self.atBottomTolerance {
            state = .following
            return nil
        }
        if distanceFromBottom <= Self.settleBand {
            state = .animating
            return .animatedSettle
        }
        return nil
    }

    /// A discrete-wheel scrolling burst went quiet. Wheel scrolling pauses
    /// constantly mid-read, so this never emits a pull; it only re-engages
    /// following when the wheel came to rest exactly at the bottom.
    mutating func wheelScrollEnded(isAtBottom: Bool) {
        guard state == .browsing, isAtBottom else { return }
        state = .following
    }

    /// The jump-to-latest control was activated.
    mutating func jumpRequested() -> ConversationPinCommand {
        state = .animating
        return .animatedJump
    }

    /// A programmatic scroll animation finished.
    mutating func animationEnded(distanceFromBottom: CGFloat) -> ConversationPinCommand? {
        guard state == .animating else {
            return geometryChanged(
                isAtBottom: distanceFromBottom <= Self.atBottomTolerance
            )
        }
        state = .following
        if distanceFromBottom <= Self.atBottomTolerance {
            return nil
        }
        return .instant
    }

    /// Fresh conversation content replaced an empty transcript; re-anchor at
    /// the latest item with one deterministic backstop pin.
    mutating func contentLoaded() -> ConversationPinCommand? {
        guard state != .browsing else { return nil }
        state = .anchoring
        return .instant
    }

    /// Failsafe if geometry never confirms the bottom while anchoring, so the
    /// transcript can never stay hidden.
    mutating func completeAnchor() {
        if state == .anchoring {
            state = .following
        }
    }
}
