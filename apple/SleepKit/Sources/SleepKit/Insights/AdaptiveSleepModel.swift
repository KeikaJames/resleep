import Foundation

public struct AdaptiveSleepProfile: Codable, Sendable, Equatable {
    public var version: Int
    public var sampleCount: Int
    public var feedbackSampleCount: Int
    public var highConfidenceSampleCount: Int
    public var averageEvidenceConfidence: Double
    public var typicalBedtimeMinute: Int?
    public var typicalWakeMinute: Int?
    public var averageAsleepMinutes: Double?
    public var averageWakeMinutes: Double?
    public var averageSleepScore: Double?
    public var snoreEventsPerHour: Double?
    public var recoveryQuality: Double?
    public var alarmFeltGoodRate: Double?
    public var ingestedNightIDs: [String]
    public var feedbackNightIDs: [String]
    public var lastUpdatedAt: Date?

    public static let empty = AdaptiveSleepProfile(
        version: 1,
        sampleCount: 0,
        feedbackSampleCount: 0,
        highConfidenceSampleCount: 0,
        averageEvidenceConfidence: 0,
        typicalBedtimeMinute: nil,
        typicalWakeMinute: nil,
        averageAsleepMinutes: nil,
        averageWakeMinutes: nil,
        averageSleepScore: nil,
        snoreEventsPerHour: nil,
        recoveryQuality: nil,
        alarmFeltGoodRate: nil,
        ingestedNightIDs: [],
        feedbackNightIDs: [],
        lastUpdatedAt: nil
    )

    public var isMature: Bool {
        sampleCount >= 5 && highConfidenceSampleCount >= 3
    }

    public var canAdjustSleepPlan: Bool {
        sampleCount >= 3
            && highConfidenceSampleCount >= 2
            && averageEvidenceConfidence >= 0.55
    }
}

public struct AdaptiveSleepRecommendation: Codable, Sendable, Equatable {
    public let plan: SleepPlanConfiguration
    public let confidence: Double
    public let sampleCount: Int
    public let reasons: [String]

    public init(plan: SleepPlanConfiguration,
                confidence: Double,
                sampleCount: Int,
                reasons: [String]) {
        self.plan = plan
        self.confidence = min(max(confidence, 0), 1)
        self.sampleCount = sampleCount
        self.reasons = reasons
    }
}

public protocol AdaptiveSleepProfileStoreProtocol: Sendable {
    func loadProfile() async -> AdaptiveSleepProfile
    func saveProfile(_ profile: AdaptiveSleepProfile) async
    func reset() async
}

public actor InMemoryAdaptiveSleepProfileStore: AdaptiveSleepProfileStoreProtocol {
    private var profile: AdaptiveSleepProfile = .empty

    public init() {}

    public func loadProfile() -> AdaptiveSleepProfile {
        profile
    }

    public func saveProfile(_ profile: AdaptiveSleepProfile) {
        self.profile = profile
    }

    public func reset() {
        profile = .empty
    }
}

public actor PersistentAdaptiveSleepProfileStore: AdaptiveSleepProfileStoreProtocol {
    public let fileURL: URL
    private var cache: AdaptiveSleepProfile = .empty
    private var loaded = false

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public static func defaultURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = dir.appendingPathComponent("SleepTracker", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder,
                                                 withIntermediateDirectories: true)
        return folder.appendingPathComponent("adaptive-sleep-profile.json")
    }

    public func loadProfile() -> AdaptiveSleepProfile {
        ensureLoaded()
        return cache
    }

    public func saveProfile(_ profile: AdaptiveSleepProfile) {
        ensureLoaded()
        cache = profile
        flush()
    }

    public func reset() {
        cache = .empty
        flush()
    }

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode(AdaptiveSleepProfile.self, from: data) {
            cache = decoded
        }
    }

    private func flush() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(cache) else { return }
        let parent = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent,
                                                 withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }
}

public actor AdaptiveSleepModelService {
    public let store: AdaptiveSleepProfileStoreProtocol

    public init(store: AdaptiveSleepProfileStoreProtocol) {
        self.store = store
    }

    public func ingest(record: StoredSessionRecord,
                       plan: SleepPlanConfiguration,
                       now: Date = Date(),
                       calendar: Calendar = .current) async {
        let profile = await store.loadProfile()
        let updated = AdaptiveSleepModel.updated(
            profile: profile,
            evidence: NightEvidence(record: record),
            survey: record.survey,
            snoreEventCount: record.snoreEventCount,
            currentPlan: plan,
            now: now,
            calendar: calendar
        )
        if updated != profile {
            await store.saveProfile(updated)
        }
    }

    public func recommendation(currentPlan: SleepPlanConfiguration) async -> AdaptiveSleepRecommendation {
        let profile = await store.loadProfile()
        return AdaptiveSleepModel.recommendation(profile: profile, currentPlan: currentPlan)
    }

    public func snapshot() async -> AdaptiveSleepProfile {
        await store.loadProfile()
    }

    public func reset() async {
        await store.reset()
    }
}

