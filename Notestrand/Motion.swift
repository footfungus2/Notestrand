import SwiftUI

/// App-wide motion. Under Reduce Motion the spring is nil, so changes apply without movement.
enum Motion {
    static var reduced: Bool { UIAccessibility.isReduceMotionEnabled }
    /// Critically damped: things that appear, move or resize settle without overshoot.
    static var spring: Animation? { reduced ? nil : .spring(response: 0.4, dampingFraction: 1) }
    /// The spring, or a short fade where Reduce Motion still wants a change to be visible.
    static var springOrFade: Animation { spring ?? .easeOut(duration: 0.2) }
}

/// Press feedback on touch-down for card-like buttons.
struct PressableStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct Entrance: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let index: Int
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            // Reduce Motion keeps the fade and drops the movement.
            .offset(y: shown || reduceMotion ? 0 : 14)
            .onAppear {
                guard !shown else { return }
                let animation = reduceMotion ? Animation.easeOut(duration: 0.2) : Motion.springOrFade.delay(Double(index) * 0.05)
                withAnimation(animation) { shown = true }
            }
    }
}

extension View {
    /// Fades and lifts the view in when it first appears; `index` staggers siblings.
    func entrance(_ index: Int = 0) -> some View { modifier(Entrance(index: index)) }
}

/// Haptics for meaningful moments only: a page change, a connection made, a key refused.
enum Haptics {
    private static var on: Bool { Prefs.d.object(forKey: Prefs.haptics) as? Bool ?? true }
    static func select() { if on { UISelectionFeedbackGenerator().selectionChanged() } }
    static func success() { if on { UINotificationFeedbackGenerator().notificationOccurred(.success) } }
    static func error() { if on { UINotificationFeedbackGenerator().notificationOccurred(.error) } }
}

/// A horizontal shake; animate `shakes` up by one to play it once (used for a refused key).
struct Shake: GeometryEffect {
    var shakes: CGFloat
    var animatableData: CGFloat {
        get { shakes }
        set { shakes = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 7 * sin(shakes * .pi * 4), y: 0))
    }
}

/// 0 → 1 between `start` and `start + length` seconds, smoothstepped: drives the onboarding's looping demos.
func ramp(_ t: Double, _ start: Double, _ length: Double) -> Double {
    let x = min(max((t - start) / length, 0), 1)
    return x * x * (3 - 2 * x)
}
