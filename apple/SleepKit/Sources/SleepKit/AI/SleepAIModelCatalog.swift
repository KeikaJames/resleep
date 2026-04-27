import Foundation

/// Catalog of the on-device LLM tiers Circadia ships. Each entry maps to:
///   • A weights *directory name* (used by the build phase that embeds the
///     model into the .app bundle, and by `MLXSleepAIService` to locate
///     them at runtime).
///   • A *display name* + *tier badge* shown in the model picker.
///   • A regional policy (`SleepAIRegion.allows(_:)`) that decides whether
///     this tier is offered in the picker.
///
/// Adding a new tier is one line in `all`; the rest of the app picks it up.

public enum SleepAIModelKind: String, Codable, Sendable, CaseIterable, Equatable {
    /// Google DeepMind's Gemma-2-2B-IT, 4-bit, with a Circadia LoRA adapter
    /// fused in. Default in regions outside Mainland China.
    case gemma
    /// Alibaba Tongyi Lab Qwen3-1.7B-Instruct, 4-bit, sleep-only LoRA-tuned.
    /// Branded as **Instant** — fast, light footprint.
    case qwenInstant
    /// Alibaba Tongyi Lab Qwen3-4B-Instruct, 4-bit, sleep-only LoRA-tuned.
    /// Branded as **Pro** — larger, higher quality, slower first-token.
    case qwenPro
}

/// Static metadata describing how each tier is presented and where its
/// weights live on disk.
public struct SleepAIModelTier: Codable, Equatable, Sendable, Identifiable {
    public let kind: SleepAIModelKind
    /// Subdirectory name *inside the .app bundle* and on disk under
    /// `Documents/Models/`. Stable across renames so existing installs keep
    /// finding their weights.
    public let bundleDirName: String
    /// Short brand name in English: "Gemma 3n" / "Instant" / "Pro".
    public let englishName: String
    /// Short brand name in zh-Hans: "Gemma 3n" / "Instant 即时版" / "Pro 专业版".
    public let chineseName: String
    /// One-line subtitle shown under the model row in the picker.
    public let englishSubtitle: String
    public let chineseSubtitle: String
    /// On-disk size in MB (rounded). Used in the picker so the user can
    /// understand cost before swapping.
    public let approximateMB: Int
    /// SF Symbol used as the picker row glyph.
    public let symbol: String

    public var id: String { kind.rawValue }

    public func displayName(chinese: Bool) -> String {
        chinese ? chineseName : englishName
    }
    public func subtitle(chinese: Bool) -> String {
        chinese ? chineseSubtitle : englishSubtitle
    }
}

public enum SleepAIModelCatalog {

    /// All tiers Circadia knows about, in picker order. The order also
    /// drives default selection (`defaultDescriptor(for:)` picks the first
    /// allowed entry).
    public static let all: [SleepAIModelTier] = [
        SleepAIModelTier(
            kind: .gemma,
            bundleDirName: "circadia-sleep-2b-4bit",
            englishName: "Gemma 3n",
            chineseName: "Gemma 3n",
            englishSubtitle: "Google DeepMind · 2B · 4-bit · LoRA",
            chineseSubtitle: "Google DeepMind · 2B · 4-bit · LoRA",
            approximateMB: 1500,
            symbol: "sparkle"
        ),
        SleepAIModelTier(
            kind: .qwenInstant,
            bundleDirName: "circadia-sleep-qwen-1_7b-4bit",
            englishName: "Instant",
            chineseName: "Instant 即时版",
            englishSubtitle: "Tongyi Lab Qwen3 · 1.7B · 4-bit · LoRA",
            chineseSubtitle: "通义实验室 Qwen3 · 1.7B · 4-bit · LoRA",
            approximateMB: 1100,
            symbol: "bolt"
        ),
        SleepAIModelTier(
            kind: .qwenPro,
            bundleDirName: "circadia-sleep-qwen-4b-4bit",
            englishName: "Pro",
            chineseName: "Pro 专业版",
            englishSubtitle: "Tongyi Lab Qwen3 · 4B · 4-bit · LoRA",
            chineseSubtitle: "通义实验室 Qwen3 · 4B · 4-bit · LoRA",
            approximateMB: 2500,
            symbol: "sparkles"
        )
    ]

    public static func descriptor(for kind: SleepAIModelKind) -> SleepAIModelTier {
        all.first { $0.kind == kind } ?? all[0]
    }

    /// Returns the descriptors the user is allowed to see in the picker
    /// for a given region. Always non-empty: the catalogue guarantees at
    /// least one Qwen tier in every region.
    public static func available(in region: SleepAIRegion) -> [SleepAIModelTier] {
        all.filter { region.allows($0.kind) }
    }

    /// Default tier for a fresh install in `region`. We prefer **Instant**
    /// in Mainland China (smallest footprint, no Gemma) and **Gemma** in
    /// every other region (current shipping default).
    public static func defaultKind(for region: SleepAIRegion) -> SleepAIModelKind {
        switch region {
        case .mainlandChina: return .qwenInstant
        case .global:        return .gemma
        }
    }
}
