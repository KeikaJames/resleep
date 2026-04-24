import Foundation

/// Deterministic replay harness for a single scenario.
///
/// The runner walks a pre-sorted list of `ScenarioStep`s and, for each event,
/// drives the *same telemetry plumbing* a real watch would:
///
///   * heart-rate points → `onHeartRate(bpm, at: date)`
///   * accel windows     → `onAccelWindow(window)`
///   * reachability      → `onReachability(Bool)`
///   * armSmartAlarm     → `onArmAlarm(target, windowMinutes)`
///   * dismissAlarm      → `onDismissAlarm()`
///   * mark              → `onMark(label)` (debug-only)
///
/// The runner does not touch `WorkoutSessionManager` or the connectivity
/// bus directly — `AppState` wires the callbacks so the live integration
/// point stays the same whether data comes from the watch or simulation.
///
/// Determinism:
///   * Step timestamps come from `scenarioStart + offsetSec`, not wall clock.
///   * Stepping by index gives bit-identical replay given the same scripts.
@MainActor
public final class ScenarioRunner: ObservableObject {

    // MARK: Published state (debug UI)

    @Published public private(set) var isRunning: Bool = false
    @Published public private(set) var scenario: ScenarioType?
    @Published public private(set) var stepIndex: Int = 0
    @Published public private(set) var lastMark: String?

    // MARK: Callbacks (wired by AppState)

    public var onHeartRate:    (@MainActor (Double, Date) -> Void)?
    public var onAccelWindow:  (@MainActor (AccelWindow) -> Void)?
    public var onReachability: (@MainActor (Bool) -> Void)?
    public var onArmAlarm:     (@MainActor (Date, Int) -> Void)?
    public var onDismissAlarm: (@MainActor () -> Void)?
    public var onMark:         (@MainActor (String) -> Void)?
    /// Fired once the last step has executed.
    public var onComplete:     (@MainActor () -> Void)?

    // MARK: Config

    /// Replay speed multiplier. 1.0 = real time, 60.0 = 60x faster.
    /// Default is aggressive so debug sessions finish in a minute.
    public var timeMultiplier: Double = 20.0

    // MARK: State

    private var steps: [ScenarioStep] = []
    private var task: Task<Void, Never>?
    private var scenarioStart: Date = Date()

    public init() {}

    // MARK: Control

    /// Starts replaying `scenario`. No-op if a scenario is already running —
    /// call `stop()` first. Returns immediately; steps fire asynchronously
    /// on the MainActor.
    public func start(_ scenario: ScenarioType, startDate: Date = Date()) {
        guard !isRunning else { return }
        self.scenario = scenario
        self.steps = ScenarioScripts.steps(for: scenario)
        self.scenarioStart = startDate
        self.stepIndex = 0
        self.lastMark = nil
        self.isRunning = true

        let captured = self.steps
        let multiplier = max(0.001, self.timeMultiplier)
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            var elapsed: Double = 0
            for (idx, step) in captured.enumerated() {
                if Task.isCancelled { return }
                let waitSec = max(0, step.offsetSec - elapsed) / multiplier
                if waitSec > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(waitSec * 1_000_000_000))
                }
                if Task.isCancelled { return }
                self.fire(step, at: startDate.addingTimeInterval(step.offsetSec))
                self.stepIndex = idx + 1
                elapsed = step.offsetSec
            }
            self.isRunning = false
            self.onComplete?()
        }
    }

    /// Cancels the current replay. Safe to call when idle.
    public func stop() {
        task?.cancel()
        task = nil
        isRunning = false
        scenario = nil
    }

    // MARK: Synchronous replay (tests)

    /// Fires every step in order without waiting — callers get a bit-for-bit
    /// reproducible sweep. Used by unit tests to assert determinism.
    public func replayImmediately(_ scenario: ScenarioType, startDate: Date = Date()) {
        self.scenario = scenario
        self.steps = ScenarioScripts.steps(for: scenario)
        self.scenarioStart = startDate
        self.stepIndex = 0
        self.lastMark = nil
        for (idx, step) in steps.enumerated() {
            fire(step, at: startDate.addingTimeInterval(step.offsetSec))
            stepIndex = idx + 1
        }
    }

    // MARK: Dispatch

    private func fire(_ step: ScenarioStep, at date: Date) {
        switch step {
        case .heartRate(_, let bpm):
            onHeartRate?(bpm, date)

        case .accelWindow(_, let mx, let my, let mz, let energy):
            let w = AccelWindow(
                tsMs: UInt64(date.timeIntervalSince1970 * 1000),
                meanX: mx, meanY: my, meanZ: mz,
                magnitudeMean: sqrt(mx * mx + my * my + mz * mz),
                energy: energy,
                sampleCount: 10
            )
            onAccelWindow?(w)

        case .reachability(_, let reachable):
            onReachability?(reachable)

        case .armSmartAlarm(_, let targetOffset, let windowMinutes):
            let target = scenarioStart.addingTimeInterval(targetOffset)
            onArmAlarm?(target, windowMinutes)

        case .dismissAlarm:
            onDismissAlarm?()

        case .mark(_, let label):
            lastMark = label
            onMark?(label)
        }
    }
}
