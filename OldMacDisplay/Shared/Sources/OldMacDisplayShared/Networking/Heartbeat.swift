import Foundation

/// Drives the Ping/Pong exchange and maintains RTT statistics.
///
/// Symmetric: both Host and Receiver run one, so each side can display its own
/// measured latency without trusting a number reported by the peer. The clock is
/// injectable so the timing logic is unit-testable without real delays.
public final class Heartbeat {
    /// Called on `queue` whenever a new RTT sample lands.
    public var onSample: ((LatencyTracker) -> Void)?
    /// Called once, on `queue`, when nothing at all has arrived from the peer
    /// for `timeout` seconds. TCP alone does not notice a vanished peer while
    /// data is being sent: retransmission goes on for minutes and keepalive
    /// probes only start on an idle socket. Application-level liveness is
    /// the only thing that ends a session promptly when the other Mac drops
    /// off the network.
    public var onTimeout: (() -> Void)?

    public private(set) var tracker = LatencyTracker()
    /// Peer clock relative to ours, refined with every pong that carries a
    /// `receivedAt`. Lets the Receiver turn Host capture timestamps into local
    /// time for a true capture-to-display latency figure.
    public private(set) var clockOffset = ClockOffsetEstimator()

    private let interval: Double
    private let timeout: Double
    private var lastInboundAt: Double?
    private var timedOut = false
    private let queue: DispatchQueue
    private let now: () -> Double
    private let send: (ControlMessage) -> Void
    private var timer: DispatchSourceTimer?
    private var sequence: UInt32 = 0
    private let log = Log(.network)

    public init(interval: Double = 1.0,
                timeout: Double = 10.0,
                queue: DispatchQueue,
                now: @escaping () -> Double = MonotonicClock.now,
                send: @escaping (ControlMessage) -> Void) {
        self.interval = interval
        self.timeout = timeout
        self.queue = queue
        self.now = now
        self.send = send
    }

    deinit { timer?.cancel() }

    public func start() {
        stop()
        lastInboundAt = now()
        timedOut = false
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(10))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
    }

    public func stop() {
        timer?.cancel()
        timer = nil
    }

    public func reset() {
        tracker.reset()
        clockOffset.reset()
        sequence = 0
    }

    /// One timer tick: check liveness, then ping. Exposed for tests.
    public func tick() {
        // Once the peer is declared gone, stop pinging into the void; the
        // owner is tearing the session down.
        guard !timedOut else { return }
        if let last = lastInboundAt, now() - last > timeout {
            timedOut = true
            log.error("Nothing heard from the peer for \(Int(now() - last)) s")
            onTimeout?()
            return
        }
        sendPing()
    }

    /// Emits one ping immediately. Exposed for tests and for a manual "measure
    /// now" action in the diagnostics overlay.
    public func sendPing() {
        sequence &+= 1
        send(.ping(ControlMessage.Ping(sequence: sequence, sentAt: now())))
    }

    /// Feed every inbound control message here; returns true if it was consumed.
    @discardableResult
    public func handle(_ message: ControlMessage) -> Bool {
        // Any inbound message proves the peer is alive, not just pongs.
        lastInboundAt = now()
        switch message {
        case .ping(let ping):
            // Reply immediately and on this queue: any delay here is
            // indistinguishable from network latency to the peer.
            send(.pong(ControlMessage.Pong(echoing: ping, receivedAt: now())))
            return true

        case .pong(let pong):
            let returnedAt = now()
            let rtt = returnedAt - pong.sentAt
            guard rtt >= 0 else {
                log.error("Discarding pong \(pong.sequence) with a negative RTT")
                return true
            }
            tracker.record(rtt: rtt)
            if let peerReceivedAt = pong.receivedAt {
                clockOffset.record(sentAt: pong.sentAt, peerReceivedAt: peerReceivedAt,
                                   returnedAt: returnedAt)
            }
            log.debug(String(format: "RTT seq %u: %.2f ms (smoothed %.2f ms)",
                             pong.sequence, rtt * 1000, tracker.smoothedMilliseconds ?? 0))
            onSample?(tracker)
            return true

        default:
            return false
        }
    }
}
