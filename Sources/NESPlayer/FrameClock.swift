import Foundation
import QuartzCore

#if canImport(AppKit)
import AppKit
#endif

/// Drives the emulator at display refresh, with a timer fallback.
///
/// `CADisplayLink` is the right primitive — it is phase-locked to the display,
/// so frames land exactly when they will be shown. But it has two failure modes
/// that would silently freeze the game:
///
/// - On macOS it is vended by an `NSScreen`, which is unavailable if the app is
///   not yet on a screen.
/// - It pauses when the display sleeps.
///
/// Neither should stop emulation, so this falls back to a timer whenever the
/// display link is unavailable, and watchdogs it to catch a link that stops
/// firing after having started.
@MainActor
final class FrameClock {

    private var displayLink: CADisplayLink?
    private var timer: Timer?
    private var watchdog: Timer?
    private var lastTick = CFAbsoluteTimeGetCurrent()

    private let onTick: () -> Void

    /// Target frame interval. The NES runs at ~60.0988 Hz; 60 is close enough
    /// that no one can hear or see the difference over a play session.
    private let interval = 1.0 / 60.0

    init(onTick: @escaping () -> Void) {
        self.onTick = onTick
    }

    var isRunning: Bool { displayLink != nil || timer != nil }

    func start() {
        guard !isRunning else { return }

        if let link = Self.makeDisplayLink(target: self, selector: #selector(tick)) {
            link.add(to: .main, forMode: .common)
            displayLink = link
            startWatchdog()
        } else {
            startTimer()
        }
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
        timer?.invalidate()
        timer = nil
        watchdog?.invalidate()
        watchdog = nil
    }

    @objc private func tick() {
        lastTick = CFAbsoluteTimeGetCurrent()
        onTick()
    }

    private func startTimer() {
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // .common so the clock keeps running during window resize and menu
        // tracking, which would otherwise stall the game mid-frame.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// If the display link stops delivering — display sleep, or the app moving
    /// off-screen — switch to the timer so the game keeps running.
    private func startWatchdog() {
        watchdog = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.displayLink != nil else { return }
                if CFAbsoluteTimeGetCurrent() - self.lastTick > 0.75 {
                    self.displayLink?.invalidate()
                    self.displayLink = nil
                    self.startTimer()
                }
            }
        }
    }

    private static func makeDisplayLink(target: Any, selector: Selector) -> CADisplayLink? {
        #if canImport(AppKit)
        // Prefer the screen the app is actually on; fall back to any screen.
        let screen = NSApplication.shared.keyWindow?.screen
            ?? NSScreen.main
            ?? NSScreen.screens.first
        return screen?.displayLink(target: target, selector: selector)
        #else
        return CADisplayLink(target: target, selector: selector)
        #endif
    }
}
