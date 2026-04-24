import Foundation
#if canImport(WatchConnectivity)
import WatchConnectivity
#endif

/// Thin protocol around `WCSession` so the `ConnectivityManager` can be
/// exercised under test without real WatchConnectivity.
///
/// All methods and delegate callbacks on the real session run on WC's own
/// background queue; implementations are expected to hop to the main actor
/// before mutating shared state.
public protocol WCSessionClientProtocol: AnyObject {
    var isSupported: Bool { get }
    var isReachable: Bool { get }
    var isPaired: Bool { get }
    var isWatchAppInstalled: Bool { get }
    var activationState: WCActivationState { get }

    func activate()
    func updateApplicationContext(_ context: [String: Any]) throws
    func sendMessage(_ message: [String: Any],
                     replyHandler: (@Sendable ([String: Any]) -> Void)?,
                     errorHandler: (@Sendable (Error) -> Void)?)
    func transferUserInfo(_ userInfo: [String: Any])

    /// Delegate surface. The hosting `ConnectivityManager` sets these once.
    var onMessage:        (@Sendable ([String: Any]) -> Void)?        { get set }
    var onMessageData:    (@Sendable (Data) -> Void)?                 { get set }
    var onUserInfo:       (@Sendable ([String: Any]) -> Void)?        { get set }
    var onAppContext:     (@Sendable ([String: Any]) -> Void)?        { get set }
    var onReachability:   (@Sendable (Bool) -> Void)?                 { get set }
    var onActivation:     (@Sendable (WCActivationState, Error?) -> Void)? { get set }
}

/// Abstraction matching `WCSessionActivationState`. We re-export the real one
/// when WatchConnectivity is linked and shadow it with a compatible enum on
/// macOS / Linux so the rest of SleepKit compiles.
#if canImport(WatchConnectivity)
public typealias WCActivationState = WCSessionActivationState
#else
public enum WCActivationState: Int, Sendable {
    case notActivated = 0
    case inactive = 1
    case activated = 2
}
#endif

// MARK: - Real implementation

#if canImport(WatchConnectivity)

public final class DefaultWCSessionClient: NSObject, WCSessionClientProtocol, @unchecked Sendable {

    // Closures are mutated from the main actor in production, but WCSession
    // delegate methods fire on a private queue. We read these closures from
    // both sides, so they're protected by a lock.
    private let lock = NSLock()

    private var _onMessage:      (@Sendable ([String: Any]) -> Void)?
    private var _onMessageData:  (@Sendable (Data) -> Void)?
    private var _onUserInfo:     (@Sendable ([String: Any]) -> Void)?
    private var _onAppContext:   (@Sendable ([String: Any]) -> Void)?
    private var _onReachability: (@Sendable (Bool) -> Void)?
    private var _onActivation:   (@Sendable (WCActivationState, Error?) -> Void)?

    public var onMessage: (@Sendable ([String: Any]) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onMessage }
        set { lock.lock(); defer { lock.unlock() }; _onMessage = newValue }
    }
    public var onMessageData: (@Sendable (Data) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onMessageData }
        set { lock.lock(); defer { lock.unlock() }; _onMessageData = newValue }
    }
    public var onUserInfo: (@Sendable ([String: Any]) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onUserInfo }
        set { lock.lock(); defer { lock.unlock() }; _onUserInfo = newValue }
    }
    public var onAppContext: (@Sendable ([String: Any]) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onAppContext }
        set { lock.lock(); defer { lock.unlock() }; _onAppContext = newValue }
    }
    public var onReachability: (@Sendable (Bool) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onReachability }
        set { lock.lock(); defer { lock.unlock() }; _onReachability = newValue }
    }
    public var onActivation: (@Sendable (WCActivationState, Error?) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onActivation }
        set { lock.lock(); defer { lock.unlock() }; _onActivation = newValue }
    }

    private let session: WCSession

    public override init() {
        self.session = .default
        super.init()
    }

    public var isSupported: Bool { WCSession.isSupported() }
    public var isReachable: Bool { session.isReachable }

    public var isPaired: Bool {
        #if os(iOS)
        return session.isPaired
        #else
        return true
        #endif
    }

    public var isWatchAppInstalled: Bool {
        #if os(iOS)
        return session.isWatchAppInstalled
        #else
        return true
        #endif
    }

    public var activationState: WCActivationState { session.activationState }

    public func activate() {
        guard WCSession.isSupported() else { return }
        if session.delegate == nil {
            session.delegate = self
        }
        session.activate()
    }

    public func updateApplicationContext(_ context: [String: Any]) throws {
        try session.updateApplicationContext(context)
    }

    public func sendMessage(_ message: [String: Any],
                            replyHandler: (@Sendable ([String: Any]) -> Void)?,
                            errorHandler: (@Sendable (Error) -> Void)?) {
        guard session.activationState == .activated else {
            errorHandler?(NSError(domain: "WCSessionClient", code: -1,
                                  userInfo: [NSLocalizedDescriptionKey: "session not activated"]))
            return
        }
        guard session.isReachable else {
            errorHandler?(NSError(domain: "WCSessionClient", code: -2,
                                  userInfo: [NSLocalizedDescriptionKey: "counterpart not reachable"]))
            return
        }
        session.sendMessage(message, replyHandler: replyHandler, errorHandler: errorHandler)
    }

    public func transferUserInfo(_ userInfo: [String: Any]) {
        session.transferUserInfo(userInfo)
    }

    // MARK: Closure snapshots (lock-protected reads)

    private func snapMessage()      -> (@Sendable ([String: Any]) -> Void)? { lock.lock(); defer { lock.unlock() }; return _onMessage }
    private func snapMessageData()  -> (@Sendable (Data) -> Void)?          { lock.lock(); defer { lock.unlock() }; return _onMessageData }
    private func snapUserInfo()     -> (@Sendable ([String: Any]) -> Void)? { lock.lock(); defer { lock.unlock() }; return _onUserInfo }
    private func snapAppContext()   -> (@Sendable ([String: Any]) -> Void)? { lock.lock(); defer { lock.unlock() }; return _onAppContext }
    private func snapReachability() -> (@Sendable (Bool) -> Void)?          { lock.lock(); defer { lock.unlock() }; return _onReachability }
    private func snapActivation()   -> (@Sendable (WCActivationState, Error?) -> Void)? {
        lock.lock(); defer { lock.unlock() }; return _onActivation
    }
}

extension DefaultWCSessionClient: WCSessionDelegate {
    public func session(_ session: WCSession,
                        activationDidCompleteWith activationState: WCSessionActivationState,
                        error: Error?) {
        snapActivation()?(activationState, error)
    }

    #if os(iOS)
    public func sessionDidBecomeInactive(_ session: WCSession) {}
    public func sessionDidDeactivate(_ session: WCSession) {
        WCSession.default.activate()
    }
    #endif

    public func sessionReachabilityDidChange(_ session: WCSession) {
        snapReachability()?(session.isReachable)
    }

    public func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        snapMessage()?(message)
    }

    public func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        snapMessageData()?(messageData)
    }

    public func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        snapUserInfo()?(userInfo)
    }

    public func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        snapAppContext()?(applicationContext)
    }
}

#endif
