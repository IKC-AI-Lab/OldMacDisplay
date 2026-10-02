import Foundation
import SystemConfiguration

/// This Mac's IPv4 address on each kind of link, for the Bonjour TXT record.
///
/// A resolved Bonjour endpoint carries every address the Host has, and the
/// resolver connects to whichever answers first, which on a Mac with both a
/// cable and Wi-Fi is often Wi-Fi. Publishing the per-link addresses lets a
/// Receiver that wants the cable connect straight to the cable's address.
///
/// `SCNetworkInterfaceCopyAll` (macOS 10.4+) tells wired from wireless by
/// BSD name; `getifaddrs` supplies the addresses.
enum LocalAddresses {
    struct Snapshot: Equatable {
        var ethernet: String?
        var wifi: String?
    }

    static func current() -> Snapshot {
        let types = interfaceTypesByBSDName()
        var snapshot = Snapshot()

        var first: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&first) == 0, let start = first else { return snapshot }
        defer { freeifaddrs(first) }

        for pointer in sequence(first: start, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let sa = entry.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET),
                  (Int32(entry.ifa_flags) & IFF_UP) != 0,
                  (Int32(entry.ifa_flags) & IFF_LOOPBACK) == 0 else { continue }
            let name = String(cString: entry.ifa_name)
            guard let type = types[name] else { continue }

            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &buffer, socklen_t(buffer.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(cString: buffer)
            // Self-assigned 169.254.x.x means no DHCP answered; a Receiver
            // could still be on that link (direct cable), so it is kept, but
            // a routable address on the same link type wins.
            let linkLocal = address.hasPrefix("169.254.")

            switch type {
            case .ethernet:
                if snapshot.ethernet == nil || (snapshot.ethernet!.hasPrefix("169.254.") && !linkLocal) {
                    snapshot.ethernet = address
                }
            case .wifi:
                if snapshot.wifi == nil || (snapshot.wifi!.hasPrefix("169.254.") && !linkLocal) {
                    snapshot.wifi = address
                }
            }
        }
        return snapshot
    }

    private enum LinkKind { case ethernet, wifi }

    private static func interfaceTypesByBSDName() -> [String: LinkKind] {
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [:] }
        var result: [String: LinkKind] = [:]
        for interface in interfaces {
            guard let name = SCNetworkInterfaceGetBSDName(interface) as String?,
                  let type = SCNetworkInterfaceGetInterfaceType(interface) as String? else { continue }
            // USB and Thunderbolt Ethernet adapters report as Ethernet too,
            // which is what a Receiver on a cable needs.
            if type == (kSCNetworkInterfaceTypeEthernet as String) {
                result[name] = .ethernet
            } else if type == (kSCNetworkInterfaceTypeIEEE80211 as String) {
                result[name] = .wifi
            }
        }
        return result
    }
}
