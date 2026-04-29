import Foundation

public enum SleepProtocolCheckInKind: String, Codable, Sendable, Equatable {
    case jetLag
    case memory
}

public enum SleepProtocolCheckInCategory: String, Codable, Sendable, Equatable {
    case light
    case caffeine
    case nap
    case windDown
    case sleepWindow
    case review
}

public struct SleepProtocolCheckInTask: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let category: SleepProtocolCheckInCategory
    public let title: String
    public let detail: String
    public let scheduledMinute: Int?
    public var completedAt: Date?

    public init(id: String,
                category: SleepProtocolCheckInCategory,
                title: String,
                detail: String,
                scheduledMinute: Int? = nil,
                completedAt: Date? = nil) {
        self.id = id
        self.category = category
        self.title = title
        self.detail = detail
        self.scheduledMinute = scheduledMinute.map(Self.normalizeMinute)
        self.completedAt = completedAt
    }

    public var isCompleted: Bool { completedAt != nil }

    public func completing(at date: Date = Date()) -> SleepProtocolCheckInTask {
        var copy = self
        copy.completedAt = date
        return copy
    }

    private static func normalizeMinute(_ minute: Int) -> Int {
        ((minute % (24 * 60)) + (24 * 60)) % (24 * 60)
    }
}

public struct SleepProtocolCheckInPlan: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let kind: SleepProtocolCheckInKind
    public let title: String
    public let createdAt: Date
    public let sleepPlan: SleepPlanConfiguration
    public let reasons: [String]
    public var tasks: [SleepProtocolCheckInTask]

    public init(id: String = UUID().uuidString,
                kind: SleepProtocolCheckInKind,
                title: String,
                createdAt: Date = Date(),
                sleepPlan: SleepPlanConfiguration,
                reasons: [String],
                tasks: [SleepProtocolCheckInTask]) {
        self.id = id
        self.kind = kind
        self.title = title
        self.createdAt = createdAt
        self.sleepPlan = sleepPlan
        self.reasons = reasons
        self.tasks = tasks
    }

    public var completedCount: Int {
        tasks.filter(\.isCompleted).count
    }

    public var completionRatio: Double {
        guard !tasks.isEmpty else { return 0 }
        return Double(completedCount) / Double(tasks.count)
    }

    public var isComplete: Bool {
        !tasks.isEmpty && completedCount == tasks.count
    }

    public func completingTask(id taskID: String,
                               at date: Date = Date()) -> SleepProtocolCheckInPlan {
        var copy = self
        copy.tasks = tasks.map { task in
            guard task.id == taskID, task.completedAt == nil else { return task }
            return task.completing(at: date)
        }
        return copy
    }
}

public protocol SleepProtocolCheckInStoreProtocol: Sendable {
    func loadActivePlan() async -> SleepProtocolCheckInPlan?
    func saveActivePlan(_ plan: SleepProtocolCheckInPlan?) async
    func reset() async
}

public actor InMemorySleepProtocolCheckInStore: SleepProtocolCheckInStoreProtocol {
    private var plan: SleepProtocolCheckInPlan?

    public init(plan: SleepProtocolCheckInPlan? = nil) {
        self.plan = plan
    }

    public func loadActivePlan() -> SleepProtocolCheckInPlan? {
        plan
    }

    public func saveActivePlan(_ plan: SleepProtocolCheckInPlan?) {
        self.plan = plan
    }

    public func reset() {
        plan = nil
    }
}

