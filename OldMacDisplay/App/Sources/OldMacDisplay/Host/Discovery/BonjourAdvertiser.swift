import Foundation
import Network
import OldMacDisplayShared

/// Publishes `_oldmacdisplay._tcp` on the LAN and accepts inbound connections.
///
/// Network.framework couples advertising and listening in a single `NWListener`,
/// so this type owns both; everything Bonjour-specific (service naming, TXT
/// record contents) stays here rather than leaking into the session layer.
final class BonjourAdvertiser {
    enum State: Equatable {
        case stopped
        case advertising(port: UInt16)
        case failed(String)
    }

    var onStateChange: ((State) -> Void)?
    var onNewConnection: ((NWConnection) -> Void)?

    private let queue: DispatchQueue
    private let log = Log(.discovery)
    private var listener: NWListener?
    private var device: DeviceInfo?
    private var port: UInt16 = OMDProtocol.defaultPort
    private var advertisedAddresses = LocalAddresses.Snapshot()
    /// Re-reads the addresses whenever a link comes or goes. They were only
    /// read at launch, so an adapter or cable plugged in afterwards was never
    /// published and the Receiver could not find this Mac over it.
    private var pathMonitor: NWPathMonitor?
    private var refreshWork: DispatchWorkItem?

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    /// Restarts after a failure. Set on `queue`.
    private var restartTimer: DispatchSourceTimer?
    private var consecutiveFailures = 0
    private var running = false

    /// After this many failed restarts in a row the UI is told; before that
    /// a hiccup is fixed without the user ever seeing it.
    private static let failuresBeforeReporting = 3

    func start(device: DeviceInfo, port: UInt16 = OMDProtocol.defaultPort) {
        queue.async { [weak self] in
            guard let self else { return }
            self.stopOnQueue()
            self.device = device
            self.port = port
            self.running = true
            self.consecutiveFailures = 0
            self.startListener()
            self.startWatchingLinks()
        }
    }

    func stop() {
        queue.async { [weak self] in self?.stopOnQueue() }
    }

    /// On `queue`.
    private func stopOnQueue() {
        running = false
        restartTimer?.cancel()
        restartTimer = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        refreshWork?.cancel()
        refreshWork = nil
        cancelListener()
    }

