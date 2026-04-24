import Foundation

// MARK: - In-memory single-endpoint stub

/// Loopback manager useful for previews, SwiftUI canvases, and as a safe
/// default when `WCSession` is unavailable. Messages sent here round-trip
/// back to the inbound handler on the same thread.
public final class InMemoryConnectivityManager: ConnectivityManagerProtocol, @unchecked Sendable {

    private let lock = NSLock()
    private var inbound:     (@Sendable (MessageEnvelope) -> Void)?
    private var reachHandler:(@Sendable (Bool) -> Void)?
    public private(set) var isReachable: Bool = true

    public init() {}

    public var isSupported: Bool         { true }
    public var isPaired: Bool            { true }
    public var isWatchAppInstalled: Bool { true }

    public func activate() {}

    public func sendImmediateMessage(_ envelope: MessageEnvelope) throws {
        guard isReachable else { throw ConnectivityError.notReachable }
        dispatchInbound(envelope)
    }

    public func sendGuaranteedMessage(_ envelope: MessageEnvelope) {
        dispatchInbound(envelope)
    }

    public func updateStatusSnapshot(_ snapshot: StatusSnapshotPayload, sessionId: String?) throws {
        let env = try WatchMessage.status(sessionId: sessionId, payload: snapshot)
        dispatchInbound(env)
    }

    public func setInboundHandler(_ handler: @escaping @Sendable (MessageEnvelope) -> Void) {
        lock.lock(); defer { lock.unlock() }
        inbound = handler
    }

    public func setReachabilityHandler(_ handler: @escaping @Sendable (Bool) -> Void) {
        lock.lock(); defer { lock.unlock() }
        reachHandler = handler
    }

    public func setReachable(_ reachable: Bool) {
        isReachable = reachable
        lock.lock(); let h = reachHandler; lock.unlock()
        h?(reachable)
    }

    private func dispatchInbound(_ env: MessageEnvelope) {
        lock.lock(); let h = inbound; lock.unlock()
        h?(env)
    }
}

// MARK: - Paired mock bus

/// Back-to-back pair of in-memory managers simulating a phone/watch link.
/// Messages sent from `.phone` arrive on `.watch` and vice versa.
///
/// Useful in unit tests where we want to exercise the whole telemetry pipeline
/// without real `WCSession`.
public final class MockConnectivityBus: @unchecked Sendable {

    public let phone: InMemoryConnectivityManager
    public let watch: InMemoryConnectivityManager

    public init(reachable: Bool = true) {
        self.phone = InMemoryConnectivityManager()
        self.watch = InMemoryConnectivityManager()
        self.phone.setReachable(reachable)
        self.watch.setReachable(reachable)
        wireAsPair()
    }

    public func setReachable(_ reachable: Bool) {
        phone.setReachable(reachable)
        watch.setReachable(reachable)
    }

    // Re-route each endpoint's outbound path to the other's inbound handler.
    private func wireAsPair() {
        let phoneEndpoint = PairedEndpoint(wrapped: phone, counterpart: watch)
        let watchEndpoint = PairedEndpoint(wrapped: watch, counterpart: phone)
        phoneRouter = phoneEndpoint
        watchRouter = watchEndpoint
    }

    private var phoneRouter: PairedEndpoint?
    private var watchRouter: PairedEndpoint?

    /// Runs the block while routing phone→watch and watch→phone.
    /// Because `InMemoryConnectivityManager.sendImmediateMessage` dispatches
    /// inbound back to the same endpoint, the paired bus exposes
    /// `sendFromPhone` / `sendFromWatch` instead, which deliver to the
    /// counterpart.
    public func sendFromPhone(_ env: MessageEnvelope) throws {
        guard let r = phoneRouter else { throw ConnectivityError.notActivated }
        try r.forward(env)
    }
    public func sendFromWatch(_ env: MessageEnvelope) throws {
        guard let r = watchRouter else { throw ConnectivityError.notActivated }
        try r.forward(env)
    }
}

private final class PairedEndpoint: @unchecked Sendable {
    let wrapped: InMemoryConnectivityManager
    weak var counterpart: InMemoryConnectivityManager?
    init(wrapped: InMemoryConnectivityManager, counterpart: InMemoryConnectivityManager) {
        self.wrapped = wrapped
        self.counterpart = counterpart
    }
    func forward(_ env: MessageEnvelope) throws {
        guard wrapped.isReachable else { throw ConnectivityError.notReachable }
        // Re-inject into the counterpart's inbound pipeline.
        counterpart?.sendGuaranteedMessage(env)
    }
}
