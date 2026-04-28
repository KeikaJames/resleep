import Foundation

/// Catalog of the on-device LLM Circadia ships.
///
/// Release policy: the app exposes a single formal Sleep AI model backed
/// by Qwen3-4B. Older tier identifiers remain supported only so existing
/// preferences and side-loaded folders do not crash during migration.

public enum SleepAIModelKind: String, Codable, Sendable, CaseIterable, Equatable {
    /// Legacy Gemma identifier. Migrates to the formal model.
    case gemma
    /// Legacy Qwen 1.7B identifier. Migrates to the formal model.
    case qwenInstant
    /// Internal identifier for the formal Sleep AI model.
    case qwenPro
}

/// Legacy brand tier. Kept so stored user defaults decode cleanly.
public enum SleepAIBrandTier: String, Codable, Sendable, CaseIterable, Equatable {
    case instant
    case pro
}

public struct SleepAIModelTier: Codable, Equatable, Sendable, Identifiable {
    public let brand: SleepAIBrandTier
    public let kind: SleepAIModelKind
    public let bundleDirName: String
    public let displayName: String
    public let englishSubtitle: String
    public let chineseSubtitle: String
    public let approximateMB: Int
    public let symbol: String

    public var id: String { kind.rawValue }

    public func subtitle(chinese: Bool) -> String {
        chinese ? chineseSubtitle : englishSubtitle
    }
}

public enum SleepAIModelCatalog {

    public static func kind(for brand: SleepAIBrandTier, in region: SleepAIRegion) -> SleepAIModelKind {
        _ = brand
        _ = region
        return .qwenPro
    }

    public static func descriptor(for brand: SleepAIBrandTier, in region: SleepAIRegion) -> SleepAIModelTier {
        _ = brand
        return descriptor(for: .qwenPro, in: region)
    }

    public static func descriptor(for kind: SleepAIModelKind) -> SleepAIModelTier {
        descriptor(for: kind, in: SleepAIRegion.current)
    }

    public static func descriptor(for kind: SleepAIModelKind, in region: SleepAIRegion) -> SleepAIModelTier {
        _ = kind
        _ = region
        return SleepAIModelTier(
            brand: .pro,
            kind: .qwenPro,
            bundleDirName: bundleDirName(for: .qwenPro),
            displayName: "Circadia AI",
            englishSubtitle: "On-device sleep assistant",
            chineseSubtitle: "本机睡眠助手",
            approximateMB: 2500,
            symbol: "sparkles"
        )
    }

    /// The app now offers one model. If it is not bundled in a simulator or
    /// fresh clone, still return the descriptor so the UI has a stable label;
    /// the service layer falls back to the deterministic rule-based assistant
    /// if the weights are missing.
    public static func available(in region: SleepAIRegion) -> [SleepAIModelTier] {
        [descriptor(for: .qwenPro, in: region)]
    }

    public static func isBundled(_ tier: SleepAIModelTier) -> Bool {
        let fm = FileManager.default
        if let url = Bundle.main.url(forResource: tier.bundleDirName, withExtension: nil),
           fm.fileExists(atPath: url.path) {
            return true
        }
        if let docs = try? fm.url(for: .documentDirectory, in: .userDomainMask,
                                  appropriateFor: nil, create: false) {
            let candidate = docs
                .appendingPathComponent("Models", isDirectory: true)
                .appendingPathComponent(tier.bundleDirName, isDirectory: true)
            if fm.fileExists(atPath: candidate.path) {
                return true
            }
        }
        return false
    }

    public static func firstAvailable(in region: SleepAIRegion) -> SleepAIModelTier {
        descriptor(for: .qwenPro, in: region)
    }

    public static func defaultBrand(for region: SleepAIRegion) -> SleepAIBrandTier {
        _ = region
        return .pro
    }

    public static func defaultKind(for region: SleepAIRegion) -> SleepAIModelKind {
        _ = region
        return .qwenPro
    }

    private static func bundleDirName(for kind: SleepAIModelKind) -> String {
        switch kind {
        case .gemma: return "circadia-sleep-2b-4bit"
        case .qwenInstant: return "circadia-sleep-qwen-1_7b-4bit"
        case .qwenPro: return "circadia-sleep-qwen-4b-4bit"
        }
    }
}