public actor PersistentSleepProtocolCheckInStore: SleepProtocolCheckInStoreProtocol {
    public let fileURL: URL
    private var cache: SleepProtocolCheckInPlan?
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
        return folder.appendingPathComponent("protocol-checkin.json")
    }

    public func loadActivePlan() -> SleepProtocolCheckInPlan? {
        ensureLoaded()
        return cache
    }

    public func saveActivePlan(_ plan: SleepProtocolCheckInPlan?) {
        ensureLoaded()
        cache = plan
        flush()
    }

    public func reset() {
        cache = nil
        try? FileManager.default.removeItem(at: fileURL)
    }

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        cache = try? decoder.decode(SleepProtocolCheckInPlan.self, from: data)
    }

    private func flush() {
        guard let cache else {
            try? FileManager.default.removeItem(at: fileURL)
            return
        }
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

public actor SleepProtocolCheckInService {
    public let store: SleepProtocolCheckInStoreProtocol

    public init(store: SleepProtocolCheckInStoreProtocol) {
        self.store = store
    }

    public func activePlan() async -> SleepProtocolCheckInPlan? {
        await store.loadActivePlan()
    }

    public func activate(_ plan: SleepProtocolCheckInPlan) async -> SleepProtocolCheckInPlan {
        await store.saveActivePlan(plan)
        return plan
    }

    public func completeTask(id taskID: String,
                             at date: Date = Date()) async -> SleepProtocolCheckInPlan? {
        guard let plan = await store.loadActivePlan() else { return nil }
        let updated = plan.completingTask(id: taskID, at: date)
        await store.saveActivePlan(updated)
        return updated
    }

    public func clear() async {
        await store.reset()
    }
}

public enum SleepProtocolCheckInFactory {
    public static func makePlan(from optimization: SleepProtocolOptimization,
                                prompt: String,
                                now: Date = Date()) -> SleepProtocolCheckInPlan? {
        guard let draft = optimization.draft else { return nil }
        let chinese = prompt.range(of: #"\p{Han}"#, options: .regularExpression) != nil
        let kind: SleepProtocolCheckInKind = optimization.kind == .jetLag ? .jetLag : .memory
        let title: String
        let tasks: [SleepProtocolCheckInTask]
        switch kind {
        case .jetLag:
            title = chinese ? "倒时差打卡" : "Jet Lag Check-in"
            tasks = jetLagTasks(plan: draft.plan, chinese: chinese)
        case .memory:
            title = chinese ? "记忆睡眠打卡" : "Memory Sleep Check-in"
            tasks = memoryTasks(plan: draft.plan, chinese: chinese)
        }
        return SleepProtocolCheckInPlan(
            kind: kind,
            title: title,
            createdAt: now,
            sleepPlan: draft.plan,
            reasons: optimization.reasons,
            tasks: tasks
        )
    }

    private static func jetLagTasks(plan: SleepPlanConfiguration,
                                    chinese: Bool) -> [SleepProtocolCheckInTask] {
        let bed = plan.bedtimeHour * 60 + plan.bedtimeMinute
        let wake = plan.wakeHour * 60 + plan.wakeMinute
        return [
            SleepProtocolCheckInTask(
                id: "light",
                category: .light,
                title: chinese ? "目的地白天光照" : "Destination daytime light",
                detail: chinese ? "醒后尽快接触自然光或明亮室内光。" : "Get outdoor or bright indoor light soon after waking.",
                scheduledMinute: wake + 30
            ),
            SleepProtocolCheckInTask(
                id: "caffeine",
                category: .caffeine,
                title: chinese ? "咖啡因截止" : "Caffeine cutoff",
                detail: chinese ? "睡前 6 小时后不再摄入咖啡因。" : "Stop caffeine 6 hours before the planned bedtime.",
                scheduledMinute: bed - 360
            ),
            SleepProtocolCheckInTask(
                id: "nap",
                category: .nap,
                title: chinese ? "只允许短 nap" : "Short nap only",
                detail: chinese ? "如果白天撑不住，限制在 20-30 分钟。" : "If needed, keep the nap to 20-30 minutes.",
                scheduledMinute: 14 * 60
            ),
            SleepProtocolCheckInTask(
                id: "wind_down",
                category: .windDown,
                title: chinese ? "睡前减光" : "Dim light before bed",
                detail: chinese ? "睡前 1 小时降低屏幕和房间亮度。" : "Dim screens and room light in the last hour.",
                scheduledMinute: bed - 60
            ),
            SleepProtocolCheckInTask(
                id: "sleep_window",
                category: .sleepWindow,
                title: chinese ? "按计划上床" : "Follow sleep window",
                detail: chinese ? "按保存的睡眠计划执行，不再临时大幅改动。" : "Follow the saved Sleep Plan without a late large shift.",
                scheduledMinute: bed
            )
        ]
    }

    private static func memoryTasks(plan: SleepPlanConfiguration,
                                    chinese: Bool) -> [SleepProtocolCheckInTask] {
        let bed = plan.bedtimeHour * 60 + plan.bedtimeMinute
        let wake = plan.wakeHour * 60 + plan.wakeMinute
        return [
            SleepProtocolCheckInTask(
                id: "study_cutoff",
                category: .windDown,
                title: chinese ? "停止高强度学习" : "Stop heavy studying",
                detail: chinese ? "睡前 45 分钟停止刷题和新内容输入。" : "Stop problem sets and new material 45 minutes before bed.",
                scheduledMinute: bed - 45
            ),
            SleepProtocolCheckInTask(
                id: "wind_down",
                category: .windDown,
                title: chinese ? "降刺激放松" : "Wind down",
                detail: chinese ? "用低刺激复盘或整理明早清单，不再硬背。" : "Use low-stimulation review or prepare a morning list.",
                scheduledMinute: bed - 30
            ),
            SleepProtocolCheckInTask(
                id: "sleep_window",
                category: .sleepWindow,
                title: chinese ? "保护整段睡眠" : "Protect the sleep window",
                detail: chinese ? "按计划睡眠窗口执行，避免熬夜压缩 REM。" : "Follow the planned window and avoid cutting late-night REM.",
                scheduledMinute: bed
            ),
            SleepProtocolCheckInTask(
                id: "morning_review",
                category: .review,
                title: chinese ? "早晨 20 分钟复习" : "20-minute morning review",
                detail: chinese ? "醒后复习最难的 1-2 个知识点。" : "Review the hardest 1-2 items after waking.",
                scheduledMinute: wake + 30
            )
        ]
    }
}
