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

    // Step exactly one stop per accessibility adjustment; at the bounds the
    // step is a no-op and must not fire the action or schedule a commit.
    override func accessibilityPerformIncrement() -> Bool {
        stepByOne(1)
    }

    override func accessibilityPerformDecrement() -> Bool {
        stepByOne(-1)
    }

    private func stepByOne(_ delta: Double) -> Bool {
        let clamped = min(max((doubleValue + delta).rounded(), minValue), maxValue)
        guard clamped != doubleValue else { return false }
        doubleValue = clamped
        sendAction(action, to: target)
        scheduleAccessibilityCommit()
        return true
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
