import Foundation
import Network
import CoreMedia
import OldMacDisplayShared

/// The Receiver's side of a session with one Host.
///
/// Owns discovery-independent connection logic: connect, handshake, heartbeat,
/// a second connection for video once the Host has issued a session token,
/// and automatic reconnection within a grace period so a briefly unplugged
/// Ethernet cable does not end the session.
final class ReceiverClient {
    struct Status: Equatable {
        var state: ConnectionState = .idle
        var hostName: String?
        var hostDevice: DeviceInfo?
        var serverCapabilities: ServerCapabilities?
        var negotiated: SessionConfiguration?
        var latencyMilliseconds: Double?
        /// Capture-to-enqueue latency once the clocks have been aligned.
        var endToEndMilliseconds: Double?
        var networkType: NetworkType = .unknown
        var lastError: String?
        var video: ControlMessage.VideoConfiguration?
        var streaming = false
        var measuredFPS: Double = 0
        var measuredBitrateBPS: Int = 0
        /// True while video arrives on its own connection.
        var videoOnSeparateConnection = false
    }

    /// How long to keep retrying before declaring the session dead.
    ///
    /// Long enough to ride out the Host sleeping for a few minutes (lid
    /// closed, or the Apple menu's Sleep). The Host keeps the virtual display
    /// for a Receiver that dropped off, so coming back finds the same windows.
    /// Retries are cheap: at most one connection attempt every 2 s.
    var reconnectGracePeriod: TimeInterval = 5 * 60

    var onStatusChange: ((Status) -> Void)?
    /// Pointer updates, delivered on `callbackQueue`.
    var onCursor: ((ControlMessage.CursorUpdate) -> Void)?

    /// Supplies renderer counters for the stats report sent back to the Host.
    /// Set through `setDisplayStatsProvider`; called on the network queue, so
    /// the provider must be thread-safe.
    private var displayStatsProvider: (() -> (displayed: Int, dropped: Int))?

    /// Only ever read or written on `callbackQueue`.
    private(set) var status = Status() {
        didSet {
            guard status != oldValue else { return }
            let snapshot = status
            callbackQueue.async { [weak self] in self?.onStatusChange?(snapshot) }
        }
    }

    private let profile: ReceiverHardwareProfile
    private let queue = DispatchQueue(label: "com.oldmacdisplay.receiver.network",
                                      qos: .userInteractive)
    private let callbackQueue: DispatchQueue
    private let pathObserver: PathObserver
    private let log = Log(.network)

    /// One way of reaching the Host. The plan is tried in order; a pinned
    /// attempt that does not come up within its timeout falls through to the
    /// next rather than counting as a lost connection.
    private struct ConnectAttempt {
        let endpoint: NWEndpoint
        /// Pins the connection to this kind of link. Only ever set together
        /// with a concrete `hostPort` endpoint on that link.
        let interfaceType: NWInterface.InterfaceType?
        let timeout: TimeInterval
        var label: String {
            switch interfaceType {
            case .wiredEthernet?: return "Ethernet-pinned \(endpoint)"
            case .wifi?: return "Wi-Fi-pinned \(endpoint)"
            default: return "unpinned \(endpoint)"
            }
        }
    }

    // Everything below is touched on `queue` only.
    private var transport: NWMessageChannel?
    private var videoTransport: NWMessageChannel?
    private var heartbeat: Heartbeat?
    private var stateMachine = ConnectionStateMachine()
    private var plan: [ConnectAttempt] = []
    private var planIndex = 0
    private var target: NWEndpoint? { plan.first?.endpoint }
    private var reconnectDeadline: Date?
    private var connectWatchdog: DispatchSourceTimer?
    private var reconnectTimer: DispatchSourceTimer?
    private var userInitiatedDisconnect = false

    private let assembler = SampleBufferAssembler()
    /// Where decoded-and-ready sample buffers go. Invoked on `queue`, straight
    /// from the receive path: no hop through the main queue, which the UI
    /// shares and which added visible jitter under load.
    private var videoSink: ((CMSampleBuffer) -> Void)?
    private var lastKeyframeRequest: Double = 0
    private var videoWindowStart = MonotonicClock.now()
    private var videoWindowFrames = 0
    private var videoWindowBytes = 0
    private var queueing = QueueingDelayTracker()
    private var endToEndSum: Double = 0
    private var endToEndCount = 0
    /// Token from the Host's `hello`, kept so the video carrier can be
    /// re-attached if it drops while the control connection is fine.
    private var sessionToken: String?
    private var videoReattachTimer: DispatchSourceTimer?
    private var videoReattachAttempts = 0
    /// Keeps the Mac and App Nap from interfering while a stream is up.
    private var activity: NSObjectProtocol?

