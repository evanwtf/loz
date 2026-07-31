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
    /// When a frame was last actually emulated, as opposed to when the display
    /// link last fired. These differ on a display refreshing faster than 60 Hz.
    private var lastEmulatedFrame = CFAbsoluteTimeGetCurrent() - 1

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
            // Pin to 60 Hz. A display link defaults to the display's maximum
            // rate, so on a ProMotion device it fires at 120 — and because each
            // callback steps a whole NES frame, the game ran at double speed
            // while doing twice the render work.
            //
            // The second effect is worse than the first. Two full frames of
            // emulation plus two CGImage builds per display refresh saturates
            // the main thread, and once it is saturated the run loop stops
            // servicing touches promptly: the picture keeps moving because
            // display link callbacks are privileged, but a tap can sit unread
            // for seconds. "The game runs but input lags badly" is exactly what
            // that looks like from the outside.
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: 60, maximum: 60, preferred: 60)
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
        let now = CFAbsoluteTimeGetCurrent()
        // Watchdog liveness is about the link firing at all, so record it even
        // on refreshes where no frame is emulated.
        lastTick = now

        // Pace emulation to 60 Hz whatever rate the link actually delivers.
        // `preferredFrameRateRange` is a request, not a guarantee, and a clock
        // that emulates once per refresh silently changes the speed of the game
        // depending on the display it is attached to. The tolerance absorbs
        // ordinary jitter so a frame arriving slightly early is not dropped.
        guard now - lastEmulatedFrame >= interval * 0.9 else { return }
        lastEmulatedFrame = now
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
