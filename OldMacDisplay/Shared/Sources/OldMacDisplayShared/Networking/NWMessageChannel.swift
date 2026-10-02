import Foundation
import Network

/// `MessageTransport` implemented on Network.framework.
///
/// Available on macOS 10.15, so the same implementation serves the Catalina
/// Receiver and the modern Host. Deliberately callback-based (no async/await) to
/// keep the Receiver binary free of back-deployed concurrency runtime.
public final class NWMessageChannel: MessageTransport {
    public var onStateChange: ((TransportState) -> Void)?
    public var onFrame: ((OMDFrame) -> Void)?
    public var onError: ((Error) -> Void)?

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let log = Log(.network)
    private var stopped = false

    /// Wraps an already-created connection (server side, from `NWListener`).
    public init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    /// Creates an outbound connection (client side).
    ///
    /// `requiredInterfaceType` pins the connection to one kind of link. Only
    /// use it with a concrete `hostPort` endpoint on that link: with a
    /// Bonjour service endpoint the constraint stalls the connection (see
    /// `parameters()`).
    public convenience init(endpoint: NWEndpoint, queue: DispatchQueue,
                            requiredInterfaceType: NWInterface.InterfaceType? = nil) {
        let params = NWMessageChannel.parameters()
        if let type = requiredInterfaceType { params.requiredInterfaceType = type }
        self.init(connection: NWConnection(to: endpoint, using: params), queue: queue)
    }

    /// Low-latency TCP parameters shared by both ends.
    ///
    /// Deliberately places no interface constraint on the connection. Two kinds
    /// were tried, to keep a VPN from stealing a LAN session, and both stalled
    /// it instead: `requiredInterface` pinned to the NIC a Bonjour service was
    /// discovered on, and `prohibitedInterfaceTypes` excluding the links the
    /// user had not picked. In each case `NWConnection` sat in `.preparing`
    /// indefinitely — emitting neither `waiting` nor `failed` — because a
    /// resolved Bonjour endpoint carries addresses for every one of the peer's
    /// interfaces, and a constraint that rules out the route to the address
    /// being tried leaves nothing to fall back to. Measured directly against a
    /// running Host: unconstrained connects (and picks Ethernet on its own,
    /// since routing already prefers it); Wi-Fi-only never connects at all.
    ///
    /// So the link choice in the Use As Display pane filters which Hosts are
    /// listed, and routing decides the path. Keeping a VPN off the session is
    /// unsolved; see docs/RECEIVER_COMPATIBILITY.md.
    public static func parameters() -> NWParameters {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = TCPTuning.noDelay
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = TCPTuning.keepaliveIdleSeconds
        tcp.keepaliveCount = TCPTuning.keepaliveCount
        tcp.keepaliveInterval = TCPTuning.keepaliveIntervalSeconds
        tcp.connectionTimeout = TCPTuning.connectionTimeoutSeconds

        let params = NWParameters(tls: nil, tcp: tcp)
        // Ask the scheduler to treat this as interactive traffic.
        params.serviceClass = .responsiveData

        return params
    }

    public var currentInterfaceType: NetworkType {
        guard let interface = connection.currentPath?.availableInterfaces.first else {
            return .unknown
        }
        switch interface.type {
        case .wiredEthernet: return .ethernet
        case .wifi:          return .wifi
        case .cellular, .loopback, .other: return .other
        @unknown default:    return .other
        }
    }

    /// The concrete address this connection resolved to, once ready.
    ///
    /// A Bonjour service endpoint resolves to every address the peer has; this
    /// is the one that actually worked. A second connection to the same peer
    /// (the video carrier) is opened to this address so it lands on the same
    /// interface without another resolution round.
    public var remoteEndpoint: NWEndpoint? {
        connection.currentPath?.remoteEndpoint
    }