    init(profile: ReceiverHardwareProfile, callbackQueue: DispatchQueue = .main) {
        self.profile = profile
        self.callbackQueue = callbackQueue
        self.pathObserver = PathObserver(queue: queue)

        pathObserver.onChange = { [weak self] snapshot in
            guard let self = self else { return }
            // Only meaningful while a session exists: idle, the default path is
            // whatever this Mac happens to route the internet over, which says
            // nothing about how the Host would be reached.
            let link = self.transport?.currentInterfaceType ?? .unknown
            self.callbackQueue.async {
                self.status.networkType = link == .unknown ? .unknown : snapshot.activeType
            }
        }
        pathObserver.start()
    }

    // MARK: - Public API

    /// `link` is the link the user picked in the pane. When the Host
    /// published its address on that link, the first attempt goes straight to
    /// it, pinned to that interface type, so a Mac with both a cable and
    /// Wi-Fi is actually reached over the cable. The plain service endpoint
    /// remains as the fallback.
    func connect(to host: DiscoveredHost, preferring link: LinkFilter? = nil) {
        var plan: [ConnectAttempt] = []
        if let link = link, let direct = host.directEndpoint(over: link) {
            plan.append(ConnectAttempt(endpoint: direct, interfaceType: link.interfaceType, timeout: 4))
        }
        plan.append(ConnectAttempt(endpoint: host.endpoint, interfaceType: nil, timeout: 6))

        queue.async { [weak self] in
            guard let self = self else { return }
            self.userInitiatedDisconnect = false
            self.plan = plan
            self.planIndex = 0
            self.reconnectDeadline = nil
            self.callbackQueue.async { self.status.hostName = host.serviceName }
            self.advance(.connectRequested)
            self.openTransport()
        }
    }

