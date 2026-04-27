import UIKit

/// Centralised Taptic Engine helpers. Keep generators alive briefly so the
/// engine doesn't re-spin between paired events (prepare → fire pattern is
/// what gives Apple's UI its characteristic "solid" 3D feel rather than the
/// thin buzz you get from one-shot generators).
@MainActor
public enum Haptics {

    // MARK: Impact (CoreHaptics under the hood on phones with the Taptic
    // Engine). `.rigid` is the dense, ceramic-feeling tap that Apple uses
    // for primary buttons in iOS 17+.

    /// Sharp ceramic tap. Use for primary CTAs, the AI composer send,
    /// "Start tracking", suggestion-card selection.
    public static func tapRigid(intensity: CGFloat = 1.0) {
        let g = UIImpactFeedbackGenerator(style: .rigid)
        g.prepare()
        g.impactOccurred(intensity: intensity)
    }

    /// Soft cushioned tap. Use for secondary actions where rigid would
    /// feel aggressive (toggling a row, opening a sheet).
    public static func tapSoft(intensity: CGFloat = 0.85) {
        let g = UIImpactFeedbackGenerator(style: .soft)
        g.prepare()
        g.impactOccurred(intensity: intensity)
    }

    /// Heavy thump. Reserved for "consequential" moments (end session,
    /// accept legal, alarm fire).
    public static func tapHeavy() {
        let g = UIImpactFeedbackGenerator(style: .heavy)
        g.prepare()
        g.impactOccurred()
    }

    /// Tab / segment / card selection drift. Light tick.
    public static func selection() {
        let g = UISelectionFeedbackGenerator()
        g.prepare()
        g.selectionChanged()
    }

    /// Success ding (e.g. message streamed in, settings saved).
    public static func success() {
        let g = UINotificationFeedbackGenerator()
        g.prepare()
        g.notificationOccurred(.success)
    }

    /// Warning. Use for blocked actions / refusals.
    public static func warning() {
        let g = UINotificationFeedbackGenerator()
        g.prepare()
        g.notificationOccurred(.warning)
    }

    /// Error. Use for hard failures only.
    public static func error() {
        let g = UINotificationFeedbackGenerator()
        g.prepare()
        g.notificationOccurred(.error)
    }
}
