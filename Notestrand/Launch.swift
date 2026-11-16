import SwiftUI

/// Shown from launch until saved sessions are loaded. It starts as an exact copy of the launch screen
/// (the N mark, same size and place), so the hand-off from iOS is invisible; then colour flows along the strand.
struct SplashView: View {
    /// The launch image's colour; the splash keeps it so the hand-off doesn't change colour.
    static let brand = Color("#2f6fed")
    let leaving: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settled = false

    var body: some View {
        ZStack {
            Color(.systemBackground).opacity(leaving ? 0 : 1)
            TimelineView(.animation(minimumInterval: nil, paused: reduceMotion || !settled)) { timeline in
                let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
                let head = phase * 1.4, tail = head - 0.4 // a 40% highlight that enters at one end and leaves at the other
                ZStack {
                    NStrand().stroke(Self.brand.opacity(settled && !reduceMotion ? 0.22 : 1), style: Self.stroke)
                    if !reduceMotion {
                        NStrand().trim(from: max(0, tail), to: min(1, head)).stroke(Self.brand, style: Self.stroke)
                            .opacity(settled ? 1 : 0)
                    }
                }
            }
            .frame(width: 88, height: 88)
            .scaleEffect(leaving && !reduceMotion ? 1.15 : 1)
            .opacity(leaving ? 0 : 1)
        }
        .ignoresSafeArea()
        .accessibilityElement()
        .accessibilityLabel("Notestrand is loading")
        .onAppear { withAnimation(.easeOut(duration: 0.5)) { settled = true } }
    }

    private static let stroke = StrokeStyle(lineWidth: 11, lineCap: .round, lineJoin: .round)
}

/// Holds the splash over the app until saved data is in, then lets it go.
struct LaunchGate<Content: View>: View {
    @EnvironmentObject var app: AppState
    @ViewBuilder var content: Content
    @State private var minimumShown = false
    @State private var leaving = false
    @State private var gone = false

    var body: some View {
        ZStack {
            content
            if !gone { SplashView(leaving: leaving).zIndex(1) }
        }
        .task {
            // Long enough for the mark to read as a moment rather than a flicker; data loading usually finishes first.
            try? await Task.sleep(nanoseconds: 600_000_000)
            minimumShown = true
            finishIfReady()
        }
        .onChange(of: app.loaded) { _ in finishIfReady() }
    }

    private func finishIfReady() {
        guard app.loaded, minimumShown, !leaving else { return }
        withAnimation(Motion.springOrFade) { leaving = true }
        Task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            gone = true
            app.launched = true
        }
    }
}
