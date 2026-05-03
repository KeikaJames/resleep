import Foundation

/// Product-level provenance for a night. This is intentionally separate from
/// `TrackingSource`: a night can be active, passively imported from HealthKit,
/// or eventually inferred from a plan/device-state fallback.
public enum NightEvidenceOrigin: String, Codable, Sendable, Equatable {
    case activeSession
    case passiveHealthKit
    case sleepPlanEstimate
}

public enum NightEvidenceQuality: String, Codable, Sendable, Equatable, Comparable {
    case low
    case moderate
    case high

    public static func < (lhs: NightEvidenceQuality, rhs: NightEvidenceQuality) -> Bool {
        lhs.rank < rhs.rank
    }

    private var rank: Int {
        switch self {
        case .low: return 0
        case .moderate: return 1
        case .high: return 2
        }
    }
}

/// Signals that can support a nightly sleep estimate. Keep this list broader
/// than today's implementation so local-only modules can attach HRV,
/// respiration, wrist temperature, device state, and optional user-entered
/// cycle context without changing the night evidence contract.
public enum NightEvidenceSignal: String, Codable, Sendable, Equatable, Hashable, CaseIterable {
    case activeSession
    case appleWatchSleepAnalysis
    case healthSleepAnalysis
    case stageSummary
    case timeline
    case heartRate
    case accelerometer
    case smartAlarm
    case wakeSurvey
    case notes
    case tags
    case snoreEvents
    case sleepPlan
    case hrv
    case restingHeartRate
    case respiratoryRate
    case oxygenSaturation
    case wristTemperature
    case deviceState
    case cycleContext
}

public struct NightEvidenceAssessment: Codable, Sendable, Equatable {
    public let origin: NightEvidenceOrigin
    public let quality: NightEvidenceQuality
    /// Normalized 0...1 confidence in the night-level aggregate. This is not
    /// a medical certainty; it is a product reliability score for UI and AI
    /// grounding.
    public let confidence: Double
    public let observedSignals: [NightEvidenceSignal]
    public let missingSignals: [NightEvidenceSignal]
    public let limitations: [String]
    public let isEstimated: Bool

    public init(origin: NightEvidenceOrigin,
                quality: NightEvidenceQuality,
                confidence: Double,
                observedSignals: [NightEvidenceSignal],
                missingSignals: [NightEvidenceSignal],
                limitations: [String] = [],
                isEstimated: Bool) {
        self.origin = origin
        self.quality = quality
        self.confidence = min(max(confidence, 0), 1)
        self.observedSignals = Self.stableUnique(observedSignals)
        self.missingSignals = Self.stableUnique(missingSignals)
        self.limitations = limitations
        self.isEstimated = isEstimated
    }

    public var confidencePercent: Int {
        Int((confidence * 100).rounded())
    }

    private static func stableUnique(_ signals: [NightEvidenceSignal]) -> [NightEvidenceSignal] {
        var seen = Set<NightEvidenceSignal>()
        var out: [NightEvidenceSignal] = []
        for signal in signals where !seen.contains(signal) {
            seen.insert(signal)
            out.append(signal)
        }
        return out
    }
}

/// Unified evidence object for a night. Today it wraps active session records
/// and passive HealthKit nights; later protocol engines can consume this same
/// shape instead of reaching into app-specific storage details.
public struct NightEvidence: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let startedAt: Date
    public let endedAt: Date?
    public let durationSec: Int
    public let asleepSec: Int?
    public let wakeSec: Int?
    public let lightSec: Int?
    public let deepSec: Int?
    public let remSec: Int?
    public let sleepScore: Int?
    public let sourceBundleIDs: [String]
    public let assessment: NightEvidenceAssessment

    public init(id: String,
                startedAt: Date,
                endedAt: Date?,
                durationSec: Int,
                asleepSec: Int? = nil,
                wakeSec: Int? = nil,
                lightSec: Int? = nil,
                deepSec: Int? = nil,
                remSec: Int? = nil,
                sleepScore: Int? = nil,
                sourceBundleIDs: [String] = [],
                assessment: NightEvidenceAssessment) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationSec = max(0, durationSec)
        self.asleepSec = asleepSec
        self.wakeSec = wakeSec
        self.lightSec = lightSec
        self.deepSec = deepSec
        self.remSec = remSec
        self.sleepScore = sleepScore
        self.sourceBundleIDs = sourceBundleIDs
        self.assessment = assessment
    }

    public init(record: StoredSessionRecord) {
        let summary = record.summary
        let duration = summary?.durationSec
            ?? record.endedAt.map { max(0, Int($0.timeIntervalSince(record.startedAt))) }
            ?? 0
        let assessment = SleepConfidenceScorer.assess(record: record)
        self.init(
            id: record.id,
            startedAt: record.startedAt,
            endedAt: record.endedAt,
            durationSec: duration,
            asleepSec: summary.map {
                max(0, $0.timeInLightSec + $0.timeInDeepSec + $0.timeInRemSec)
            },
            wakeSec: summary?.timeInWakeSec,
            lightSec: summary?.timeInLightSec,
            deepSec: summary?.timeInDeepSec,
            remSec: summary?.timeInRemSec,
            sleepScore: summary?.sleepScore,
            assessment: assessment
        )
    }

    public init(passiveNight night: PassiveSleepNight) {
        let assessment = SleepConfidenceScorer.assess(passiveNight: night)
        self.init(
            id: night.id,
            startedAt: night.startedAt,
            endedAt: night.endedAt,
            durationSec: night.durationSec,
            asleepSec: night.asleepSec,
            wakeSec: night.awakeSec,
            lightSec: night.coreSec,
            deepSec: night.deepSec,
            remSec: night.remSec,
            sourceBundleIDs: night.sourceBundleIDs,
            assessment: assessment
        )
    }
}

