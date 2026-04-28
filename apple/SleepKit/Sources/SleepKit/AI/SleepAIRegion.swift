import Foundation

/// Coarse geographic policy retained for old preference migration. The
/// current release exposes one formal model in every region.
///
/// The classification is deliberately conservative: anything that *could*
/// be Mainland China (region "CN") is treated as such.  Hong Kong, Macao
/// and Taiwan are NOT mainland and remain in `.global`.
public enum SleepAIRegion: String, Sendable, Equatable {
    /// Mainland China.
    case mainlandChina
    /// Everywhere else.
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
    /// The formal model policy allows all legacy identifiers to migrate.
    public func allows(_ kind: SleepAIModelKind) -> Bool {
        _ = kind
        return true
    }
}