    public func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .setup:
                self.onStateChange?(.setup)
            case .preparing:
                self.onStateChange?(.preparing)
            case .waiting(let error):
                self.log.notice("Transport waiting on \(self.connection.endpoint): \(error)")
                self.onStateChange?(.waiting(error.localizedDescription))
            case .ready:
                self.log.info("Transport ready to \(self.connection.endpoint)")
                self.onStateChange?(.ready)
                self.receiveHeader()
            case .failed(let error):
                self.log.error("Transport failed: \(error)")
                self.onStateChange?(.failed(error.localizedDescription))
            case .cancelled:
                self.onStateChange?(.cancelled)
            @unknown default:
                break
            }
        }
        connection.start(queue: queue)
    }

    public func send(_ frame: OMDFrame, completion: ((Error?) -> Void)?) {
        send(channel: frame.channel, flags: frame.flags, parts: [frame.payload], completion: completion)
    }

    /// Scatter-gather send: header and each payload part go to the socket as
    /// separate buffers inside one batch, so a 300 KB keyframe is never copied
    /// into a fresh `Data` just to prepend 28 bytes of headers. The batch keeps
    /// the pieces contiguous on the wire.
    public func send(channel: OMDChannel, flags: UInt8, parts: [Data],
                     completion: ((Error?) -> Void)?) {
        let header: Data
        do {
            header = try WireFormat.encodeHeader(channel: channel, flags: flags,
                                                 payloadLength: parts.reduce(0) { $0 + $1.count })
        } catch {
            log.failure("Encoding outbound frame", error)
            onError?(error)
            completion?(error)
            return
        }

        let buffers = [header] + parts.filter { !$0.isEmpty }
        connection.batch {
            for (index, buffer) in buffers.enumerated() {
                let isLast = index == buffers.count - 1
                if isLast {
                    connection.send(content: buffer, completion: .contentProcessed { [weak self] error in
                        if let error = error {
                            self?.log.failure("Sending frame", error)
                            self?.onError?(error)
                        }
                        completion?(error)
                    })
                } else {
                    connection.send(content: buffer, completion: .idempotent)
                }
            }
        }
    }

    public func stop() {
        stopped = true
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    // MARK: - Receive

    /// Reads exactly one header, then exactly its payload.
    ///
    /// Asking for precise lengths means the payload `Data` handed to `onFrame`
    /// is the buffer Network.framework filled — no accumulation buffer, no
    /// parser, no copy. The previous 64 KB chunked reads made a single 1080p
    /// keyframe cost several callbacks plus an O(n) buffer compaction each.
    private func receiveHeader() {
        let length = WireFormat.headerLength
        connection.receive(minimumIncompleteLength: length, maximumLength: length) {
            [weak self] data, _, isComplete, error in
            guard let self = self, !self.stopped else { return }

            if let data = data, data.count == length {
                let header: WireFormat.Header
                do {
                    header = try WireFormat.decodeHeader(data)
                } catch {
                    // A malformed stream is unrecoverable: there is no way to
                    // resynchronise safely, so surface it and tear down.
                    self.fail("Parsing inbound header", error)
                    return
                }
                if header.payloadLength == 0 {
                    self.onFrame?(OMDFrame(channel: header.channel, flags: header.flags, payload: Data()))
                    self.receiveHeader()
                } else {
                    self.receivePayload(for: header)
                }
                return
            }

            self.finish(isComplete: isComplete, error: error)
        }
    }

    private func receivePayload(for header: WireFormat.Header) {
        let length = Int(header.payloadLength)
        connection.receive(minimumIncompleteLength: length, maximumLength: length) {
            [weak self] data, _, isComplete, error in
            guard let self = self, !self.stopped else { return }

            if let data = data, data.count == length {
                self.onFrame?(OMDFrame(channel: header.channel, flags: header.flags, payload: data))
                self.receiveHeader()
                return
            }

            self.finish(isComplete: isComplete, error: error)
        }
    }

    private func fail(_ context: String, _ error: Error) {
        log.failure(context, error)
        onError?(error)
        onStateChange?(.failed("Protocol error: \(error)"))
        stop()
    }

    private func finish(isComplete: Bool, error: Error?) {
        if let error = error {
            log.failure("Receiving", error)
            onError?(error)
            onStateChange?(.failed(error.localizedDescription))
            return
        }
        if isComplete {
            log.info("Peer closed the connection")
            onStateChange?(.cancelled)
            return
        }
        // Short read without EOF or error should not happen with exact
        // lengths; treat it as a broken stream rather than spinning.
        onStateChange?(.failed("Truncated frame"))
        stop()
    }
}
