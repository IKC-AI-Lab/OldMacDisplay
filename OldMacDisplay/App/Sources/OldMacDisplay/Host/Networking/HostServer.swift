import Foundation
import Network
import CoreGraphics
import OldMacDisplayShared

/// Ties Bonjour advertising to session management.
///
/// Accepts a single Receiver at a time. Every inbound connection is read up to
/// its first control frame before being classified: a `hello` opens a session
/// (or is rejected with an explicit error when one exists), an `attachVideo`
/// with the live session's token becomes that session's video carrier, and
/// anything else is dropped.
final class HostServer {
    struct Status: Equatable {
        var advertising = false
        var port: UInt16 = OMDProtocol.defaultPort
        var connectionState: ConnectionState = .idle
        var peer: HostSession.Peer?
        var negotiated: SessionConfiguration?
        var latencyMilliseconds: Double?
        var lastError: String?
        var streaming = false
        var measuredFPS: Double = 0
        var measuredBitrateBPS: Int = 0
        var encodeMillis: Double = 0
        /// What the adaptive controller currently asks of the encoder. Equals
        /// the negotiated target until the link proves it cannot carry it.
        var currentBitrateBPS: Int?
        /// Frames dropped on the send side because the network stalled.
        var networkDroppedFrames = 0
        /// What the Receiver reports it is actually displaying. This, not the
        /// host-side figure, is what the user is looking at.
        var receiverFPS: Double?
        var receiverDropRatio: Double?
        var receiverQueueingMillis: Double?
        var receiverEndToEndMillis: Double?
        /// Set once macOS is actually extending onto our virtual display.
        var virtualDisplayID: CGDirectDisplayID?
    }

    var onStatusChange: ((Status) -> Void)?

    /// Only ever read or written on `callbackQueue`.
    private(set) var status = Status() {
        didSet {
            guard status != oldValue else { return }
            let snapshot = status
            callbackQueue.async { [weak self] in self?.onStatusChange?(snapshot) }
        }
    }

    let systemInfo: HostSystemInfo

    private let queue = DispatchQueue(label: "com.oldmacdisplay.host.network")
    private let callbackQueue: DispatchQueue
    private let advertiser: BonjourAdvertiser
    private var session: HostSession?
    private var streamController: AnyObject?
    private var cursorTracker: CursorTracker?
    private var bitrateController: BitrateController?
    private var lastNetworkDroppedFrames = 0
    /// Held while streaming. Without it, App Nap kicks in as soon as this
    /// window is hidden behind the ones being worked in (which is exactly
    /// how a Host is used) and delays the heartbeat timers by seconds, which
    /// the Receiver reads as the Host having gone away.
    private var activity: NSObjectProtocol?
    private let virtualDisplayProvider: VirtualDisplayProvider = CGVirtualDisplayProvider()
    private var preferences: HostPreferences
    private let log = Log(.network)

    /// Connections still waiting for their first frame. On `queue`.
    private var pending: [ObjectIdentifier: PendingConnection] = [:]

    init(systemInfo: HostSystemInfo = .current(),
         preferences: HostPreferences = .default,
         callbackQueue: DispatchQueue = .main) {
        self.systemInfo = systemInfo
        self.preferences = preferences
        self.callbackQueue = callbackQueue
        self.advertiser = BonjourAdvertiser(queue: queue)
    }

    func start() {
        advertiser.onStateChange = { [weak self] state in
            guard let self else { return }
            self.callbackQueue.async {
                switch state {
                case .advertising(let port):
                    self.status.advertising = true
                    self.status.port = port
                    self.status.lastError = nil
                case .stopped:
                    self.status.advertising = false
                case .failed(let reason):
                    self.status.advertising = false
                    self.status.lastError = reason
                }
            }
        }
        advertiser.onNewConnection = { [weak self] connection in
            self?.classify(connection)
        }
        advertiser.start(device: systemInfo.device)
    }

    func stop() {
        stopStreaming()
        session?.disconnect(reason: "Host stopped")
        session = nil
        advertiser.stop()
        callbackQueue.async { [weak self] in
            self?.status.advertising = false
            self?.status.connectionState = .idle
        }
    }

    func disconnectCurrentSession() {
        session?.disconnect(reason: "Disconnected by host")
    }

    func updatePreferences(_ preferences: HostPreferences) {
        self.preferences = preferences
        session?.updatePreferences(preferences)
    }

    // MARK: - Inbound connections

    /// A started channel whose first frame decides what it is for.
    private final class PendingConnection {
        let channel: NWMessageChannel
        let endpoint: String
        var timeout: DispatchSourceTimer?
        init(channel: NWMessageChannel, endpoint: String) {
            self.channel = channel
            self.endpoint = endpoint
        }
    }

    /// How long a fresh connection may stay silent before it is dropped.
    private static let firstFrameTimeout: TimeInterval = 5

