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

    // Step exactly one stop per accessibility adjustment — the tickless
    // track has no intrinsic step, so don't rely on NSSlider's default.
    override func accessibilityPerformIncrement() -> Bool {
        stepByOne(1)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        stepByOne(-1)
        return true
    }

    private func stepByOne(_ delta: Double) {
        doubleValue = min(max((doubleValue + delta).rounded(), minValue), maxValue)
        sendAction(action, to: target)
        scheduleAccessibilityCommit()
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
