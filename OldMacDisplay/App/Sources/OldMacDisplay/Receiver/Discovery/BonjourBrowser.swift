import Foundation
import Network
import OldMacDisplayShared

/// A Host discovered on the LAN.
struct DiscoveredHost: Equatable {
    let endpoint: NWEndpoint
    /// Every interface this Host was seen on.
    ///
    /// Bonjour reports one result per service, listing all the interfaces it
    /// arrived over, so a Mac reachable by both cable and Wi-Fi appears once
    /// with two entries here. The list is what the link filter in the Use As
    /// Display pane narrows the visible Hosts by.
    let interfaces: [NWInterface]

    /// Bonjour instance name — the Host's computer name.
    let serviceName: String
    let model: String?
    let osVersion: String?
    let protocolVersion: Int?
    /// The Host's own IPv4 address per link, from its TXT record, plus the
    /// port it listens on. Lets the Receiver connect to the cable's address
    /// directly instead of whichever address the resolver reaches first.
    var addresses: [LinkFilter: String] = [:]
    var port: UInt16 = OMDProtocol.defaultPort

    /// A concrete endpoint on `link`, if the Host published one.
    func directEndpoint(over link: LinkFilter) -> NWEndpoint? {
        guard let address = addresses[link], let nwPort = NWEndpoint.Port(rawValue: port) else {
            return nil
        }
        return .hostPort(host: NWEndpoint.Host(address), port: nwPort)
    }

    /// Whether this Host was advertised over `link`.
    func isReachable(over link: LinkFilter) -> Bool {
        // A manually typed address carries no interface information, so it is
        // shown under every link rather than hidden everywhere.
        interfaces.isEmpty || interfaces.contains { $0.type == link.interfaceType }
    }

    /// True when this Host speaks a protocol version we can actually talk to.
    var isCompatible: Bool {
        guard let version = protocolVersion else {
            // Older Hosts may not publish TXT data; let the handshake decide.
            return true
        }
        return version == Int(OMDProtocol.version)
    }

    /// How this Host was advertised, for the row subtitle.
    ///
    /// Worth showing: a Mac that appears under both links is genuinely visible
    /// over both, while "link unknown" means discovery reported no interface at
    /// all and the row is being shown everywhere rather than hidden.
    var linkSummary: String {
        let names = interfaces.compactMap { interface -> String? in
            switch interface.type {
            case .wiredEthernet: return "Ethernet"
            case .wifi: return "Wi-Fi"
            default: return nil
            }
        }
        guard !names.isEmpty else { return "link unknown" }
        var seen: [String] = []
        for name in names where !seen.contains(name) { seen.append(name) }
        return seen.joined(separator: " + ")
    }

    var subtitle: String {
        var parts: [String] = []
        if let model = model { parts.append(model) }
        if let os = osVersion { parts.append("macOS \(os)") }
        parts.append(linkSummary)
        if !isCompatible, let version = protocolVersion {
            parts.append("protocol v\(version) — incompatible")
        }
        return parts.isEmpty ? "Available" : parts.joined(separator: " · ")
    }
}

extension DiscoveredHost {
    /// Builds a host entry from a typed-in address, for direct Ethernet links
    /// where mDNS may be unavailable. Accepts "192.168.2.2" or "host:port".
    init?(address: String) {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // Split off the port, taking care not to break bare IPv6 literals.
        var hostPart = trimmed
        var port = OMDProtocol.defaultPort
        if let colon = trimmed.lastIndex(of: ":"),
           trimmed.filter({ $0 == ":" }).count == 1 {
            let candidate = String(trimmed[trimmed.index(after: colon)...])
            if let parsed = UInt16(candidate) {
                port = parsed
                hostPart = String(trimmed[trimmed.startIndex..<colon])
            }
        }

        guard let nwPort = NWEndpoint.Port(rawValue: port) else { return nil }
        self.init(endpoint: .hostPort(host: NWEndpoint.Host(hostPart), port: nwPort),
                  interfaces: [],
                  serviceName: hostPart,
                  model: nil,
                  osVersion: nil,
                  protocolVersion: nil)
    }
}

/// Browses for `_oldmacdisplay._tcp` Hosts.
///
/// `NWBrowser` is macOS 10.15+, so this works on Catalina; the older
/// `NSNetServiceBrowser` is not needed.
final class BonjourBrowser {
    /// Fired on `callbackQueue` whenever the result set changes.
    var onResultsChange: (([DiscoveredHost]) -> Void)?
    var onError: ((String) -> Void)?

    private(set) var hosts: [DiscoveredHost] = []

    private let queue: DispatchQueue
    private let callbackQueue: DispatchQueue
    private var browser: NWBrowser?
    private let log = Log(.discovery)

    init(queue: DispatchQueue, callbackQueue: DispatchQueue = .main) {
        self.queue = queue
        self.callbackQueue = callbackQueue
    }

    func start() {
        stop()
        let parameters = NWParameters()
        // Bonjour results are needed from every interface: the iMac may reach
        // the Host over Ethernet, Wi-Fi or a direct cable.
        parameters.includePeerToPeer = false

        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: OMDProtocol.bonjourServiceType, domain: nil),
            using: parameters)

        browser.stateUpdateHandler = { [weak self] state in
            guard let self = self else { return }
            switch state {
            case .ready:
                self.log.info("Browsing for \(OMDProtocol.bonjourServiceType)")
            case .failed(let error):
                self.log.failure("Browser failed", error)
                self.callbackQueue.async { self.onError?(error.localizedDescription) }
            case .cancelled:
                self.log.info("Browser cancelled")
            default:
                break
            }
        }

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self = self else { return }
            let hosts = results.compactMap(BonjourBrowser.makeHost)
                .sorted { $0.serviceName.localizedCaseInsensitiveCompare($1.serviceName) == .orderedAscending }
            self.hosts = hosts
            self.log.info("Discovered \(hosts.count) host(s): \(hosts.map { $0.serviceName }.joined(separator: ", "))")
            self.callbackQueue.async { self.onResultsChange?(hosts) }
        }

        self.browser = browser
        browser.start(queue: queue)
    }

    func stop() {
        browser?.stateUpdateHandler = nil
        browser?.browseResultsChangedHandler = nil
        browser?.cancel()
        browser = nil
    }

    private static func makeHost(from result: NWBrowser.Result) -> DiscoveredHost? {
        guard case .service(let name, _, _, _) = result.endpoint else { return nil }

        var model: String?
        var osVersion: String?
        var protocolVersion: Int?
        var addresses: [LinkFilter: String] = [:]
        var port = OMDProtocol.defaultPort
        if case .bonjour(let txt) = result.metadata {
            model = txt[OMDProtocol.TXTKey.deviceModel]
            osVersion = txt[OMDProtocol.TXTKey.osVersion]
            protocolVersion = txt[OMDProtocol.TXTKey.protocolVersion].flatMap(Int.init)
            if let eth = txt[OMDProtocol.TXTKey.ethernetAddress] { addresses[.ethernet] = eth }
            if let wifi = txt[OMDProtocol.TXTKey.wifiAddress] { addresses[.wifi] = wifi }
            if let published = txt[OMDProtocol.TXTKey.port].flatMap(UInt16.init) { port = published }
        }

        return DiscoveredHost(endpoint: result.endpoint,
                              interfaces: result.interfaces,
                              serviceName: name,
                              model: model,
                              osVersion: osVersion,
                              protocolVersion: protocolVersion,
                              addresses: addresses,
                              port: port)
    }
}