public enum SleepConfidenceScorer {
    public static func assess(record: StoredSessionRecord) -> NightEvidenceAssessment {
        var observed: [NightEvidenceSignal] = [.activeSession]
        var missing: [NightEvidenceSignal] = []
        var limitations: [String] = []
        var score = 0.54

        if let summary = record.summary {
            observed.append(.stageSummary)
            if summary.durationSec >= 4 * 3600 { score += 0.06 }
            if summary.durationSec < 30 * 60 {
                score -= 0.22
                limitations.append("short_session")
            }
            if summary.timeInLightSec + summary.timeInDeepSec + summary.timeInRemSec <= 0 {
                score -= 0.16
                limitations.append("no_asleep_stage_total")
            }
        } else {
            missing.append(.stageSummary)
            score -= 0.24
            limitations.append("missing_stage_summary")
        }

        if record.timeline.isEmpty {
            missing.append(.timeline)
            score -= 0.08
        } else {
            observed.append(.timeline)
            score += 0.08
        }

        switch record.sourceRaw {
        case TrackingSource.remoteWatch.rawValue:
            observed.append(.heartRate)
            observed.append(.accelerometer)
            score += 0.12
        case TrackingSource.localPhone.rawValue:
            observed.append(.heartRate)
            missing.append(.accelerometer)
            score += 0.03
        default:
            missing.append(.heartRate)
            missing.append(.accelerometer)
            score -= 0.06
        }

        if record.alarm?.enabled == true {
            observed.append(.smartAlarm)
            score += 0.02
        }
        if record.survey != nil {
            observed.append(.wakeSurvey)
            score += 0.04
        } else {
            missing.append(.wakeSurvey)
        }
        if let notes = record.notes, !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            observed.append(.notes)
        }
        if let tags = record.tags, tags.contains(where: { !$0.isEmpty }) {
            observed.append(.tags)
        }
        if (record.snoreEventCount ?? 0) > 0 {
            observed.append(.snoreEvents)
        }

        let clamped = clamp(score)
        return NightEvidenceAssessment(
            origin: .activeSession,
            quality: quality(for: clamped),
            confidence: clamped,
            observedSignals: observed,
            missingSignals: missing,
            limitations: limitations,
            isEstimated: false
        )
    }

    public static func assess(passiveNight night: PassiveSleepNight) -> NightEvidenceAssessment {
        let observed: [NightEvidenceSignal] = [
            night.isAppleWatchOriginated ? .appleWatchSleepAnalysis : .healthSleepAnalysis,
            .stageSummary
        ]
        var missing: [NightEvidenceSignal] = [
            .heartRate,
            .accelerometer,
            .wakeSurvey
        ]
        var limitations: [String] = ["passive_healthkit_import"]
        var score = night.isAppleWatchOriginated ? 0.64 : 0.55

        let hasStageDetail = night.coreSec > 0 || night.deepSec > 0 || night.remSec > 0
        if hasStageDetail {
            score += 0.11
        } else {
            limitations.append("missing_sleep_stage_detail")
        }

        if night.asleepSec >= 4 * 3600 {
            score += 0.06
        } else if night.asleepSec < 90 * 60 {
            score -= 0.16
            limitations.append("short_passive_sleep")
        }

        if night.awakeSec > 0 {
            score += 0.02
        }
        if night.sourceBundleIDs.count > 1 {
            score -= 0.03
            limitations.append("mixed_healthkit_sources")
        }
        if night.inBedSec <= 0 {
            missing.append(.sleepPlan)
        }

        if night.sourceBundleIDs.isEmpty {
            score -= 0.05
            limitations.append("unknown_healthkit_source")
        }

        let clamped = clamp(score)
        return NightEvidenceAssessment(
            origin: .passiveHealthKit,
            quality: quality(for: clamped),
            confidence: clamped,
            observedSignals: observed,
            missingSignals: missing,
            limitations: limitations,
            isEstimated: true
        )
    }

    private static func quality(for confidence: Double) -> NightEvidenceQuality {
        if confidence >= 0.78 { return .high }
        if confidence >= 0.50 { return .moderate }
        return .low
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
