import Foundation

/// Coarse geographic policy used to decide which on-device LLM is allowed
/// to run. We rely only on `Locale` signals — never a network probe — so
/// the result is stable, offline, and respects iOS region settings.
///
/// The classification is deliberately conservative: anything that *could*
/// be Mainland China (region "CN") is treated as such.  Hong Kong, Macao
/// and Taiwan are NOT mainland and remain in `.global`.
public enum SleepAIRegion: String, Sendable, Equatable {
    /// Mainland China. Gemma weights are not authorised in this region;
    /// only Qwen-based models are offered.
    case mainlandChina
    /// Everywhere else — full model catalogue (Gemma + Qwen) is offered.
    case global

    /// Resolves the current region from `Locale.current`. The result is
    /// computed every call (cheap) so users who change iOS region get the
    /// right behaviour after a relaunch.
    public static var current: SleepAIRegion {
        let id: String?
        if #available(iOS 16.0, watchOS 9.0, *) {
            id = Locale.current.region?.identifier
        } else {
            id = Locale.current.regionCode
        }
        guard let id else { return .global }
        return id.uppercased() == "CN" ? .mainlandChina : .global
    }

    /// True when the model `kind` is allowed to be loaded in this region.
    /// Use this both to filter the picker and to refuse silently-jailbroken
    /// states (e.g. a UserDefaults value persisted in another region).
    public func allows(_ kind: SleepAIModelKind) -> Bool {
        switch self {
        case .global:
            return true
        case .mainlandChina:
            return kind != .gemma
        }
    }
}
