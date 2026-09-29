import UIKit

/// Feedback for deliberate controls only. Automatic song changes stay silent.
@MainActor
enum ListeningHaptics {
    private static let preferenceKey = "listeningHapticsEnabled"
    private static let selection = UISelectionFeedbackGenerator()
    private static let softImpact = UIImpactFeedbackGenerator(style: .soft)
    private static let crispImpact = UIImpactFeedbackGenerator(style: .rigid)
    private static let notification = UINotificationFeedbackGenerator()
    private static var lastEmission = -Double.infinity

    static var enabled: Bool {
        get {
            guard UserDefaults.standard.object(forKey: preferenceKey) != nil else { return true }
            return UserDefaults.standard.bool(forKey: preferenceKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: preferenceKey) }
    }

    static func select() {
        emit(using: selection) { selection.selectionChanged() }
    }

    static func playPause() {
        emit(using: softImpact) { softImpact.impactOccurred(intensity: 0.55) }
    }

    static func next() {
        emit(using: crispImpact) { crispImpact.impactOccurred(intensity: 0.6) }
    }

    static func like() {
        emit(using: softImpact) { softImpact.impactOccurred(intensity: 0.8) }
    }

    /// Call when the user releases the scrubber, never for each progress update.
    static func seekEnded() {
        emit(using: selection) { selection.selectionChanged() }
    }

    static func success() {
        emit(using: notification) { notification.notificationOccurred(.success) }
    }

    private static func emit(using generator: UIFeedbackGenerator, action: () -> Void) {
        guard enabled, UIApplication.shared.applicationState == .active else { return }
        let now = ProcessInfo.processInfo.systemUptime
        // Coalesce duplicate gesture callbacks and adjacent controls into one tap.
        guard now - lastEmission >= 0.15 else { return }
        lastEmission = now
        // UIKit handles unsupported hardware without requiring an iPad special case.
        generator.prepare()
        action()
    }
}
