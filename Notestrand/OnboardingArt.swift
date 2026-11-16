import SwiftUI

// Illustrations for the onboarding. Each is a pure function of time inside a TimelineView, so it can't
// drift out of step, pauses when off screen, and shows its finished state under Reduce Motion.

/// Soft ribbons drifting behind the onboarding. They shift sideways a little as pages change.
struct StrandsBackground: View {
    let page: Int
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || !active)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { ctx, size in
                for i in 0..<3 {
                    var path = Path()
                    let mid = size.height * (0.22 + 0.28 * Double(i))
                    let amp = 22 + 10 * Double(i), wave = size.width * (0.9 + 0.25 * Double(i))
                    let phase = (reduceMotion ? 0 : t) * (0.18 + 0.07 * Double(i)) + Double(i) * 1.7
                    for step in 0...48 {
                        // Wider than the screen: the canvas slides left by up to 4 × 28pt as pages change.
                        let x = -60 + (size.width + 200) * Double(step) / 48
                        let y = mid + amp * sin(x / wave * 2 * .pi + phase)
                        step == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
                    }
                    ctx.stroke(path, with: .color(.accentColor.opacity(0.055)), style: StrokeStyle(lineWidth: 30 - 6 * Double(i), lineCap: .round))
                }
            }
        }
        .offset(x: reduceMotion ? 0 : -CGFloat(page) * 28)
        .accessibilityHidden(true)
    }
}

/// The N with a bright section of colour flowing along it end to end.
struct FlowingN: View {
    var lineWidth: CGFloat = 3
    var active = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: reduceMotion || !active)) { timeline in
            let phase = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.8) / 1.8
            let head = phase * 1.4, tail = head - 0.4
            ZStack {
                NStrand().stroke(Color.accentColor.opacity(reduceMotion ? 1 : 0.22), style: style)
                if !reduceMotion {
                    NStrand().trim(from: max(0, tail), to: min(1, head)).stroke(Color.accentColor, style: style)
                }
            }
        }
    }

    private var style: StrokeStyle { StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round) }
}

/// Welcome hero: the logo writes itself once, then colour starts flowing through it.
struct WelcomeMark: View {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawn = false

    var body: some View {
        ZStack {
            if drawn && !reduceMotion {
                FlowingN(lineWidth: 11, active: active).transition(.opacity)
            } else {
                NStrand()
                    .trim(from: 0, to: drawn || reduceMotion ? 1 : 0)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 11, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: 92, height: 92)
        .padding(30)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 36, style: .continuous))
        .accessibilityHidden(true)
        .onAppear {
            guard !drawn, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.0).delay(0.2)) { drawn = true }
        }
    }
}

enum DemoMode: Int, CaseIterable, Identifiable {
    case teach, practice, chat
    var id: Int { rawValue }
    var title: String { ["Teach", "Practice", "Chat"][rawValue] }
    var symbol: String { ["graduationcap", "pencil.and.outline", "bubble.left.and.bubble.right"][rawValue] }
    var blurb: String {
        [
            "Finds out what you already know with a few questions, plans a route to your goal, and checks every step.",
            "Sets problems on what you've learned, with hints when you're stuck, and live graphs you can play with.",
            "A normal assistant that searches the web, reads your notes, and names its sources.",
        ][rawValue]
    }
    var spoken: String {
        [
            "Demo: a question is answered with 80 percent confidence, marked correct, and the lesson plan advances.",
            "Demo: a break-even chart where moving the price slider moves the break-even point.",
            "Demo: a question gets an answer with two sources.",
        ][rawValue]
    }
}

/// The looping demo card for one mode.
struct ModeDemo: View {
    let mode: DemoMode
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: reduceMotion || !active)) { timeline in
            // Under Reduce Motion each demo is held at its most telling moment.
            let t = reduceMotion ? 4.6 : timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 6)
            Group {
                switch mode {
                case .teach: TeachDemo(t: t)
                case .practice: PracticeDemo(t: reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate)
                case .chat: ChatDemo(t: t)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, minHeight: 250, alignment: .topLeading)
        }
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color(.separator).opacity(0.4), lineWidth: 0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(mode.spoken)
    }
}

private struct TeachDemo: View {
    let t: Double
    private let options = ["8", "11", "14"]

