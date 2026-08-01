import Foundation
import QuartzCore
import SwiftUI

#if os(iOS)

    /// Tap as fast as you can for fifteen seconds.
    ///
    /// Exists because the fault being chased is unusually hard to demonstrate.
    /// Every other instrument here records a press only once it has arrived, so
    /// none of them can show the delay *in front of* the press — a fair
    /// objection, and the reason this became necessary.
    ///
    /// A burst of taps splits the possibilities apart in one run. If taps are
    /// being lost, the count is far below what a thumb can do. If they are all
    /// arriving but the screen is stalling, the count is high, delivery is
    /// sub-millisecond, and `shown` collapses while `gap` grows — which is
    /// exactly what a screen recording caught: the picture unchanged for twenty
    /// seconds while the emulator reported a steady 60 fps.
    ///
    /// The game keeps running underneath, deliberately. A test conducted with
    /// the emulator paused would remove the very load being measured.
    struct TapTest: View {
        let host: EmulatorHost
        @Binding var isPresented: Bool

        static let duration: Double = 15

        /// When each tap reached the handler, and how late it was.
        @State private var tapTimes: [CFAbsoluteTime] = []
        @State private var latencies: [Double] = []
        @State private var startedAt: CFAbsoluteTime?
        @State private var elapsed: Double = 0
        @State private var finished = false
        @State private var touchDown = false

        /// Presentation counters captured at the start, so the run can be
        /// reported as a delta rather than a lifetime total.
        @State private var framesShownAtStart = 0
        @State private var framesMadeAtStart = 0

        /// Drives the countdown from the run loop rather than from drawing.
        /// A timer still fires when the display is stalled, which is precisely
        /// the condition under test — a clock that depended on rendering would
        /// stop exactly when it mattered.
        private let tick = Timer.publish(every: 0.05, on: .main, in: .common)
            .autoconnect()

        var body: some View {
            ZStack {
                // Opaque: the diagnostics readout and the game both sit
                // underneath, and reading a tap count through them is needless
                // work for the one person trying to count taps.
                Color.black.ignoresSafeArea()

                VStack(spacing: 18) {
                    header
                    if finished { results } else { target }
                }
                .padding(24)
                .frame(maxWidth: 460)
            }
            .onReceive(tick) { _ in
                guard let startedAt, !finished else { return }
                elapsed = CFAbsoluteTimeGetCurrent() - startedAt
                if elapsed >= Self.duration { finish() }
            }
        }

        // MARK: Pieces

        private var header: some View {
            HStack {
                Text(finished ? "Result" : "Tap as fast as you can")
                    .font(.headline)
                Spacer()
                Button {
                    isPresented = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .foregroundStyle(.white)
        }

        private var target: some View {
            VStack(spacing: 14) {
                Text(startedAt == nil
                    ? "15 seconds, starting on your first tap"
                    : String(format: "%.1fs left", max(0, Self.duration - elapsed)))
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.7))

                // The count is the honest part of the display: if the number
                // is not keeping up with the thumb, that is the finding.
                Text("\(tapTimes.count)")
                    .font(.system(size: 72, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .contentTransition(.numericText())

                RoundedRectangle(cornerRadius: 24)
                    .fill(touchDown ? Color.accentColor : Color.white.opacity(0.16))
                    .overlay(
                        Text("TAP HERE")
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.85)))
                    .frame(height: 240)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard !touchDown, !finished else { return }
                                touchDown = true
                                record(eventTime: value.time)
                            }
                            .onEnded { _ in touchDown = false })
            }
        }

        private var results: some View {
            let stats = summary()
            return VStack(alignment: .leading, spacing: 8) {
                ForEach(stats, id: \.label) { row in
                    HStack {
                        Text(row.label)
                            .foregroundStyle(.white.opacity(0.65))
                        Spacer()
                        Text(row.value)
                            .foregroundStyle(row.alarming ? .red : .green)
                    }
                    .font(.system(.footnote, design: .monospaced))
                }

                Text(verdict())
                    .font(.footnote)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)

                HStack {
                    Button("Again") { reset() }
                    Spacer()
                    Button("Done") { isPresented = false }
                }
                .font(.callout.weight(.semibold))
                .padding(.top, 10)
            }
        }

        // MARK: Recording

        private func record(eventTime: Date) {
            let now = CFAbsoluteTimeGetCurrent()
            if startedAt == nil {
                startedAt = now
                framesShownAtStart = host.frames.presented
                framesMadeAtStart = host.frames.produced
            }
            tapTimes.append(now)
            latencies.append(max(0, Date().timeIntervalSince(eventTime) * 1000))
            Haptics.action()
        }

        private func finish() {
            finished = true
            let taps = tapTimes.count
            let shown = host.frames.presented - framesShownAtStart
            let made = host.frames.produced - framesMadeAtStart
            Log.ui.notice("""
            tap test: \(taps, privacy: .public) taps in \
            \(Self.duration, format: .fixed(precision: 0), privacy: .public)s, \
            frames made \(made, privacy: .public) shown \(shown, privacy: .public)
            """)
        }

        private func reset() {
            tapTimes = []
            latencies = []
            startedAt = nil
            elapsed = 0
            finished = false
        }

        // MARK: Reporting

        private struct Row {
            let label: String
            let value: String
            var alarming = false
        }

        /// Longest silence between consecutive taps. A thumb tapping steadily
        /// produces a tight spread, so an outlier here is the app stalling
        /// rather than the hand pausing.
        private var worstGapMS: Double {
            guard tapTimes.count > 1 else { return 0 }
            return (1..<tapTimes.count)
                .map { (tapTimes[$0] - tapTimes[$0 - 1]) * 1000 }
                .max() ?? 0
        }

        private func summary() -> [Row] {
            let taps = tapTimes.count
            let perSecond = Double(taps) / Self.duration
            let shown = host.frames.presented - framesShownAtStart
            let made = host.frames.produced - framesMadeAtStart
            let shownPerSecond = Double(shown) / Self.duration
            let worstLatency = latencies.max() ?? 0
            let meanLatency = latencies.isEmpty
                ? 0 : latencies.reduce(0, +) / Double(latencies.count)

            return [
                Row(label: "taps", value: "\(taps)"),
                Row(label: "taps/sec",
                    value: String(format: "%.1f", perSecond),
                    alarming: perSecond < 3),
                Row(label: "delivery mean",
                    value: String(format: "%.1f ms", meanLatency),
                    alarming: meanLatency > 50),
                Row(label: "delivery worst",
                    value: String(format: "%.0f ms", worstLatency),
                    alarming: worstLatency > 100),
                Row(label: "longest gap",
                    value: String(format: "%.0f ms", worstGapMS),
                    alarming: worstGapMS > 500),
                Row(label: "frames emulated", value: "\(made)"),
                Row(label: "frames shown",
                    value: "\(shown)",
                    alarming: shownPerSecond < 45),
                Row(label: "shown/sec",
                    value: String(format: "%.1f", shownPerSecond),
                    alarming: shownPerSecond < 45),
            ]
        }

        /// Says which of the two failure modes the numbers describe, so the
        /// result does not need interpreting by whoever ran it.
        private func verdict() -> String {
            let shown = host.frames.presented - framesShownAtStart
            let shownPerSecond = Double(shown) / Self.duration
            let worstLatency = latencies.max() ?? 0

            if tapTimes.count < 15 {
                return "Too few taps to judge. Run it again and tap hard."
            }
            if shownPerSecond < 45, worstLatency < 100 {
                return """
                Input is fine — every tap arrived promptly. The display is the \
                problem: frames were emulated far faster than they were shown, \
                so what you press happens and you see it late.
                """
            }
            if worstLatency >= 100 {
                return """
                Taps are arriving late, before any drawing happens. The delay \
                is in touch delivery, not in rendering.
                """
            }
            return "Input and display both healthy over this run."
        }
    }

#endif
