import Foundation

// MARK: - Public protocol

public enum ConnectivityError: Error, Sendable, Equatable {
    case notSupported
    case notReachable
    case notActivated
    case encodingFailed
    case queueFull
    case underlying(String)
}

/// Manager sitting above `WCSessionClientProtocol`. This is the only type
/// that ViewModels / AppState interact with — raw `WCSession` never escapes
/// SleepKit.
///
/// Three delivery paths are offered:
/// - `sendImmediateMessage`  low-latency, requires reachability; fails fast.
/// - `sendGuaranteedMessage` best-effort via `transferUserInfo`, OS queues.
/// - `updateStatusSnapshot`  coalesced latest-wins snapshot via application context.
public protocol ConnectivityManagerProtocol: AnyObject {
    var isSupported: Bool { get }
    var isReachable: Bool { get }
    var isPaired: Bool { get }
    var isWatchAppInstalled: Bool { get }

    func activate()
    func sendImmediateMessage(_ envelope: MessageEnvelope) throws
    func sendGuaranteedMessage(_ envelope: MessageEnvelope)
    func updateStatusSnapshot(_ snapshot: StatusSnapshotPayload, sessionId: String?) throws

    /// Registers (or replaces) the inbound-envelope handler. Called on an
    /// arbitrary thread — callers must hop to the main actor before mutating
    /// UI state.
    func setInboundHandler(_ handler: @escaping @Sendable (MessageEnvelope) -> Void)

    /// Optional reachability callback. Called on an arbitrary thread.
    func setReachabilityHandler(_ handler: @escaping @Sendable (Bool) -> Void)
}

// MARK: - Production manager

/// `WCSession`-backed manager. Works identically on iOS and watchOS; the
/// only platform-specific bits (`isPaired`, `isWatchAppInstalled`) are
/// delegated to `WCSessionClientProtocol`.
public final class ConnectivityManager: ConnectivityManagerProtocol, @unchecked Sendable {

    private let client: WCSessionClientProtocol
    private let lock = NSLock()
    private var inbound: (@Sendable (MessageEnvelope) -> Void)?
    private var reach:   (@Sendable (Bool) -> Void)?

    public init(client: WCSessionClientProtocol) {
        self.client = client
        wireClientHandlers()
    }

    // Convenience factory used by production app composition. Falls back to
    // `InMemoryConnectivityManager` when WatchConnectivity isn't available
    // (e.g. SleepKit running inside a macOS unit-test bundle).
    public static func makeProductionDefault() -> ConnectivityManagerProtocol {
        #if canImport(WatchConnectivity)
        return ConnectivityManager(client: DefaultWCSessionClient())
        #else
        return InMemoryConnectivityManager()
        #endif
    }

    public var isSupported:          Bool { client.isSupported }
    public var isReachable:          Bool { client.isReachable }
    public var isPaired:             Bool { client.isPaired }
    public var isWatchAppInstalled:  Bool { client.isWatchAppInstalled }

    public func activate() { client.activate() }

    public func sendImmediateMessage(_ envelope: MessageEnvelope) throws {
        guard client.isSupported else { throw ConnectivityError.notSupported }
        guard client.isReachable else { throw ConnectivityError.notReachable }
        let dict = envelope.toDictionary()
        var sendError: Error?
        client.sendMessage(dict, replyHandler: nil) { err in
            sendError = err
        }
        // `sendMessage` dispatches asynchronously; the error handler fires
        // later, but pre-flight gating above covers the common cases. The
        // error capture is best-effort for synchronous call sites.
        if let sendError { throw ConnectivityError.underlying(sendError.localizedDescription) }
    }

    public func sendGuaranteedMessage(_ envelope: MessageEnvelope) {
        client.transferUserInfo(envelope.toDictionary())
    }

    public func updateStatusSnapshot(_ snapshot: StatusSnapshotPayload, sessionId: String?) throws {
        let env = try WatchMessage.status(sessionId: sessionId, payload: snapshot)
        try client.updateApplicationContext(env.toDictionary())
    }

    public func setInboundHandler(_ handler: @escaping @Sendable (MessageEnvelope) -> Void) {
        lock.lock(); defer { lock.unlock() }
        inbound = handler
    }

    public func setReachabilityHandler(_ handler: @escaping @Sendable (Bool) -> Void) {
        lock.lock(); defer { lock.unlock() }
        reach = handler
    }

    // MARK: - Private

    private func snapshotInbound() -> (@Sendable (MessageEnvelope) -> Void)? {
        lock.lock(); defer { lock.unlock() }; return inbound
    }
    private func snapshotReach() -> (@Sendable (Bool) -> Void)? {
        lock.lock(); defer { lock.unlock() }; return reach
    }

    private func wireClientHandlers() {
        client.onMessage = { [weak self] dict in
            guard let env = MessageEnvelope.fromDictionary(dict) else {
                NSLog("[ConnectivityManager] dropping malformed message")
                return
            }
            self?.snapshotInbound()?(env)
        }
        client.onMessageData = { [weak self] data in
            guard let env = try? JSONDecoder().decode(MessageEnvelope.self, from: data) else { return }
            self?.snapshotInbound()?(env)
        }
        client.onUserInfo = { [weak self] dict in
            guard let env = MessageEnvelope.fromDictionary(dict) else {
                NSLog("[ConnectivityManager] dropping malformed userInfo")
                return
            }
            self?.snapshotInbound()?(env)
        }
        client.onAppContext = { [weak self] dict in
            guard let env = MessageEnvelope.fromDictionary(dict) else { return }
            self?.snapshotInbound()?(env)
        }
        client.onReachability = { [weak self] reachable in
            self?.snapshotReach()?(reachable)
        }
        client.onActivation = { state, err in
            if let err = err {
                NSLog("[ConnectivityManager] activation error: \(err.localizedDescription)")
            }
            NSLog("[ConnectivityManager] activation state=\(state.rawValue)")
        }
    }
}