    /// `completion` runs once the goodbye frame has been handed to the
    /// transport, so a caller shutting the app down can wait for the flush.
    func disconnect(completion: (() -> Void)? = nil) {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.userInitiatedDisconnect = true
            let reason = "Disconnected by user"

            let finish: () -> Void = {
                self.advance(.disconnectRequested(reason: reason))
                self.teardown()
                completion?()
            }

            if let transport = self.transport {
                do {
                    try transport.sendControl(.disconnect(.init(reason: reason))) { _ in
                        finish()
                    }
                } catch {
                    self.log.failure("Encoding disconnect", error)
                    finish()
                }
            } else {
                finish()
            }

            self.clearSessionState()
        }
    }

    /// Installs the consumer of decoded frames. Takes effect on the network
    /// queue so the receive path never reads a half-assigned closure.
    func setVideoSink(_ sink: ((CMSampleBuffer) -> Void)?) {
        queue.async { [weak self] in self?.videoSink = sink }
    }

    func setDisplayStatsProvider(_ provider: (() -> (displayed: Int, dropped: Int))?) {
        queue.async { [weak self] in self?.displayStatsProvider = provider }
    }

    /// The renderer had to discard a frame and the decoder's reference chain
    /// is broken until the next IDR.
    func requestKeyframe() {
        queue.async { [weak self] in self?.requestKeyframeThrottled() }
    }

    /// Clears everything that describes a live session.
    ///
    /// Must run on every path that ends one — user disconnect, host disconnect,
    /// protocol error, grace period expiry. Leaving `streaming`/`video` set was
    /// what kept the stream window open as a black rectangle after a
    /// disconnect: the UI re-opened it from stale state the moment it closed.
    private func clearSessionState() {
        callbackQueue.async { [weak self] in
            guard let self = self else { return }
            self.status.streaming = false
            self.status.video = nil
            self.status.hostDevice = nil
            self.status.negotiated = nil
            self.status.latencyMilliseconds = nil
            self.status.endToEndMilliseconds = nil
            self.status.measuredFPS = 0
            self.status.measuredBitrateBPS = 0
            self.status.networkType = .unknown
            self.status.videoOnSeparateConnection = false
        }
    }

    // MARK: - Transport lifecycle

    private func openTransport() {
        guard !plan.isEmpty else { return }
        teardownTransport()
        if planIndex >= plan.count { planIndex = 0 }
        let attempt = plan[planIndex]
        log.info("Connecting: \(attempt.label)")

        let channel = NWMessageChannel(endpoint: attempt.endpoint, queue: queue,
                                       requiredInterfaceType: attempt.interfaceType)
        channel.onStateChange = { [weak self] state in self?.handleTransport(state) }
        channel.onFrame = { [weak self] frame in self?.handle(frame) }
        channel.onError = { [weak self] error in
            self?.log.failure("Client transport", error)
        }
        transport = channel

        let heartbeat = Heartbeat(queue: queue) { [weak self] message in
            self?.sendControl(message)
        }
        heartbeat.onSample = { [weak self] tracker in
            guard let self = self else { return }
            self.callbackQueue.async { self.status.latencyMilliseconds = tracker.smoothedMilliseconds }
        }
        heartbeat.onTimeout = { [weak self] in
            guard let self = self else { return }
            self.log.error("Host stopped responding")
            self.setLastError("Host stopped responding")
            self.beginReconnect(reason: "Host stopped responding")
        }
        self.heartbeat = heartbeat

        armConnectWatchdog(timeout: attempt.timeout)
        channel.start()
    }

    /// A connection attempt failed before becoming ready. If the plan has a
    /// fallback (the pinned attempt did not come up), try that next without
    /// entering the reconnect state; otherwise it is a real failure.
    private func attemptFailed(reason: String) {
        if planIndex + 1 < plan.count {
            log.notice("Attempt \(plan[planIndex].label) failed (\(reason)); trying the next")
            planIndex += 1
            openTransport()
        } else {
            planIndex = 0
            setLastError(reason)
            beginReconnect(reason: reason)
        }
    }

    /// `NWConnection` can sit in `.preparing` indefinitely when it is pinned to
    /// an interface that cannot reach the Host, emitting neither `waiting` nor
    /// `failed`. Without this the UI would show "Connecting" forever.
    private func armConnectWatchdog(timeout: TimeInterval) {
        connectWatchdog?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.connectWatchdog = nil
            self.log.error("Connection did not become ready within \(Int(timeout))s")
            self.attemptFailed(reason: "Connection timed out")
        }
        connectWatchdog = timer
        timer.resume()
    }

    /// True until the current attempt has come up.
    private var connecting: Bool { connectWatchdog != nil }

    private func setLastError(_ message: String?) {
        callbackQueue.async { [weak self] in self?.status.lastError = message }
    }

    private func handleTransport(_ state: TransportState) {
        switch state {
        case .ready:
            connectWatchdog?.cancel()
            connectWatchdog = nil
            let link = transport?.currentInterfaceType ?? .unknown
            log.info("Connected over \(link.rawValue) via \(plan[planIndex].label)")
            callbackQueue.async { [weak self] in self?.status.networkType = link }
            advance(.transportReady)
            reconnectDeadline = nil
            setLastError(nil)
            sendHandshake()
            heartbeat?.start()

        case .failed(let reason):
            log.error("Transport failed: \(reason)")
            if connecting {
                attemptFailed(reason: reason)
            } else {
                setLastError(reason)
                beginReconnect(reason: reason)
            }

        case .waiting(let reason):
            // NWConnection will sit here forever once the Host's listener has
            // gone away, so drive the retry ourselves.
            log.notice("Transport waiting (\(reason)); retrying")
            if connecting {
                attemptFailed(reason: reason)
            } else {
                setLastError(reason)
                beginReconnect(reason: reason)
            }

        case .cancelled:
            if !userInitiatedDisconnect { beginReconnect(reason: "Connection closed") }

        case .setup, .preparing:
            break
        }
    }

    private func sendHandshake() {
        sendControl(.hello(.init(device: profile.deviceInfo)))

        // Prefer the interface this connection is genuinely using over the
        // system's default-path guess. On a direct Ethernet cable there is no
        // internet route, so the default path reports `unknown` and the Host
        // would cap the stream as if this were a poor wireless link — exactly
        // backwards for the best connection available.
        var snapshot = pathObserver.snapshot
        let actual = transport?.currentInterfaceType ?? .unknown
        if actual != .unknown, actual != snapshot.activeType {
            log.info("Link type from the live connection: \(actual.rawValue) (default path said \(snapshot.activeType.rawValue))")
            snapshot = PathObserver.Snapshot(
                isSatisfied: true,
                activeType: actual,
                ethernetAvailable: snapshot.ethernetAvailable || actual == .ethernet,
                wifiAvailable: snapshot.wifiAvailable || actual == .wifi)
        }
        callbackQueue.async { [weak self] in self?.status.networkType = snapshot.activeType }
        sendControl(.clientCapabilities(profile.capabilities(network: snapshot)))
    }

    // MARK: - Video connection

    /// Opens the second connection and binds it to the session with the token
    /// the Host handed out in its `hello`.
    ///
    /// Connects to the address the control connection actually resolved to,
    /// not the Bonjour service endpoint: same interface, no second resolution,
    /// and no chance of landing on a different one of the Host's addresses.
    private func openVideoTransport(token: String) {
        videoTransport?.stop()
        guard let endpoint = transport?.remoteEndpoint ?? target else { return }

        // Same concrete address and the same pin as the control connection,
        // so both carriers share one link.
        let channel = NWMessageChannel(endpoint: endpoint, queue: queue,
                                       requiredInterfaceType: plan[planIndex].interfaceType)
        channel.onFrame = { [weak self] frame in self?.handle(frame) }
        channel.onStateChange = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.log.info("Video connection ready; attaching to session")
                do {
                    try channel.sendControl(.attachVideo(.init(sessionToken: token)))
                } catch {
                    self.log.failure("Encoding attachVideo", error)
                }
                self.callbackQueue.async { self.status.videoOnSeparateConnection = true }
            case .failed(let reason):
                self.log.error("Video connection failed: \(reason)")
                self.closeVideoTransport()
                self.scheduleVideoReattach()
            case .cancelled:
                self.log.notice("Video connection closed")
                self.closeVideoTransport()
                self.scheduleVideoReattach()
            case .waiting(let reason):
                self.log.notice("Video connection waiting (\(reason))")
            case .setup, .preparing:
                break
            }
        }
        channel.onError = { [weak self] error in
            self?.log.failure("Video transport", error)
        }
        videoTransport = channel
        channel.start()
    }

    /// Losing the video carrier is not losing the session: the Host falls
    /// back to sending video on the control connection the moment it notices,
    /// so nothing is lost but the split. Try to get the split back a few
    /// times, then live without it. Tearing the whole session down here was
    /// what turned a five-second stall on an idle carrier into a visible
    /// disconnect and reconnect.
    private func scheduleVideoReattach() {
        guard !userInitiatedDisconnect, transport != nil, let token = sessionToken else { return }
        guard videoReattachAttempts < 3 else {
            log.notice("Video carrier not re-attached after \(videoReattachAttempts) attempts; staying on the control connection")
            return
        }
        videoReattachAttempts += 1
        let attempt = videoReattachAttempts
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1.0)
        timer.setEventHandler { [weak self] in
            guard let self = self, self.transport != nil, self.videoTransport == nil else { return }
            self.log.info("Re-attaching video carrier (attempt \(attempt))")
            self.openVideoTransport(token: token)
        }
        videoReattachTimer?.cancel()
        videoReattachTimer = timer
        timer.resume()
    }

    private func closeVideoTransport() {
        videoReattachTimer?.cancel()
        videoReattachTimer = nil
        guard let channel = videoTransport else { return }
        videoTransport = nil
        channel.onStateChange = nil
        channel.onFrame = nil
        channel.stop()
        callbackQueue.async { [weak self] in self?.status.videoOnSeparateConnection = false }
    }

    // MARK: - Reconnection

    private func beginReconnect(reason: String) {
        guard !userInitiatedDisconnect, !plan.isEmpty else { return }

        // Drop the dead connection now: left alive it keeps firing `waiting`
        // callbacks, which would re-enter this method on every one of them.
        teardownTransport()
        advance(.transportFailed(reason: reason))

        // Start the clock on the first failure only, so the grace period covers
        // the whole outage rather than restarting with every retry.
        if reconnectDeadline == nil {
            reconnectDeadline = Date().addingTimeInterval(reconnectGracePeriod)
            log.info("Entering reconnect grace period of \(Int(reconnectGracePeriod))s")
        }

        guard let deadline = reconnectDeadline, Date() < deadline else {
            log.error("Reconnect grace period expired; giving up")
            advance(.gracePeriodExpired)
            teardown()
            clearSessionState()
            return
        }

        // Backoff capped at 2s: on a LAN the peer usually returns quickly and a
        // long backoff would just add dead time.
        let attempt = stateMachine.reconnectAttempts
        let delay = min(pow(1.5, Double(attempt - 1)) * 0.25, 2.0)
        log.info("Reconnect attempt \(attempt) in \(String(format: "%.2f", delay))s")

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in self?.openTransport() }
        reconnectTimer?.cancel()
        reconnectTimer = timer
        timer.resume()
    }

    /// While this Mac is being used as a display, neither it nor this
    /// process may doze off: App Nap would delay the heartbeat past its
    /// timeout, and idle display sleep would blank the very screen being
    /// streamed to.
    private func beginActivity() {
        guard activity == nil else { return }
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical, .idleDisplaySleepDisabled, .idleSystemSleepDisabled],
            reason: "Showing a remote display")
    }

    private func endActivity() {
        guard let activity = activity else { return }
        ProcessInfo.processInfo.endActivity(activity)
        self.activity = nil
    }

    private func teardownTransport() {
        connectWatchdog?.cancel()
        connectWatchdog = nil
        endActivity()
        sessionToken = nil
        // The next connection restarts the encoder, so the old parameter sets
        // no longer describe the incoming bitstream.
        assembler.reset()
        queueing.reset()
        heartbeat?.stop()
        heartbeat = nil
        closeVideoTransport()
        transport?.onStateChange = nil
        transport?.onFrame = nil
        transport?.stop()
        transport = nil
    }

    private func teardown() {
        reconnectTimer?.cancel()
        reconnectTimer = nil
        reconnectDeadline = nil
        teardownTransport()
    }

    // MARK: - Messages

    private func handle(_ frame: OMDFrame) {
        if frame.channel == .video {
            handleVideo(frame)
            return
        }
        guard frame.channel == .control else { return }

        let message: ControlMessage
        do {
            message = try ControlCodec.decode(frame.payload)
        } catch {
            log.failure("Decoding control message", error)
            return
        }

        if heartbeat?.handle(message) == true { return }

        switch message {
        case .hello(let hello):
            log.info("Host is \(hello.device.name) (\(hello.device.model), macOS \(hello.device.osVersion))")
            callbackQueue.async { [weak self] in
                self?.status.hostDevice = hello.device
                self?.status.hostName = hello.device.name
            }
            sessionToken = hello.sessionToken
            videoReattachAttempts = 0
            if let token = hello.sessionToken {
                openVideoTransport(token: token)
            }

        case .serverCapabilities(let capabilities):
            log.info("Host codecs: \(capabilities.supportedCodecs.map { $0.rawValue }.joined(separator: ", "))")
            callbackQueue.async { [weak self] in self?.status.serverCapabilities = capabilities }
            // Capabilities exchanged in both directions: handshake is done.
            advance(.handshakeCompleted)

        case .videoConfiguration(let configuration):
            log.info("Incoming stream: \(configuration.codec.rawValue) \(configuration.encodedWidth)x\(configuration.encodedHeight) @\(configuration.frameRate)")
            assembler.configure(codec: configuration.codec)
            callbackQueue.async { [weak self] in self?.status.video = configuration }

        case .streamStart:
            log.info("Stream started")
            resetVideoStats()
            beginActivity()
            callbackQueue.async { [weak self] in self?.status.streaming = true }

        case .streamStop:
            log.info("Stream stopped")
            assembler.reset()
            endActivity()
            callbackQueue.async { [weak self] in
                self?.status.streaming = false
                self?.status.measuredFPS = 0
            }

        case .displayConfiguration(let config):
            log.info("Host negotiated \(config.mode) \(config.codec.rawValue)")
            callbackQueue.async { [weak self] in self?.status.negotiated = config }

        case .cursor(let update):
            callbackQueue.async { [weak self] in self?.onCursor?(update) }

        case .disconnect(let payload):
            log.info("Host disconnected: \(payload.reason)")
            userInitiatedDisconnect = true
            advance(.disconnectRequested(reason: payload.reason))
            teardown()
            clearSessionState()

        case .error(let payload):
            log.error("Host error \(payload.code): \(payload.message)")
            setLastError(payload.message)
            if payload.code == "E_BUSY" || payload.code == "E_VERSION" {
                // Not transient: retrying would just be rejected again.
                userInitiatedDisconnect = true
                advance(.disconnectRequested(reason: payload.message))
                teardown()
                clearSessionState()
            }

        default:
            log.debug("Ignoring \(message.kind.rawValue)")
        }
    }

    // MARK: - Video

    private func handleVideo(_ frame: OMDFrame) {
        let arrival = MonotonicClock.now()
        let packet: VideoPacket
        do {
            packet = try VideoPacket.decode(frame.payload)
        } catch {
            log.failure("Decoding video packet", error)
            return
        }

        switch packet.kind {
        case .parameterSets:
            do {
                let sets = try ParameterSets.decode(packet.payload)
                try assembler.setParameterSets(
                    sets, nalUnitHeaderLength: Int(packet.nalUnitHeaderLength))
            } catch {
                log.failure("Applying parameter sets", error)
            }

        case .accessUnit:
            guard assembler.isReady else {
                // Joined mid-GOP. Ask for an IDR; parameter sets ride along
                // with it.
                requestKeyframeThrottled()
                return
            }
            do {
                let sampleBuffer = try assembler.makeSampleBuffer(from: packet)
                recordVideoStats(packet: packet, arrival: arrival)
                videoSink?(sampleBuffer)
            } catch {
                log.failure("Building sample buffer", error)
                requestKeyframeThrottled()
            }
        }
    }

    /// At most one keyframe request per second: the Host cannot answer faster,
    /// and a flood would waste the control channel during a bad patch.
    private func requestKeyframeThrottled() {
        let now = MonotonicClock.now()
        guard now - lastKeyframeRequest > 1.0 else { return }
        lastKeyframeRequest = now
        log.info("Requesting a keyframe")
        sendControl(.requestKeyframe)
    }

    private func recordVideoStats(packet: VideoPacket, arrival: Double) {
        videoWindowFrames += 1
        videoWindowBytes += packet.payload.count

        let pts = Double(packet.presentationTimeMicros) / 1_000_000
        queueing.record(presentationTime: pts, arrival: arrival)
        // The capture timestamp is on the Host's clock; the heartbeat has
        // been estimating how far off ours it is.
        if let localCapture = heartbeat?.clockOffset.localTime(forPeerTime: pts) {
            endToEndSum += arrival - localCapture
            endToEndCount += 1
        }

        let now = arrival
        let elapsed = now - videoWindowStart
        guard elapsed >= 1.0 else { return }

        let fps = Double(videoWindowFrames) / elapsed
        let bitrate = Int(Double(videoWindowBytes * 8) / elapsed)
        let queueingReport = queueing.report()
        let endToEnd: Double? = endToEndCount > 0
            ? endToEndSum / Double(endToEndCount) * 1000 : nil

        callbackQueue.async { [weak self] in
            self?.status.measuredFPS = fps
            self?.status.measuredBitrateBPS = bitrate
            self?.status.endToEndMilliseconds = endToEnd
        }
        reportStatsToHost(fps: fps, bitrate: bitrate,
                          queueingMillis: queueingReport?.maxMillis,
                          endToEndMillis: endToEnd)

        videoWindowStart = now
        videoWindowFrames = 0
        videoWindowBytes = 0
        endToEndSum = 0
        endToEndCount = 0
    }

    /// Tells the Host how the stream is actually arriving here.
    ///
    /// This is the only truthful backpressure signal in the system. The Host
    /// cannot infer congestion from its own sends: `NWConnection` reports a
    /// frame as processed once the kernel accepts it into the socket buffer,
    /// which happens immediately even when the link is stalled. Only the
    /// Receiver knows how many frames actually made it to the screen and how
    /// late they were.
    private func reportStatsToHost(fps: Double, bitrate: Int,
                                   queueingMillis: Double?, endToEndMillis: Double?) {
        let display = displayStatsProvider?() ?? (displayed: 0, dropped: 0)
        let total = display.displayed + display.dropped
        let dropRatio = total > 0 ? Double(display.dropped) / Double(total) : 0

        sendControl(.networkStats(.init(
            fps: fps,
            bitrateBPS: bitrate,
            droppedFrameRatio: dropRatio,
            decodeMillis: 0,   // not separable with AVSampleBufferDisplayLayer
            renderMillis: 0,
            queueingDelayMillis: queueingMillis,
            endToEndMillis: endToEndMillis)))
    }

    private func resetVideoStats() {
        videoWindowStart = MonotonicClock.now()
        videoWindowFrames = 0
        videoWindowBytes = 0
        queueing.reset()
        endToEndSum = 0
        endToEndCount = 0
    }

    private func sendControl(_ message: ControlMessage) {
        guard let transport = transport else { return }
        do {
            try transport.sendControl(message)
        } catch {
            log.failure("Encoding \(message.kind.rawValue)", error)
        }
    }

    private func advance(_ event: ConnectionEvent) {
        guard stateMachine.handle(event) else { return }
        let state = stateMachine.state
        callbackQueue.async { [weak self] in self?.status.state = state }
    }
}
