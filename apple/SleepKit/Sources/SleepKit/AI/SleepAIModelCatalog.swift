import Foundation

/// Catalog of the on-device LLM tiers Circadia ships.
///
/// **Brand model (user-visible).** The picker only ever exposes two tiers:
///
///   • **Instant** — fast, lightweight model. Region-routed:
///       - Mainland China  → Tongyi Lab Qwen3-1.7B-Instruct, 4-bit + LoRA
///       - Everywhere else → Google DeepMind Gemma 3n, 4-bit + LoRA
///     The user sees a single brand, "Instant", regardless of region.
///
///   • **Pro** — higher-quality, larger context. Identical worldwide:
///       - Tongyi Lab Qwen3-4B-Instruct, 4-bit + LoRA
///
/// **Implementation model.** `SleepAIModelKind` (gemma / qwenInstant /
/// qwenPro) still names the *underlying weights bundle on disk*; this is
/// what `MLXSleepAIService` actually loads. The picker translates a brand
/// tier + region into the right kind via `kind(for:in:)`.
///
/// Display copy is locale-agnostic on purpose — "Instant" and "Pro" read
/// the same in zh-Hans and en, so we don't need to clutter the row with
/// translations or technical jargon (no "1.7B / 4-bit / LoRA" subtitle).

public enum SleepAIModelKind: String, Codable, Sendable, CaseIterable, Equatable {
    /// Google DeepMind Gemma 3n, 4-bit, with a Circadia LoRA adapter fused
    /// in. Powers **Instant** outside Mainland China.
    case gemma
    /// Alibaba Tongyi Lab Qwen3-1.7B-Instruct, 4-bit + LoRA. Powers
    /// **Instant** in Mainland China.
    case qwenInstant
    /// Alibaba Tongyi Lab Qwen3-4B-Instruct, 4-bit + LoRA. Powers **Pro**
    /// in every region.
    case qwenPro
}

/// User-visible brand tier in the model picker. Stable string identifiers
/// so persisted preferences survive across renames.
public enum SleepAIBrandTier: String, Codable, Sendable, CaseIterable, Equatable {
    case instant
    case pro
}

/// Static metadata describing how each tier is presented and where its
/// weights live on disk.
public struct SleepAIModelTier: Codable, Equatable, Sendable, Identifiable {
    /// Brand-level tier the user picks (Instant / Pro).
    public let brand: SleepAIBrandTier
    /// Underlying weights kind that actually loads at runtime — depends on
    /// the brand tier *and* the device region.
    public let kind: SleepAIModelKind
    /// Subdirectory name *inside the .app bundle* and on disk under
    /// `Documents/Models/`. Stable across renames so existing installs keep
    /// finding their weights.
    public let bundleDirName: String
    /// Short brand name. Identical across locales — "Instant" / "Pro".
    public let displayName: String
    /// One-line subtitle shown under the model row. Plain language, no
    /// model-card jargon.
    public let englishSubtitle: String
    public let chineseSubtitle: String
    /// On-disk size in MB (rounded). Used in the picker so the user can
    /// understand cost before swapping.
    public let approximateMB: Int
    /// SF Symbol used as the picker row glyph.
    public let symbol: String

    public var id: String { brand.rawValue }

    public func subtitle(chinese: Bool) -> String {
        chinese ? chineseSubtitle : englishSubtitle
    }
}

public enum SleepAIModelCatalog {

    /// Resolves the underlying weights kind for a brand tier in a given
    /// region. The returned kind is always one the region allows.
    public static func kind(for brand: SleepAIBrandTier, in region: SleepAIRegion) -> SleepAIModelKind {
        switch (brand, region) {
        case (.instant, .mainlandChina): return .qwenInstant
        case (.instant, .global):        return .gemma
        case (.pro, _):                  return .qwenPro
        }
    }

    /// Builds the tier descriptor the picker should show for `brand` in
    /// `region`. Region only affects the *underlying* `kind` and bundle
    /// directory; the brand label is identical worldwide.
    public static func descriptor(for brand: SleepAIBrandTier, in region: SleepAIRegion) -> SleepAIModelTier {
        let kind = kind(for: brand, in: region)
        switch brand {
        case .instant:
            return SleepAIModelTier(
                brand: .instant,
                kind: kind,
                bundleDirName: bundleDirName(for: kind),
                displayName: "Instant",
                englishSubtitle: "Fast · runs entirely on your iPhone",
                chineseSubtitle: "轻快 · 完全在 iPhone 上运行",
                approximateMB: kind == .qwenInstant ? 1100 : 1500,
                symbol: "bolt.fill"
            )
        case .pro:
            return SleepAIModelTier(
                brand: .pro,
                kind: kind,
                bundleDirName: bundleDirName(for: kind),
                displayName: "Pro",
                englishSubtitle: "Higher quality · still on-device",
                chineseSubtitle: "更高质量 · 同样本地运行",
                approximateMB: 2500,
                symbol: "sparkles"
            )
        }
    }

    /// Backwards-compatible lookup by raw kind. Used by existing call sites
    /// that still pass a `SleepAIModelKind` (e.g. the legacy persistence
    /// layer that stored kind strings before the brand-tier refactor).
    public static func descriptor(for kind: SleepAIModelKind) -> SleepAIModelTier {
        let region = SleepAIRegion.current
        switch kind {
        case .qwenPro:
            return descriptor(for: .pro, in: region)
        case .gemma, .qwenInstant:
            return descriptor(for: .instant, in: region)
        }
    }

    /// Tiers offered to the user in this region. Always exactly two,
    /// `[Instant, Pro]`, independent of region — but the underlying weights
    /// for Instant differ between Mainland China (Qwen) and Global (Gemma).
    public static func available(in region: SleepAIRegion) -> [SleepAIModelTier] {
        [
            descriptor(for: .instant, in: region),
            descriptor(for: .pro, in: region)
        ]
    }

    /// Default brand tier for a fresh install. Always **Instant** — a small,
    /// fast first-run experience is more important than peak quality.
    public static func defaultBrand(for region: SleepAIRegion) -> SleepAIBrandTier {
        _ = region
        return .instant
    }

    /// Default underlying kind for a fresh install in `region`. Preserved
    /// so existing call sites that read `defaultKind` keep working.
    public static func defaultKind(for region: SleepAIRegion) -> SleepAIModelKind {
        kind(for: defaultBrand(for: region), in: region)
    }

    // MARK: - Internal

    /// On-disk bundle directory name for a given underlying weights kind.
    /// These match the names used by the `Embed Circadia LLM` build phase.
    private static func bundleDirName(for kind: SleepAIModelKind) -> String {
        switch kind {
        case .gemma:       return "circadia-sleep-2b-4bit"
        case .qwenInstant: return "circadia-sleep-qwen-1_7b-4bit"
        case .qwenPro:     return "circadia-sleep-qwen-4b-4bit"
        }
    }
}
