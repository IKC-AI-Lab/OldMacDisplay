import Foundation
import Network
import OldMacDisplayShared

/// One connected Receiver.
///
/// Owns the control transport, the protocol handshake, the heartbeat and,
/// once the Receiver has attached one, a second transport that carries only
/// video. Splitting the two keeps a keyframe request or a ping from queueing
/// behind a 300 KB IDR on a stalled link. The server can hold at most one of
/// these, but nothing here assumes that.
final class HostSession {
    struct Peer: Equatable {
        var device: DeviceInfo?
        var capabilities: ClientCapabilities?
        var endpoint: String
    }

    /// Fired on `callbackQueue` whenever the UI needs to update.
    var onPeerChange: ((Peer) -> Void)?
    var onStateChange: ((ConnectionState) -> Void)?
    var onLatency: ((LatencyTracker) -> Void)?
    var onNegotiated: ((SessionConfiguration) -> Void)?
    var onEnded: ((HostSession) -> Void)?
    /// The Receiver lost sync and needs a fresh IDR.
    var onKeyframeRequested: (() -> Void)?
    /// Reports how many frames the link forced us to drop.
    var onDroppedFrame: ((Int) -> Void)?
    /// What the Receiver says it is actually managing to display.
    var onReceiverStats: ((ControlMessage.NetworkStats) -> Void)?

    /// Why a session ended. Decides whether the virtual display outlives it.
    enum EndCause: Equatable {
        /// Either side hung up on purpose. The display goes with it.
        case deliberate
        /// The Receiver vanished without a goodbye: it slept, lost its link,
        /// or this Mac slept. It will most likely come back.
        case lost
    }

    private(set) var peer: Peer
    /// Set on `queue` before `onEnded` fires; read in `onEnded`.
    private(set) var endCause: EndCause = .lost
    private(set) var stateMachine = ConnectionStateMachine()

    /// Presented by the Receiver on its second connection so the server can
    /// pair it with this session.
    let sessionToken = UUID().uuidString

    private let transport: MessageTransport
    private var videoTransport: MessageTransport?
    private let queue: DispatchQueue
    private let callbackQueue: DispatchQueue
    private let systemInfo: HostSystemInfo
    private var preferences: HostPreferences
    private var heartbeat: Heartbeat!
    private let log = Log(.network)

    // Everything below is touched on `queue` only.
    private var ended = false
    private var streaming = false
    private var framesInFlight = 0
    private var keyframeRequestedForDrop = false
    /// Frames dropped because the link could not keep up. Surfaced in the UI so
    /// a bad network is visible rather than just "feeling" slow.
    private(set) var droppedFrames = 0

    init(transport: MessageTransport,
         endpoint: String,
         systemInfo: HostSystemInfo,
         preferences: HostPreferences,
         queue: DispatchQueue,
         callbackQueue: DispatchQueue = .main) {
        self.transport = transport
        self.queue = queue
        self.callbackQueue = callbackQueue
        self.systemInfo = systemInfo
        self.preferences = preferences
        self.peer = Peer(device: nil, capabilities: nil, endpoint: endpoint)

        self.heartbeat = Heartbeat(queue: queue) { [weak self] message in
            self?.send(message)
        }
        self.heartbeat.onSample = { [weak self] tracker in
            guard let self else { return }
            self.callbackQueue.async { self.onLatency?(tracker) }
        }
        self.heartbeat.onTimeout = { [weak self] in
            guard let self else { return }
            // The Host never reconnects (the Receiver does), so this is a
            // terminal state, not the start of a grace period.
            let reason = "Receiver stopped responding"
            self.log.error(reason)
            self.advance(.disconnectRequested(reason: reason))
            self.finish()
        }
    }