public enum AdaptiveSleepModel {
    private static let maxRememberedNightIDs = 120

    public static func updated(profile initial: AdaptiveSleepProfile,
                               evidence: NightEvidence,
                               survey: WakeSurvey?,
                               snoreEventCount: Int?,
                               currentPlan: SleepPlanConfiguration,
                               now: Date = Date(),
                               calendar: Calendar = .current) -> AdaptiveSleepProfile {
        var profile = initial
        var changed = false

        if !profile.ingestedNightIDs.contains(evidence.id),
           evidence.durationSec >= 30 * 60 {
            let confidence = evidence.assessment.confidence
            let alpha = min(0.35, max(0.08, 0.10 + confidence * 0.20))
            profile.sampleCount += 1
            if confidence >= 0.75 {
                profile.highConfidenceSampleCount += 1
            }
            profile.averageEvidenceConfidence = ema(profile.averageEvidenceConfidence,
                                                    confidence,
                                                    alpha: alpha,
                                                    empty: profile.sampleCount == 1)
            profile.typicalBedtimeMinute = blendMinute(profile.typicalBedtimeMinute,
                                                       minuteOfDay(evidence.startedAt, calendar: calendar),
                                                       alpha: alpha)
            if let endedAt = evidence.endedAt {
                profile.typicalWakeMinute = blendMinute(profile.typicalWakeMinute,
                                                        minuteOfDay(endedAt, calendar: calendar),
                                                        alpha: alpha)
            }
            if let asleep = evidence.asleepSec {
                profile.averageAsleepMinutes = ema(profile.averageAsleepMinutes,
                                                   Double(asleep) / 60,
                                                   alpha: alpha)
            }
            if let wake = evidence.wakeSec {
                profile.averageWakeMinutes = ema(profile.averageWakeMinutes,
                                                 Double(wake) / 60,
                                                 alpha: alpha)
            }
            if let score = evidence.sleepScore {
                profile.averageSleepScore = ema(profile.averageSleepScore,
                                                Double(score),
                                                alpha: alpha)
            }
            if let snoreEventCount, evidence.durationSec > 0 {
                let perHour = Double(snoreEventCount) / (Double(evidence.durationSec) / 3600)
                profile.snoreEventsPerHour = ema(profile.snoreEventsPerHour,
                                                 perHour,
                                                 alpha: alpha)
            }
            appendBounded(evidence.id, to: &profile.ingestedNightIDs)
            changed = true
        }

        if let survey,
           evidence.durationSec >= 30 * 60,
           !profile.feedbackNightIDs.contains(evidence.id) {
            let alpha = 0.35
            profile.feedbackSampleCount += 1
            profile.recoveryQuality = ema(profile.recoveryQuality,
                                          Double(survey.quality),
                                          alpha: alpha)
            if let alarmFeltGood = survey.alarmFeltGood {
                profile.alarmFeltGoodRate = ema(profile.alarmFeltGoodRate,
                                                alarmFeltGood ? 1 : 0,
                                                alpha: alpha)
            }
            appendBounded(evidence.id, to: &profile.feedbackNightIDs)
            changed = true
        }

        if changed {
            profile.lastUpdatedAt = now
        }
        _ = currentPlan
        return profile
    }

