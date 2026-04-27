import Foundation
import SleepKit

#if canImport(MLXLLM)
import MLXLLM
import MLXLMCommon
import MLX
#endif

/// On-device Gemma assistant. Loads MLX 4-bit Gemma 3n weights from a
/// local directory (the simulator/dev workspace path or the app's
/// Documents folder on device), then answers questions with a sleep-coach
/// persona. The service still implements `SleepAIServiceProtocol`, so it
/// drops into the existing UI without changes.
///
/// Lifecycle:
///   1. `init` does no work — cheap to construct.
///   2. First `reply(...)` lazily kicks off `prepare()` which:
///        a. resolves the weights directory,
///        b. builds an MLX `ModelContainer`,
///        c. opens a `ChatSession` with our system prompt.
///   3. Subsequent calls reuse the same session.
///
/// If anything fails (missing weights, OOM, build platform without MLX),
/// the service surfaces a localized error string so the UI can fall back
/// to the rule-based engine.
public final class GemmaSleepAIService: SleepAIServiceProtocol, @unchecked Sendable {

    public init(weightsLocator: GemmaWeightsLocator = .default) {
        self.weightsLocator = weightsLocator
    }

    public var engineKind: SleepAIEngineKind { .gemmaLocal }

    // MARK: Public API

    public func morningSummary(context ctx: SleepAIContext) -> String {
        // Morning summary stays deterministic and instant — same template
        // as the rule-based service. The LLM only powers free-form chat.
        return ruleBased.morningSummary(context: ctx)
    }

    public func suggestedFollowUps(context ctx: SleepAIContext) -> [String] {
        ruleBased.suggestedFollowUps(context: ctx)
    }

    public func reply(to prompt: String, context ctx: SleepAIContext) async -> String {
        #if canImport(MLXLLM)
        do {
            let session = try await ensureSession()
            let user = composeUserMessage(prompt: prompt, ctx: ctx)
            return try await session.respond(to: user)
        } catch {
            // Fall through to rule-based on any LLM failure so the user
            // never sees a dead chat.
            let fallback = await ruleBased.reply(to: prompt, context: ctx)
            return fallback + "\n\n*— rule-based fallback (\(Self.shortDescription(of: error)))*"
        }
        #else
        return await ruleBased.reply(to: prompt, context: ctx)
        #endif
    }

    // MARK: Internals

    private let weightsLocator: GemmaWeightsLocator
    private let ruleBased = SleepAIService()

    #if canImport(MLXLLM)
    private var session: ChatSession?
    private var loadTask: Task<ChatSession, Error>?

    /// Returns a hot session, creating it on first use. `Task` is used so
    /// concurrent first-time callers wait on the same load.
    private func ensureSession() async throws -> ChatSession {
        if let session { return session }
        if let loadTask { return try await loadTask.value }

        let task = Task<ChatSession, Error> { [weightsLocator] in
            let dir = try weightsLocator.locate()

            // Cap GPU/Metal cache on iOS to keep us within the app's memory
            // budget — Gemma 3n E2B int4 sits ~3 GB and a 4 GB cache will
            // OOM on the simulator's emulated heap.
            MLX.GPU.set(cacheLimit: 64 * 1024 * 1024)

            let configuration = ModelConfiguration(directory: dir)
            let container = try await LLMModelFactory.shared.loadContainer(
                configuration: configuration
            ) { _ in }

            let s = ChatSession(
                container,
                instructions: Self.systemPrompt,
                generateParameters: GenerateParameters(
                    maxTokens: 320,
                    temperature: 0.6,
                    topP: 0.9
                )
            )
            return s
        }
        loadTask = task
        let s = try await task.value
        session = s
        loadTask = nil
        return s
    }

    private static let systemPrompt: String = """
    You are Circadia, a calm, on-device sleep companion. You speak like \
    a thoughtful coach: short sentences, no hype, no clinical claims. You \
    never recommend medication or replace a doctor. When you have a \
    user-provided night summary, ground every observation in the numbers. \
    When you don't, you ask one focused question. Match the user's \
    language. Use Markdown sparingly: **bold** for the headline number, \
    bullet lists when you have 3+ tips. Keep replies under 120 words.
    """
    #endif

    private func composeUserMessage(prompt: String, ctx: SleepAIContext) -> String {
        guard ctx.hasNight else { return prompt }
        let dur = Double(ctx.durationSec) / 3600.0
        let deep = Double(ctx.timeInDeepSec) / 3600.0
        let rem = Double(ctx.timeInRemSec) / 3600.0
        let wakeMin = ctx.timeInWakeSec / 60
        let context = String(
            format:
                "Last night context — duration %.1fh, score %d, deep %.1fh, REM %.1fh, awake %dm.",
            dur, ctx.sleepScore, deep, rem, wakeMin
        )
        return "\(context)\n\nUser: \(prompt)"
    }

    private static func shortDescription(of error: Error) -> String {
        let s = String(describing: error)
        return s.count > 80 ? String(s.prefix(80)) + "…" : s
    }
}

// MARK: - Weights locator

/// Resolves the local directory holding Gemma 3n MLX 4-bit weights.
///
/// Resolution order:
///   1. `CIRCADIA_GEMMA_DIR` environment variable (developer override).
///   2. App-specific Documents/Models/<dirName>.
///   3. Repository-relative dev path on simulator
///      (`<repoRoot>/models/<dirName>`) — only resolved when a path the
///      developer hard-coded actually exists.
///
/// Returns the URL, or throws if no candidate exists.
public struct GemmaWeightsLocator: Sendable {

    public let dirName: String
    /// Hard-coded fallback path (developer machine). Useful on simulator
    /// where Documents is sandboxed and Hub downloads aren't desired.
    public let devFallbackPath: String?

    public static let `default` = GemmaWeightsLocator(
        dirName: "gemma-3n-E2B-it-4bit",
        devFallbackPath: "/Users/gabiri/projects/resleep/sleep-tracker/models/gemma-3n-E2B-it-4bit"
    )

    public func locate() throws -> URL {
        let fm = FileManager.default

        // 1. Env override
        if let envPath = ProcessInfo.processInfo.environment["CIRCADIA_GEMMA_DIR"],
           !envPath.isEmpty,
           fm.fileExists(atPath: envPath) {
            return URL(fileURLWithPath: envPath, isDirectory: true)
        }

        // 2. Documents/Models/<dir>
        if let docs = try? fm.url(for: .documentDirectory, in: .userDomainMask,
                                  appropriateFor: nil, create: false) {
            let candidate = docs
                .appendingPathComponent("Models", isDirectory: true)
                .appendingPathComponent(dirName, isDirectory: true)
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        // 3. Dev workspace fallback (simulator)
        if let dev = devFallbackPath, fm.fileExists(atPath: dev) {
            return URL(fileURLWithPath: dev, isDirectory: true)
        }

        throw GemmaWeightsError.notFound(dirName: dirName)
    }
}

public enum GemmaWeightsError: LocalizedError {
    case notFound(dirName: String)

    public var errorDescription: String? {
        switch self {
        case .notFound(let name):
            return "Gemma weights '\(name)' not found in CIRCADIA_GEMMA_DIR, Documents/Models/, or dev workspace."
        }
    }
}

// MARK: - Small string helper

private extension String {
    func appending(_ tail: String) -> String { self + tail }
}