    /// Takes over a transport the server already started to read the first
    /// frame from. `firstFrame` is that frame, replayed into the session.
    func start(preconnectedWith firstFrame: OMDFrame?) {
        transport.onStateChange = { [weak self] state in self?.handleTransport(state) }
        transport.onFrame = { [weak self] frame in self?.handle(frame) }
        transport.onError = { [weak self] error in
            self?.log.failure("Session transport", error)
        }
        advance(.connectRequested)
        advance(.transportReady)
        heartbeat.start()
        if let frame = firstFrame { handle(frame) }
    }

    func disconnect(reason: String) {
        queue.async { [weak self] in
            guard let self else { return }
            // Tell the peer why, on a best-effort basis, before tearing down.
            self.send(.disconnect(.init(reason: reason)))
            self.advance(.disconnectRequested(reason: reason))
            self.finish(.deliberate)
        }
    }

    /// The same Receiver has connected again, so this session is a leftover
    /// its peer has already given up on. Typical after this Mac wakes from
    /// sleep: the uptime clock stops while asleep, so the heartbeat has not
    /// yet noticed the silence when the Receiver's reconnect arrives. Ends
    /// as `.lost` so the virtual display survives for the new session.
    /// On `queue`.
    func supersede() {
        log.notice("Receiver reconnected; replacing its previous session")
        advance(.disconnectRequested(reason: "Receiver reconnected"))
        finish(.lost)
    }

    /// The Receiver behind this session, once its `hello` has arrived.
    /// On `queue`.
    var peerDeviceID: String? { peer.device?.deviceID }

    func updatePreferences(_ preferences: HostPreferences) {
        queue.async { [weak self] in
            self?.preferences = preferences
            self?.renegotiateIfPossible()
        }
    }

    // MARK: - Video transport

