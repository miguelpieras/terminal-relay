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
/// mechanism; this controller is only the backstop. Its core invariant: it
/// never emits a command while the viewport is measurably at the bottom, so
/// the system anchor stays engaged, and it never emits a command while the
/// user owns the viewport (`.browsing`) or while a programmatic animation is
/// in flight (`.animating`).
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

    private(set) var state: State = .anchoring

    var isAnchoring: Bool { state == .anchoring }

    var accessibilityValue: String {
        state == .browsing ? "history" : "latest"
    }

    /// Layout geometry changed (scrolling, content growth, resize).
    mutating func geometryChanged(distanceFromBottom: CGFloat) -> ConversationPinCommand? {
        switch state {
        case .anchoring, .following:
            if distanceFromBottom <= Self.atBottomTolerance {
                state = .following
                return nil
            }
            return .instant
        case .animating:
            if distanceFromBottom <= Self.atBottomTolerance {
                state = .following
            }
            return nil
        case .browsing:
            return nil
        }
    }

    /// A user scroll gesture began; the user takes the viewport from any state.
    mutating func userScrollBegan() {
        state = .browsing
    }

    /// A user scroll gesture (including deceleration) came to rest.
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

    /// The jump-to-latest control was activated.
    mutating func jumpRequested() -> ConversationPinCommand {
        state = .animating
        return .animatedJump
    }

    /// A programmatic scroll animation finished.
    mutating func animationEnded(distanceFromBottom: CGFloat) -> ConversationPinCommand? {
        guard state == .animating else {
            return geometryChanged(distanceFromBottom: distanceFromBottom)
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
