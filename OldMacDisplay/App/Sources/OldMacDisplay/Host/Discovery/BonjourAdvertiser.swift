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

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func start(device: DeviceInfo, port: UInt16 = OMDProtocol.defaultPort) {
        stop()
        do {
            let parameters = NWMessageChannel.parameters()
            // Without this a restart within the TIME_WAIT window fails to bind.
            parameters.allowLocalEndpointReuse = true

            let listener = try NWListener(
                using: parameters,
                on: NWEndpoint.Port(rawValue: port) ?? .any)

            let addresses = LocalAddresses.current()
            log.info("Advertising addresses: eth=\(addresses.ethernet ?? "-") wifi=\(addresses.wifi ?? "-")")
            listener.service = NWListener.Service(
                name: device.name,
                type: OMDProtocol.bonjourServiceType,
                domain: nil,
                txtRecord: BonjourAdvertiser.txtRecordData(for: device, port: port,
                                                           addresses: addresses))

            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    let actualPort = listener.port?.rawValue ?? port
                    self.log.info("Advertising \(OMDProtocol.bonjourServiceType) as '\(device.name)' on port \(actualPort)")
                    self.onStateChange?(.advertising(port: actualPort))
                case .failed(let error):
                    self.log.failure("Listener failed", error)
                    self.onStateChange?(.failed(error.localizedDescription))
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
            onStateChange?(.failed(error.localizedDescription))
        }
    }

    func stop() {
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
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