    public static func recommendation(profile: AdaptiveSleepProfile,
                                      currentPlan: SleepPlanConfiguration) -> AdaptiveSleepRecommendation {
        guard profile.sampleCount > 0 else {
            return AdaptiveSleepRecommendation(
                plan: currentPlan,
                confidence: 0,
                sampleCount: 0,
                reasons: ["no_adaptive_history"]
            )
        }

        guard profile.canAdjustSleepPlan else {
            var reasons = ["collecting_adaptive_history", "low_sample_count"]
            if profile.averageEvidenceConfidence < 0.55 {
                reasons.append("low_evidence_confidence")
            }
            let confidence = min(0.45,
                                 max(0.12,
                                     profile.averageEvidenceConfidence * 0.55
                                        + min(Double(profile.sampleCount), 3) / 3 * 0.20
                                        + min(Double(profile.highConfidenceSampleCount), 2) / 2 * 0.10))
            return AdaptiveSleepRecommendation(
                plan: currentPlan,
                confidence: confidence,
                sampleCount: profile.sampleCount,
                reasons: stableUnique(reasons)
            )
        }

        var reasons: [String] = []
        let currentBed = currentPlan.bedtimeHour * 60 + currentPlan.bedtimeMinute
        let currentWake = currentPlan.wakeHour * 60 + currentPlan.wakeMinute
        let maxShift = profile.isMature ? 20 : 10
        let targetBed = profile.typicalBedtimeMinute.map {
            boundedShift(from: currentBed, toward: $0, maxMinutes: maxShift)
        } ?? currentBed
        let targetWake = profile.typicalWakeMinute.map {
            boundedShift(from: currentWake, toward: $0, maxMinutes: maxShift)
        } ?? currentWake

        if targetBed != currentBed { reasons.append("learned_bedtime_drift") }
        if targetWake != currentWake { reasons.append("learned_wake_drift") }

        var goal = currentPlan.sleepGoalMinutes
        if let asleep = profile.averageAsleepMinutes, let wake = profile.averageWakeMinutes {
            var learnedGoal = Int((asleep + max(20, min(wake, 90))).rounded())
            if let recovery = profile.recoveryQuality, recovery < 3.2 {
                learnedGoal += 15
                reasons.append("low_recovery_feedback")
            }
            if let score = profile.averageSleepScore, score < 70 {
                learnedGoal += 15
                reasons.append("low_average_score")
            }
            goal = boundedLinearShift(from: currentPlan.sleepGoalMinutes,
                                      toward: learnedGoal,
                                      maxDelta: profile.isMature ? 20 : 10)
            if goal != currentPlan.sleepGoalMinutes { reasons.append("learned_sleep_opportunity") }
        }

        var smartWindow = currentPlan.smartWakeWindowMinutes
        if let alarmRate = profile.alarmFeltGoodRate,
           profile.feedbackSampleCount >= 3,
           alarmRate < 0.45 {
            smartWindow = max(10, currentPlan.smartWakeWindowMinutes - 5)
            reasons.append("poor_smart_alarm_feedback")
        }

        if let snore = profile.snoreEventsPerHour, snore >= 6 {
            reasons.append("high_snore_event_density")
        }
        if !profile.isMature {
            reasons.append("low_sample_count")
        }

        let plan = SleepPlanConfiguration(
            autoTrackingEnabled: currentPlan.autoTrackingEnabled,
            bedtimeHour: targetBed / 60,
            bedtimeMinute: targetBed % 60,
            wakeHour: targetWake / 60,
            wakeMinute: targetWake % 60,
            sleepGoalMinutes: goal,
            smartWakeWindowMinutes: smartWindow,
            nightmareWakeEnabled: currentPlan.nightmareWakeEnabled
        )

        let confidence = min(0.9,
                             max(0.18,
                                 profile.averageEvidenceConfidence * 0.65
                                    + min(Double(profile.sampleCount), 10) / 10 * 0.25
                                    + min(Double(profile.feedbackSampleCount), 5) / 5 * 0.10))
        return AdaptiveSleepRecommendation(
            plan: plan,
            confidence: profile.isMature ? confidence : min(confidence, 0.55),
            sampleCount: profile.sampleCount,
            reasons: stableUnique(reasons)
        )
    }

    private static func ema(_ current: Double,
                            _ next: Double,
                            alpha: Double,
                            empty: Bool = false) -> Double {
        empty ? next : current * (1 - alpha) + next * alpha
    }

    private static func ema(_ current: Double?,
                            _ next: Double,
                            alpha: Double) -> Double {
        guard let current else { return next }
        return current * (1 - alpha) + next * alpha
    }

    private static func blendMinute(_ current: Int?,
                                    _ next: Int,
                                    alpha: Double) -> Int {
        guard let current else { return normalizeMinute(next) }
        let shifted = Double(current) + Double(shortestMinuteDelta(from: current, to: next)) * alpha
        return normalizeMinute(Int(shifted.rounded()))
    }

    private static func boundedShift(from current: Int,
                                     toward target: Int,
                                     maxMinutes: Int) -> Int {
        let delta = shortestMinuteDelta(from: normalizeMinute(current), to: normalizeMinute(target))
        let bounded = min(max(delta, -maxMinutes), maxMinutes)
        return normalizeMinute(current + bounded)
    }

    private static func boundedLinearShift(from current: Int,
                                           toward target: Int,
                                           maxDelta: Int) -> Int {
        let delta = min(max(target - current, -maxDelta), maxDelta)
        return current + delta
    }

    private static func shortestMinuteDelta(from current: Int, to target: Int) -> Int {
        let full = 24 * 60
        var delta = normalizeMinute(target) - normalizeMinute(current)
        if delta > full / 2 { delta -= full }
        if delta < -full / 2 { delta += full }
        return delta
    }

    private static func normalizeMinute(_ minute: Int) -> Int {
        ((minute % (24 * 60)) + (24 * 60)) % (24 * 60)
    }

    private static func minuteOfDay(_ date: Date, calendar: Calendar) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return normalizeMinute((max(0, min(23, c.hour ?? 0)) * 60) + max(0, min(59, c.minute ?? 0)))
    }

    private static func appendBounded(_ id: String, to ids: inout [String]) {
        ids.append(id)
        if ids.count > maxRememberedNightIDs {
            ids.removeFirst(ids.count - maxRememberedNightIDs)
        }
    }

    private static func stableUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for value in values where !seen.contains(value) {
            seen.insert(value)
            out.append(value)
        }
        return out
    }
}