    var body: some View {
        let picked = ramp(t, 1.0, 0.3), correct = ramp(t, 2.5, 0.3), fade = 1 - ramp(t, 5.55, 0.4)
        VStack(alignment: .leading, spacing: 10) {
            Text("CHECK").font(.caption2.weight(.bold)).foregroundColor(.accentColor)
            Text("What is 2x + 3 when x = 4?").font(.subheadline.weight(.semibold))
            ForEach(Array(options.enumerated()), id: \.offset) { i, o in
                let isAnswer = i == 1
                HStack {
                    Text(o).font(.subheadline.monospacedDigit())
                    Spacer()
                    if isAnswer {
                        Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                            .scaleEffect(0.4 + 0.6 * correct).opacity(correct)
                    }
                }
                .padding(.horizontal, 12).frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.accentColor.opacity(isAnswer ? 0.14 * picked : 0)))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(
                    isAnswer ? (correct > 0.5 ? Color.green : Color.accentColor).opacity(0.25 + 0.75 * picked) : Color(.separator),
                    lineWidth: isAnswer ? 1.5 : 0.5))
                .opacity(ramp(t, 0.1 + Double(i) * 0.12, 0.3))
            }
            HStack(spacing: 8) {
                Text("How sure?").font(.caption).foregroundColor(.secondary)
                GeometryReader { g in
                    Capsule().fill(Color(.systemGray5))
                        .overlay(alignment: .leading) { Capsule().fill(Color.accentColor).frame(width: g.size.width * 0.8 * ramp(t, 1.5, 0.8)) }
                }
                .frame(height: 6)
                Text("\(Int(80 * ramp(t, 1.5, 0.8)))%").font(.caption.monospacedDigit()).foregroundColor(.secondary).frame(width: 34, alignment: .trailing)
            }
            HStack(spacing: 0) {
                ForEach(0..<3) { i in
                    let lit = ramp(t, 3.2 + Double(i) * 0.45, 0.3)
                    if i > 0 { Rectangle().fill(Color.accentColor.opacity(0.2 + 0.8 * lit)).frame(height: 2) }
                    Text(["Basics", "Equations", "Graphs"][i])
                        .font(.caption2.weight(.semibold))
                        .foregroundColor(lit > 0.5 ? .white : .secondary)
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(Capsule().fill(Color.accentColor.opacity(lit)))
                        .overlay(Capsule().stroke(Color.accentColor.opacity(0.5), lineWidth: 1))
                        .scaleEffect(1 + 0.08 * sin(.pi * lit))
                }
            }
            .padding(.top, 4)
        }
        .opacity(fade)
    }
}

/// A break-even chart whose price slider moves by itself; the break-even point follows.
private struct PracticeDemo: View {
    let t: Double

