import Foundation

public enum TransportState: Equatable {
    case setup
    case preparing
    /// The path is currently unusable - no route, firewall, or nothing
    /// listening on the port yet.
    ///
    /// Distinct from `failed` because `NWConnection` does not give up here: it
    /// stays in this state indefinitely and only re-evaluates on a network path
    /// change. A peer that simply restarts its listener never triggers one, so
    /// a client that wants to reconnect must treat this as retryable and open a
    /// fresh connection itself rather than waiting.
    case waiting(String)
    case ready
    case failed(String)
    case cancelled
}

/// Abstraction over "something that can carry OMD frames".
///
/// Both ends of the link talk to this rather than to `NWConnection` directly, so
/// the connection state machine, handshake and ping logic can be unit-tested
/// against an in-memory loopback transport with no sockets involved.
public protocol MessageTransport: AnyObject {
    var onStateChange: ((TransportState) -> Void)? { get set }
    var onFrame: ((OMDFrame) -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }

    /// The interface type actually carrying this connection, once it is up.
    ///
    /// More trustworthy than asking the system what the default route looks
    /// like: a direct Ethernet cable between two Macs has no internet path at
    /// all, so the default path reports unsatisfied even though the link is
    /// perfect. What matters is the interface our own traffic is on.
    var currentInterfaceType: NetworkType { get }

    func start()
    /// `completion` fires once the bytes have been handed to the transport,
    /// which is what lets a caller flush a final message before terminating.
    func send(_ frame: OMDFrame, completion: ((Error?) -> Void)?)
    /// Sends one frame whose payload is given in pieces, so a transport that
    /// can scatter-gather (Network.framework) never has to concatenate them.
    /// The pieces are contiguous on the wire; the peer sees one payload.
    func send(channel: OMDChannel, flags: UInt8, parts: [Data], completion: ((Error?) -> Void)?)
    func stop()
}

public extension MessageTransport {
    func send(_ frame: OMDFrame) {
        send(frame, completion: nil)
    }

    /// Default for transports without scatter-gather: build one payload.
    func send(channel: OMDChannel, flags: UInt8, parts: [Data], completion: ((Error?) -> Void)?) {
        var payload = Data(capacity: parts.reduce(0) { $0 + $1.count })
        for part in parts { payload.append(part) }
        send(OMDFrame(channel: channel, flags: flags, payload: payload), completion: completion)
    }

    /// Convenience for the control channel.
    func sendControl(_ message: ControlMessage, completion: ((Error?) -> Void)? = nil) throws {
        send(OMDFrame(channel: .control, payload: try ControlCodec.encode(message)),
             completion: completion)
    }
}

/// Standard low-latency TCP options for this project.
///
/// Nagle's algorithm is disabled everywhere: it would coalesce small control
/// messages and, later, video slices, adding tens of milliseconds for no benefit
/// on a LAN.
public enum TCPTuning {
    public static let noDelay = true
    /// Keepalive is a safety net only. Liveness is the application-level
    /// heartbeat (`Heartbeat.timeout`); these used to be 2 s / 1 s / 3, which
    /// declared an idle video connection dead after a five-second stall and
    /// dropped whole sessions on a still desktop.
    public static let keepaliveIdleSeconds = 15
    public static let keepaliveCount = 4
    public static let keepaliveIntervalSeconds = 5
    public static let connectionTimeoutSeconds = 5
}