    /// Binds a second, already-ready transport as the video carrier. Called by
    /// the server on `queue` once the connection has presented a matching
    /// `attachVideo`.
    func attachVideoTransport(_ videoTransport: MessageTransport) {
        self.videoTransport?.stop()
        self.videoTransport = videoTransport
        videoTransport.onFrame = { [weak self] frame in
            // Nothing is expected inbound on the video carrier, but a peer
            // that sends control here is still answered.
            self?.handle(frame)
        }
        videoTransport.onStateChange = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed(let reason):
                self.log.error("Video transport failed: \(reason); falling back to the control connection")
                self.detachVideoTransport()
            case .cancelled:
                self.log.info("Video transport closed; falling back to the control connection")
                self.detachVideoTransport()
            default:
                break
            }
        }
        log.info("Video now carried on a separate connection")
        // The Receiver's decoder starts from nothing on the new carrier.
        requestKeyframe()
    }

    private func detachVideoTransport() {
        guard videoTransport != nil else { return }
        videoTransport?.onStateChange = nil
        videoTransport?.onFrame = nil
        videoTransport = nil
        framesInFlight = 0
        requestKeyframe()
    }

    // MARK: - Transport

    private func handleTransport(_ state: TransportState) {
        switch state {
        case .ready:
            advance(.transportReady)
            heartbeat.start()
        case .failed(let reason):
            log.error("Session transport failed: \(reason)")
            advance(.disconnectRequested(reason: "Connection failed: \(reason)"))
            finish()
        case .cancelled:
            advance(.disconnectRequested(reason: "Receiver disconnected"))
            finish()
        case .waiting(let reason):
            // Inbound connections should not wait; if one does, the peer is
            // unreachable and the session is effectively dead.
            log.notice("Session transport waiting: \(reason)")

        case .setup, .preparing:
            break
        }
    }

    private func handle(_ frame: OMDFrame) {
        guard frame.channel == .control else {
            // Video/audio/input channels are not handled inbound.
            return
        }
        let message: ControlMessage
        do {
            message = try ControlCodec.decode(frame.payload)
        } catch {
            log.failure("Decoding control message", error)
            send(.error(.init(code: "E_DECODE", message: "\(error)")))
            return
        }

        if heartbeat.handle(message) { return }

        switch message {
        case .hello(let hello):
            handleHello(hello)
        case .clientCapabilities(let capabilities):
            handleCapabilities(capabilities)
        case .disconnect(let payload):
            log.info("Receiver disconnected: \(payload.reason)")
            advance(.disconnectRequested(reason: payload.reason))
            finish(.deliberate)
        case .networkStats(let stats):
            log.debug(String(format: "Receiver: %.1f fps displayed, %.1f%% dropped, queueing %.0f ms",
                             stats.fps, stats.droppedFrameRatio * 100,
                             stats.queueingDelayMillis ?? 0))
            callbackQueue.async { [weak self] in self?.onReceiverStats?(stats) }

        case .requestKeyframe:
            log.info("Receiver requested a keyframe")
            requestKeyframe()

        case .error(let payload):
            log.error("Receiver reported error \(payload.code): \(payload.message)")
        default:
            log.debug("Ignoring \(message.kind.rawValue)")
        }
    }

    private func requestKeyframe() {
        callbackQueue.async { [weak self] in self?.onKeyframeRequested?() }
    }

    private func handleHello(_ hello: ControlMessage.Hello) {
        guard hello.protocolVersion == Int(OMDProtocol.version) else {
            let message = "Receiver speaks protocol v\(hello.protocolVersion), host speaks v\(OMDProtocol.version)"
            log.error(message)
            send(.error(.init(code: "E_VERSION", message: message)))
            send(.disconnect(.init(reason: message)))
            advance(.disconnectRequested(reason: message))
            finish(.deliberate)
            return
        }
        peer.device = hello.device
        log.info("Hello from \(hello.device.name) (\(hello.device.model), macOS \(hello.device.osVersion))")
        notifyPeer()
        send(.hello(.init(device: systemInfo.device, sessionToken: sessionToken)))
    }

    private func handleCapabilities(_ capabilities: ClientCapabilities) {
        peer.capabilities = capabilities
        log.info("Receiver capabilities: \(capabilities.displayWidth)x\(capabilities.displayHeight) @\(capabilities.preferredFPS), h264hw=\(capabilities.h264HardwareDecode), hevchw=\(capabilities.hevcHardwareDecode), net=\(capabilities.activeNetworkType.rawValue)")
        notifyPeer()

        send(.serverCapabilities(serverCapabilities()))
        renegotiateIfPossible()

        // The handshake is complete once both sides have exchanged capabilities.
        advance(.handshakeCompleted)
    }

    private func serverCapabilities() -> ServerCapabilities {
        var codecs: [VideoCodec] = [.h264]
        if systemInfo.hevcHardwareEncode { codecs.append(.hevc) }
        return ServerCapabilities(
            supportedCodecs: codecs,
            h264HardwareEncode: systemInfo.h264HardwareEncode,
            hevcHardwareEncode: systemInfo.hevcHardwareEncode,
            supportsVirtualDisplay: true,
            availableModes: CapabilityNegotiator.preferredModeLadder.map {
                DisplayMode(width: $0.width, height: $0.height, refreshRate: 60)
            })
    }

    /// Runs the negotiation and reports the result to the server, which feeds
    /// it to the virtual display provider.
    private func renegotiateIfPossible() {
        guard let capabilities = peer.capabilities else { return }
        let config = CapabilityNegotiator.negotiate(
            client: capabilities,
            server: serverCapabilities(),
            preferences: preferences)
        log.info("Negotiated \(config.mode) \(config.codec.rawValue) @ \(config.targetBitrateBPS / 1_000_000) Mbps")
        send(.displayConfiguration(config))
        callbackQueue.async { [weak self] in self?.onNegotiated?(config) }
    }

    // MARK: - Video

    /// Announces the bitstream, then opens the video channel.
    func startVideoStream(_ configuration: ControlMessage.VideoConfiguration) {
        queue.async { [weak self] in
            guard let self else { return }
            self.send(.videoConfiguration(configuration))
            self.send(.streamStart)
            self.streaming = true
        }
    }

    func stopVideoStream() {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.streaming else { return }
            self.streaming = false
            self.send(.streamStop)
        }
    }

    /// Pointer updates ride the control connection: they are tiny, and they
    /// must not queue behind video.
    func sendCursor(_ update: ControlMessage.CursorUpdate) {
        queue.async { [weak self] in
            guard let self, self.streaming else { return }
            self.send(.cursor(update))
        }
    }

    /// Sends one compressed access unit or parameter-set blob.
    ///
    /// Called from the encoder's callback thread; the work happens on `queue`
    /// so the in-flight bookkeeping has a single owner.
    ///
    /// Applies backpressure. Measured on Wi-Fi, the link stalls for a few
    /// hundred milliseconds at a time (a 640 ms RTT spike was recorded while
    /// the median was 7 ms). At 57 fps that stall queues ~36 frames inside the
    /// socket, and every one of them is delivered late — the lag does not
    /// recover on its own, it accumulates.
    ///
    /// So when too many frames are already in flight, new ones are dropped
    /// instead of queued, and a keyframe is requested so the Receiver can
    /// resync cleanly. A brief stutter is much better than permanently growing
    /// latency, which is the whole trade this project is built around.
    ///
    /// Keyframes and parameter sets are never dropped: without them the
    /// Receiver cannot decode anything that follows.
    func sendVideo(_ packet: VideoPacket) {
        queue.async { [weak self] in
            self?.sendVideoOnQueue(packet)
        }
    }

    private func sendVideoOnQueue(_ packet: VideoPacket) {
        guard streaming, !ended else { return }

        let droppable = packet.kind == .accessUnit && !packet.isKeyframe
        if droppable, framesInFlight >= HostSession.maxFramesInFlight {
            droppedFrames += 1
            let total = droppedFrames
            callbackQueue.async { [weak self] in self?.onDroppedFrame?(total) }
            // Ask the encoder for a fresh IDR: the Receiver has just lost
            // frames and would otherwise decode against missing references.
            if !keyframeRequestedForDrop {
                keyframeRequestedForDrop = true
                requestKeyframe()
            }
            return
        }

        if packet.isKeyframe { keyframeRequestedForDrop = false }

        framesInFlight += 1
        let carrier = videoTransport ?? transport
        carrier.send(channel: .video, flags: 0, parts: packet.encodedParts()) { [weak self] _ in
            guard let self else { return }
            self.queue.async { self.framesInFlight = max(0, self.framesInFlight - 1) }
        }
    }

    /// Roughly 50 ms of video at 60 fps. Deep enough to ride out ordinary
    /// scheduling jitter, shallow enough that a real stall is noticed at once.
    private static let maxFramesInFlight = 3

    // MARK: - Plumbing

    private func send(_ message: ControlMessage) {
        do {
            try transport.sendControl(message)
        } catch {
            log.failure("Encoding \(message.kind.rawValue)", error)
        }
    }

    private func advance(_ event: ConnectionEvent) {
        guard stateMachine.handle(event) else { return }
        let state = stateMachine.state
        callbackQueue.async { [weak self] in self?.onStateChange?(state) }
    }

    private func notifyPeer() {
        let snapshot = peer
        callbackQueue.async { [weak self] in self?.onPeerChange?(snapshot) }
    }

    private func finish(_ cause: EndCause = .lost) {
        guard !ended else { return }
        ended = true
        endCause = cause
        streaming = false
        framesInFlight = 0
        heartbeat.stop()
        videoTransport?.stop()
        videoTransport = nil
        transport.stop()
        callbackQueue.async { [weak self] in
            guard let self else { return }
            self.onEnded?(self)
        }
    }

    static func describe(_ endpoint: NWEndpoint) -> String {
        switch endpoint {
        case .hostPort(let host, _):
            // Strip the IPv6 scope id ("fe80::1%en0") for display.
            return "\(host)".components(separatedBy: "%").first ?? "\(host)"
        default:
            return "\(endpoint)"
        }
    }
}