    var body: some View {
        // Chosen so break-even stays inside the 0–1000 unit chart across the whole price range (214–750 units).
        let price = 15 + 5 * sin(t * 0.9), vc = 6.0, fc = 3000.0
        let bep = fc / (price - vc)
        VStack(alignment: .leading, spacing: 10) {
            Text("PROBLEM").font(.caption2.weight(.bold)).foregroundColor(.accentColor)
            Text("Where does the firm break even?").font(.subheadline.weight(.semibold))
            GeometryReader { g in
                let w = g.size.width, h = g.size.height
                let x = { (u: Double) in CGFloat(u / 1000) * w }, y = { (v: Double) in h - CGFloat(v / 22000) * h }
                ZStack(alignment: .topLeading) {
                    Path { p in p.move(to: CGPoint(x: 0, y: 0)); p.addLine(to: CGPoint(x: 0, y: h)); p.addLine(to: CGPoint(x: w, y: h)) }
                        .stroke(Color(.separator), lineWidth: 1)
                    Path { p in p.move(to: CGPoint(x: 0, y: y(fc))); p.addLine(to: CGPoint(x: w, y: y(fc))) }
                        .stroke(Color.orange.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    Path { p in p.move(to: CGPoint(x: 0, y: y(fc))); p.addLine(to: CGPoint(x: w, y: y(fc + vc * 1000))) }
                        .stroke(Color.orange, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    Path { p in p.move(to: CGPoint(x: 0, y: h)); p.addLine(to: CGPoint(x: w, y: y(price * 1000))) }
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    Circle().fill(Color.yellow).frame(width: 12, height: 12)
                        .overlay(Circle().stroke(Color.primary.opacity(0.6), lineWidth: 1))
                        .position(x: x(bep), y: y(price * bep))
                }
            }
            .frame(height: 104)
            .clipped()
            HStack(spacing: 10) {
                Text("Price £\(Int(price.rounded()))").font(.caption.monospacedDigit()).frame(width: 64, alignment: .leading)
                GeometryReader { g in
                    Capsule().fill(Color(.systemGray5)).frame(height: 4)
                        .overlay(alignment: .leading) {
                            Circle().fill(Color.white).frame(width: 18, height: 18).shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                                .offset(x: (g.size.width - 18) * CGFloat((price - 10) / 10))
                        }
                        .frame(maxHeight: .infinity)
                }
                .frame(height: 18)
            }
            Text("Break-even: \(Int(bep.rounded())) units").font(.caption.weight(.semibold).monospacedDigit())
        }
    }
}

private struct ChatDemo: View {
    let t: Double

    var body: some View {
        let asked = ramp(t, 0.2, 0.4), thinking = ramp(t, 0.8, 0.25) * (1 - ramp(t, 1.9, 0.2))
        let fade = 1 - ramp(t, 5.55, 0.4)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Spacer()
                Text("Why did the Roman Empire fall?")
                    .font(.subheadline)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .opacity(asked).offset(y: 10 * (1 - asked))
            if thinking > 0.01 {
                HStack(spacing: 8) {
                    FlowingN(lineWidth: 2.4).frame(width: 18, height: 18)
                    Text("Thinking…").font(.caption).foregroundColor(.secondary)
                }
                .opacity(thinking)
            }
            VStack(alignment: .leading, spacing: 7) {
                ForEach(0..<4) { i in
                    GeometryReader { g in
                        Capsule().fill(Color(.systemGray4))
                            .frame(width: g.size.width * [0.95, 0.88, 0.92, 0.55][i] * ramp(t, 2.0 + Double(i) * 0.3, 0.45))
                    }
                    .frame(height: 8)
                }
            }
            HStack(spacing: 6) {
                ForEach(0..<2) { i in
                    let shown = ramp(t, 3.5 + Double(i) * 0.3, 0.3)
                    Label(["britannica.com", "en.wikipedia.org"][i], systemImage: "link")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .background(Capsule().fill(Color(.tertiarySystemBackground)))
                        .scaleEffect(0.7 + 0.3 * shown).opacity(shown)
                }
            }
        }
        .opacity(fade)
    }
}

/// Notes page hero: notes drift gently and link up to the N when the page arrives.
struct NotesGraph: View {
    let active: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var linked = false
    private let notes = ["Biology", "Exam notes", "Memory", "Revision", "Lectures", "Ideas"]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || !active)) { timeline in
            let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
            GeometryReader { g in
                let c = CGPoint(x: g.size.width / 2, y: g.size.height / 2)
                let spots = notes.indices.map { i -> CGPoint in
                    let a = Double(i) / Double(notes.count) * 2 * .pi - .pi / 2
                    let r = min(g.size.width * 0.42, 150.0), drift = 5 * sin(t * 0.8 + Double(i))
                    return CGPoint(x: c.x + CGFloat(cos(a) * (r + drift)), y: c.y + CGFloat(sin(a) * (r * 0.62 + drift)))
                }
                ZStack {
                    ForEach(notes.indices, id: \.self) { i in
                        Path { p in p.move(to: c); p.addLine(to: spots[i]) }
                            .trim(from: 0, to: linked ? 1 : 0)
                            .stroke(Color.accentColor.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                            .animation(reduceMotion ? nil : .easeOut(duration: 0.55).delay(0.15 + Double(i) * 0.08), value: linked)
                    }
                    ForEach(notes.indices, id: \.self) { i in
                        Label(notes[i], systemImage: "doc.text")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Capsule().fill(Color(.secondarySystemBackground)))
                            .overlay(Capsule().stroke(Color(.separator).opacity(0.5), lineWidth: 0.5))
                            .position(spots[i])
                    }
                    FlowingN(lineWidth: 4, active: active)
                        .frame(width: 34, height: 34)
                        .padding(14)
                        .background(Circle().fill(Color(.systemBackground)))
                        .overlay(Circle().stroke(Color.accentColor.opacity(0.5), lineWidth: 1.5))
                        .position(c)
                }
            }
        }
        .frame(height: 240)
        .accessibilityHidden(true)
        .onChange(of: active) { if $0 { linked = true } }
        .onAppear { if active { linked = true } }
    }
}