    private func cancelListener() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
    }

    /// On `queue`. Opens the listening socket and registers the Bonjour
    /// service. Live sessions do not go through the listener, so restarting
    /// it never interrupts a stream.
    private func startListener() {
        guard running, let device = device else { return }
        cancelListener()
        do {
            let parameters = NWMessageChannel.parameters()
            // Without this a restart within the TIME_WAIT window fails to bind.
            parameters.allowLocalEndpointReuse = true

            let listener = try NWListener(
                using: parameters,
                on: NWEndpoint.Port(rawValue: port) ?? .any)

            let addresses = LocalAddresses.current()
            log.info("Advertising addresses: \(BonjourAdvertiser.describe(addresses))")
            advertisedAddresses = addresses
            listener.service = BonjourAdvertiser.service(for: device, port: port, addresses: addresses)

            listener.stateUpdateHandler = { [weak self, weak listener] state in
                guard let self, let listener, listener === self.listener else { return }
                switch state {
                case .ready:
                    self.consecutiveFailures = 0
                    let actualPort = listener.port?.rawValue ?? self.port
                    self.log.info("Advertising \(OMDProtocol.bonjourServiceType) as '\(device.name)' on port \(actualPort)")
                    self.onStateChange?(.advertising(port: actualPort))
                case .failed(let error):
                    // Typically DNS-SD -65563 "ServiceNotRunning": macOS
                    // restarted mDNSResponder (network change, wake from
                    // sleep) and every registration made through it died.
                    // The listener never recovers on its own; a new one does.
                    self.log.failure("Listener failed", error)
                    self.listenerFailed(error.localizedDescription)
                case .waiting(let error):
                    self.log.notice("Listener waiting: \(error)")
                case .cancelled:
                    self.onStateChange?(.stopped)
                default:
                    break
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.log.info("Inbound connection from \(connection.endpoint)")
                self?.onNewConnection?(connection)
            }

            self.listener = listener
            listener.start(queue: queue)
        } catch {
            log.failure("Creating listener on port \(port)", error)
            listenerFailed(error.localizedDescription)
        }
    }

    /// On `queue`.
    private func listenerFailed(_ reason: String) {
        cancelListener()
        guard running else { return }
        consecutiveFailures += 1
        if consecutiveFailures >= BonjourAdvertiser.failuresBeforeReporting {
            onStateChange?(.failed("\(reason) Retrying…"))
        }
        // 1, 2, 4, 8, 16, then every 30 s, for as long as the Host runs.
        let delay = min(pow(2.0, Double(consecutiveFailures - 1)), 30)
        log.notice("Restarting the listener in \(Int(delay)) s (failure \(consecutiveFailures))")
        restartTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + delay)
        timer.setEventHandler { [weak self] in
            self?.restartTimer = nil
            self?.startListener()
        }
        restartTimer = timer
        timer.resume()
    }

    private static func service(for device: DeviceInfo, port: UInt16,
                                addresses: LocalAddresses.Snapshot) -> NWListener.Service {
        NWListener.Service(name: device.name,
                           type: OMDProtocol.bonjourServiceType,
                           domain: nil,
                           txtRecord: txtRecordData(for: device, port: port, addresses: addresses))
    }

    static func describe(_ addresses: LocalAddresses.Snapshot) -> String {
        "eth=\(addresses.ethernet ?? "-") wifi=\(addresses.wifi ?? "-") tb=\(addresses.bridge ?? "-")"
    }

    private func startWatchingLinks() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in self?.scheduleAddressRefresh() }
        monitor.start(queue: queue)
        pathMonitor = monitor
    }

    /// On `queue`. A new link gets its address a moment after it comes up
    /// (a self-assigned 169.254 one takes a few seconds), so look twice.
    private func scheduleAddressRefresh() {
        refreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.refreshAddresses()
            self?.queue.asyncAfter(deadline: .now() + 5) { self?.refreshAddresses() }
        }
        refreshWork = work
        queue.asyncAfter(deadline: .now() + 1, execute: work)
    }

    private func refreshAddresses() {
        guard let listener = listener, listener.state == .ready, let device = device else { return }
        let addresses = LocalAddresses.current()
        guard addresses != advertisedAddresses else { return }
        advertisedAddresses = addresses
        log.info("Links changed; advertising addresses: \(BonjourAdvertiser.describe(addresses))")
        listener.service = BonjourAdvertiser.service(for: device, port: port, addresses: addresses)
    }

    /// TXT record lets the Receiver render a useful list row ("Mac14,6",
    /// "macOS 26.5.1") before any TCP connection is made.
    ///
    /// Encoded by hand rather than with `NWTXTRecord.data`, which is macOS 13+.
    /// The DNS-SD format is simply a sequence of length-prefixed "key=value"
    /// strings, one byte of length each, so this works on Catalina too.
    static func txtRecordData(for device: DeviceInfo,
                              port: UInt16 = OMDProtocol.defaultPort,
                              addresses: LocalAddresses.Snapshot = .init()) -> Data {
        var entries = [
            (OMDProtocol.TXTKey.protocolVersion, String(OMDProtocol.version)),
            (OMDProtocol.TXTKey.deviceName, device.name),
            (OMDProtocol.TXTKey.deviceModel, device.model),
            (OMDProtocol.TXTKey.osVersion, device.osVersion),
            (OMDProtocol.TXTKey.port, String(port))
        ]
        if let eth = addresses.ethernet { entries.append((OMDProtocol.TXTKey.ethernetAddress, eth)) }
        if let wifi = addresses.wifi { entries.append((OMDProtocol.TXTKey.wifiAddress, wifi)) }
        if let bridge = addresses.bridge { entries.append((OMDProtocol.TXTKey.bridgeAddress, bridge)) }

        var data = Data()
        for (key, value) in entries {
            let pair = Array("\(key)=\(value)".utf8)
            // A single entry cannot exceed 255 bytes; drop rather than corrupt
            // the record if a machine somehow has a very long name.
            guard pair.count <= 255 else { continue }
            data.append(UInt8(pair.count))
            data.append(contentsOf: pair)
        }
        return data
    }
}