    private func classify(_ connection: NWConnection) {
        let channel = NWMessageChannel(connection: connection, queue: queue)
        let pendingConnection = PendingConnection(channel: channel,
                                                  endpoint: HostSession.describe(connection.endpoint))
        let key = ObjectIdentifier(channel)
        pending[key] = pendingConnection

        channel.onFrame = { [weak self] frame in
            guard let self, let pendingConnection = self.pending.removeValue(forKey: key) else { return }
            pendingConnection.timeout?.cancel()
            self.route(frame, from: pendingConnection)
        }
        channel.onStateChange = { [weak self] state in
            guard let self else { return }
            switch state {
            case .failed, .cancelled:
                if let dropped = self.pending.removeValue(forKey: key) {
                    dropped.timeout?.cancel()
                    self.log.notice("Connection from \(dropped.endpoint) ended before its first frame")
                }
            default:
                break
            }
        }

        let timeout = DispatchSource.makeTimerSource(queue: queue)
        timeout.schedule(deadline: .now() + HostServer.firstFrameTimeout)
        timeout.setEventHandler { [weak self] in
            guard let self, let dropped = self.pending.removeValue(forKey: key) else { return }
            self.log.notice("Connection from \(dropped.endpoint) sent nothing for \(Int(HostServer.firstFrameTimeout))s; closing")
            dropped.channel.stop()
        }
        pendingConnection.timeout = timeout
        timeout.resume()

        channel.start()
    }

    /// On `queue`.
    private func route(_ frame: OMDFrame, from pendingConnection: PendingConnection) {
        let channel = pendingConnection.channel
        let message = frame.channel == .control ? try? ControlCodec.decode(frame.payload) : nil

        switch message {
        case .attachVideo(let attach):
            guard let session = session, session.sessionToken == attach.sessionToken else {
                log.notice("Rejecting video attach from \(pendingConnection.endpoint): no matching session")
                reject(channel, code: "E_SESSION", reason: "No session with that token")
                return
            }
            log.info("Attaching video connection from \(pendingConnection.endpoint)")
            session.attachVideoTransport(channel)

        case .hello:
            guard session == nil else {
                log.notice("Rejecting second Receiver from \(pendingConnection.endpoint); one session at a time")
                reject(channel, code: "E_BUSY", reason: "Host is already connected to another display")
                return
            }
            // Synchronously, on this queue: the Receiver sends `hello` and
            // `clientCapabilities` back to back, and the session must own
            // `onFrame` before the second one is delivered or it is lost.
            openSession(on: channel, endpoint: pendingConnection.endpoint, firstFrame: frame)

        default:
            log.notice("Unexpected first frame from \(pendingConnection.endpoint); closing")
            channel.stop()
        }
    }

    /// On `queue`. The session's callbacks run on `callbackQueue` and mutate
    /// `status` there.
    private func openSession(on channel: NWMessageChannel, endpoint: String, firstFrame: OMDFrame) {
        let session = HostSession(transport: channel,
                                  endpoint: endpoint,
                                  systemInfo: systemInfo,
                                  preferences: preferences,
                                  queue: queue,
                                  callbackQueue: callbackQueue)
        self.session = session

        session.onStateChange = { [weak self] state in
            self?.status.connectionState = state
        }
        session.onPeerChange = { [weak self] peer in
            self?.status.peer = peer
        }
        session.onNegotiated = { [weak self] config in
            guard let self else { return }
            self.status.negotiated = config
            self.startStreaming(config, on: session)
        }
        session.onReceiverStats = { [weak self] stats in
            self?.handleReceiverStats(stats)
        }
        session.onDroppedFrame = { [weak self] total in
            self?.status.networkDroppedFrames = total
        }
        session.onKeyframeRequested = { [weak self] in
            guard #available(macOS 13.0, *),
                  let controller = self?.streamController as? StreamController else { return }
            controller.requestKeyframe()
        }
        session.onLatency = { [weak self] tracker in
            self?.status.latencyMilliseconds = tracker.smoothedMilliseconds
        }
        session.onEnded = { [weak self] ended in
            guard let self, self.session === ended else { return }
            self.stopStreaming()
            self.session = nil
            self.status.peer = nil
            self.status.negotiated = nil
            self.status.latencyMilliseconds = nil
        }

        session.start(preconnectedWith: firstFrame)
    }

    // MARK: - Streaming

    private func startStreaming(_ configuration: SessionConfiguration, on session: HostSession) {
        guard #available(macOS 13.0, *) else {
            let message = "Screen capture requires macOS 13 or later on the host."
            log.error(message)
            status.lastError = message
            return
        }

