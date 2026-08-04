import AppKit

/// NSSlider that reports an explicit end-of-gesture commit instead of callers
/// inferring it from NSApp.currentEvent — which is stale (never nil) for
/// accessibility adjustments and misfires nondeterministically.
final class DurationSlider: NSSlider {
    /// Called once when a drag ends on a different stop than it started, or
    /// ~1s after the last VoiceOver increment/decrement so accessibility
    /// users can step through stops without committing each one.
    var onCommit: (() -> Void)?
    private var axCommitTimer: Timer?

    override func mouseDown(with event: NSEvent) {
        let startValue = doubleValue
        super.mouseDown(with: event)  // NSSliderCell tracks the entire drag here
        if doubleValue != startValue {
            onCommit?()
        }
    }

    override func accessibilityPerformIncrement() -> Bool {
        let ok = super.accessibilityPerformIncrement()
        if ok { scheduleAccessibilityCommit() }
        return ok
    }

    override func accessibilityPerformDecrement() -> Bool {
        let ok = super.accessibilityPerformDecrement()
        if ok { scheduleAccessibilityCommit() }
        return ok
    }

    private func scheduleAccessibilityCommit() {
        axCommitTimer?.invalidate()
        let t = Timer(timeInterval: 1.0, repeats: false) { [weak self] _ in
            self?.onCommit?()
        }
        RunLoop.main.add(t, forMode: .common)
        axCommitTimer = t
    }
}
