import Foundation

public struct PersonalSleepBaseline: Codable, Sendable, Equatable {
    public let sampleCount: Int
    public let highQualitySampleCount: Int
    public let typicalBedtimeMinute: Int?
    public let typicalWakeMinute: Int?
    public let averageDurationSec: Int
    public let averageAsleepSec: Int
    public let averageWakeSec: Int
    public let averageDeepSec: Int
    public let averageRemSec: Int
    public let averageSleepScore: Double?
    public let averageEvidenceConfidence: Double
    public let builtAt: Date

    public init(sampleCount: Int,
                highQualitySampleCount: Int,
                typicalBedtimeMinute: Int?,
                typicalWakeMinute: Int?,
                averageDurationSec: Int,
                averageAsleepSec: Int,
                averageWakeSec: Int,
                averageDeepSec: Int,
                averageRemSec: Int,
                averageSleepScore: Double?,
                averageEvidenceConfidence: Double,
                builtAt: Date = Date()) {
        self.sampleCount = sampleCount
        self.highQualitySampleCount = highQualitySampleCount
        self.typicalBedtimeMinute = typicalBedtimeMinute
        self.typicalWakeMinute = typicalWakeMinute
        self.averageDurationSec = averageDurationSec
        self.averageAsleepSec = averageAsleepSec
        self.averageWakeSec = averageWakeSec
        self.averageDeepSec = averageDeepSec
        self.averageRemSec = averageRemSec
        self.averageSleepScore = averageSleepScore
        self.averageEvidenceConfidence = min(max(averageEvidenceConfidence, 0), 1)
        self.builtAt = builtAt
    }

    public static let empty = PersonalSleepBaseline(
        sampleCount: 0,
        highQualitySampleCount: 0,
        typicalBedtimeMinute: nil,
        typicalWakeMinute: nil,
        averageDurationSec: 0,
        averageAsleepSec: 0,
        averageWakeSec: 0,
        averageDeepSec: 0,
        averageRemSec: 0,
        averageSleepScore: nil,
        averageEvidenceConfidence: 0
    )

    public var isMature: Bool {
        sampleCount >= 7 && highQualitySampleCount >= 4
    }
}

public enum PersonalSleepBaselineBuilder {
    public static func build(records: [StoredSessionRecord],
                             passiveNights: [PassiveSleepNight] = [],
                             now: Date = Date(),
                             calendar: Calendar = .current,
                             maxSamples: Int = 30) -> PersonalSleepBaseline {
        let active = records.map(NightEvidence.init(record:))
        let passive = passiveNights.map(NightEvidence.init(passiveNight:))
        return build(evidence: active + passive,
                     now: now,
                     calendar: calendar,
                     maxSamples: maxSamples)
    }

    public static func build(evidence rawEvidence: [NightEvidence],
                             now: Date = Date(),
                             calendar: Calendar = .current,
                             maxSamples: Int = 30) -> PersonalSleepBaseline {
        let evidence = rawEvidence
            .filter { $0.durationSec >= 30 * 60 }
            .sorted { ($0.endedAt ?? $0.startedAt) > ($1.endedAt ?? $1.startedAt) }
            .prefix(max(1, maxSamples))

        guard !evidence.isEmpty else {
            return PersonalSleepBaseline.empty
        }

        let rows = Array(evidence)
        let count = rows.count
        let highQuality = rows.filter { $0.assessment.quality == .high }.count

        func avg(_ values: [Int]) -> Int {
            guard !values.isEmpty else { return 0 }
            return values.reduce(0, +) / values.count
        }

        let scores = rows.compactMap(\.sleepScore)

        return PersonalSleepBaseline(
            sampleCount: count,
            highQualitySampleCount: highQuality,
            typicalBedtimeMinute: circularMinuteMean(rows.map { minuteOfDay($0.startedAt, calendar: calendar) }),
            typicalWakeMinute: circularMinuteMean(rows.compactMap { $0.endedAt.map { minuteOfDay($0, calendar: calendar) } }),
            averageDurationSec: avg(rows.map(\.durationSec)),
            averageAsleepSec: avg(rows.compactMap(\.asleepSec)),
            averageWakeSec: avg(rows.compactMap(\.wakeSec)),
            averageDeepSec: avg(rows.compactMap(\.deepSec)),
            averageRemSec: avg(rows.compactMap(\.remSec)),
            averageSleepScore: scores.isEmpty ? nil : Double(scores.reduce(0, +)) / Double(scores.count),
            averageEvidenceConfidence: rows.map(\.assessment.confidence).reduce(0, +) / Double(count),
            builtAt: now
        )
    }

    public static func buildFromRecords(_ records: [StoredSessionRecord],
                                        passiveNights: [PassiveSleepNight] = [],
                                        now: Date = Date(),
                                        calendar: Calendar = .current,
                                        maxSamples: Int = 30) -> PersonalSleepBaseline {
        build(records: records,
              passiveNights: passiveNights,
              now: now,
              calendar: calendar,
              maxSamples: maxSamples)
    }

    private static func minuteOfDay(_ date: Date, calendar: Calendar) -> Int {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return (max(0, min(23, c.hour ?? 0)) * 60) + max(0, min(59, c.minute ?? 0))
    }

    /// Circular mean keeps 23:50 and 00:10 near midnight instead of averaging
    /// them to noon.
    private static func circularMinuteMean(_ minutes: [Int]) -> Int? {
        guard !minutes.isEmpty else { return nil }
        let full = Double(24 * 60)
        var sinSum = 0.0
        var cosSum = 0.0
        for minute in minutes {
            let angle = Double((minute % (24 * 60) + (24 * 60)) % (24 * 60)) / full * 2 * Double.pi
            sinSum += sin(angle)
            cosSum += cos(angle)
        }
        guard abs(sinSum) > 1e-9 || abs(cosSum) > 1e-9 else { return nil }
        var angle = atan2(sinSum / Double(minutes.count), cosSum / Double(minutes.count))
        if angle < 0 { angle += 2 * Double.pi }
        return Int((angle / (2 * Double.pi) * full).rounded()) % (24 * 60)
    }
}