        // Create the extra desktop first, then capture only that. Without it
        // we would be mirroring the main display, which is not the point.
        //
        // Off the main thread: macOS registers the display through the main run
        // loop, so waiting for it there would deadlock.
        virtualDisplayProvider.createDisplay(
            configuration: VirtualDisplayConfiguration(mode: configuration.mode)
        ) { [weak self, weak session] result in
            guard let self = self, let session = session else { return }
            switch result {
            case .failure(let error):
                self.log.failure("Creating virtual display", error)
                self.status.lastError = error.localizedDescription

            case .success(let display):
                self.status.virtualDisplayID = display.displayID

                // macOS may have restored a remembered mode, so stream what is
                // actually on screen rather than what we asked for.
                let actual = SessionConfiguration(
                    mode: DisplayMode(width: display.width,
                                      height: display.height,
                                      refreshRate: configuration.mode.refreshRate),
                    codec: configuration.codec,
                    targetBitrateBPS: configuration.targetBitrateBPS)

                self.beginCapture(actual, displayID: display.displayID, on: session)
            }
        }
    }

    private func beginCapture(_ configuration: SessionConfiguration,
                              displayID: CGDirectDisplayID,
                              on session: HostSession) {
        guard #available(macOS 13.0, *) else { return }

        let controller = (streamController as? StreamController) ?? StreamController()
        streamController = controller

        controller.onConfiguration = { [weak session] videoConfiguration in
            session?.startVideoStream(videoConfiguration)
        }
        controller.onPacket = { [weak session] packet in
            session?.sendVideo(packet)
        }
        controller.onError = { [weak self] message in
            self?.callbackQueue.async {
                self?.status.lastError = message
                self?.status.streaming = false
            }
        }
        controller.onStats = { [weak self] stats in
            self?.callbackQueue.async {
                self?.status.streaming = true
                // Frames are flowing, so whatever went wrong before (a
                // capture that stopped when the previous virtual display was
                // torn down, say) is over.
                self?.status.lastError = nil
                self?.status.measuredFPS = stats.measuredFPS
                self?.status.measuredBitrateBPS = stats.measuredBitrateBPS
                self?.status.encodeMillis = stats.averageEncodeMillis
            }
        }

        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical, .idleSystemSleepDisabled],
                reason: "Streaming a display")
        }

        // Every (re)start of the pipeline resets the adaptive loop to the
        // negotiated opening bid.
        bitrateController = BitrateController(targetBPS: configuration.targetBitrateBPS)
        lastNetworkDroppedFrames = 0
        status.currentBitrateBPS = configuration.targetBitrateBPS

        controller.start(configuration: configuration, displayID: displayID)

        cursorTracker?.stop()
        let tracker = CursorTracker(displayID: displayID, queue: queue)
        tracker.onUpdate = { [weak session] update in session?.sendCursor(update) }
        tracker.start(frameRate: configuration.mode.refreshRate)
        cursorTracker = tracker
    }

    /// The once-a-second report from the Receiver drives the bitrate.
    private func handleReceiverStats(_ stats: ControlMessage.NetworkStats) {
        status.receiverFPS = stats.fps
        status.receiverDropRatio = stats.droppedFrameRatio
        status.receiverQueueingMillis = stats.queueingDelayMillis
        status.receiverEndToEndMillis = stats.endToEndMillis

        guard var controller = bitrateController else { return }
        let hostDropped = status.networkDroppedFrames - lastNetworkDroppedFrames
        lastNetworkDroppedFrames = status.networkDroppedFrames

        let input = BitrateController.Input(
            receiverDropRatio: stats.droppedFrameRatio,
            queueingDelayMillis: stats.queueingDelayMillis,
            hostDroppedFrames: max(0, hostDropped),
            rttMillis: status.latencyMilliseconds)

        if let bitrate = controller.update(input, now: MonotonicClock.now()) {
            log.info("Adaptive bitrate: \(bitrate / 100_000 / 10).\(bitrate / 100_000 % 10) Mbps (drop \(Int(stats.droppedFrameRatio * 100))%, queueing \(Int(stats.queueingDelayMillis ?? 0)) ms, host dropped \(hostDropped))")
            status.currentBitrateBPS = bitrate
            if #available(macOS 13.0, *), let stream = streamController as? StreamController {
                stream.updateBitrate(bitrate)
            }
        }
        bitrateController = controller
    }

    private func stopStreaming() {
        if let activity = activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
        cursorTracker?.stop()
        cursorTracker = nil
        if #available(macOS 13.0, *), let controller = streamController as? StreamController {
            // Tearing the virtual display down stops the capture on it with
            // "failed to find any displays to capture"; that is expected here,
            // not something to show the user.
            controller.onError = nil
            controller.onStats = nil
            controller.stop()
        }
        streamController = nil
        bitrateController = nil
        virtualDisplayProvider.destroyDisplay()
        status.virtualDisplayID = nil
        status.streaming = false
        status.measuredFPS = 0
        status.measuredBitrateBPS = 0
        status.encodeMillis = 0
        status.currentBitrateBPS = nil
        status.networkDroppedFrames = 0
        status.receiverFPS = nil
        status.receiverDropRatio = nil
        status.receiverQueueingMillis = nil
        status.receiverEndToEndMillis = nil
    }

    /// Sends a protocol-level explanation before hanging up, so the Receiver can
    /// show a real reason instead of "connection closed". On `queue`.
    private func reject(_ channel: NWMessageChannel, code: String, reason: String) {
        channel.onFrame = nil
        channel.onStateChange = nil
        try? channel.sendControl(.error(.init(code: code, message: reason))) { _ in
            channel.stop()
        }
    }
}
