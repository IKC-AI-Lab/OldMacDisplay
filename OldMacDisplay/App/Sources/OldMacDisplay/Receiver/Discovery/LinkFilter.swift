import Foundation
import Network

/// Which physical link the Receiver looks for Hosts on.
///
/// Letting the system choose is not good enough here: a Mac reachable by both
/// cable and Wi-Fi is advertised over both, and the automatic route is usually
/// Wi-Fi even when the far slower path is the one being picked. The user
/// chooses the link explicitly, and the choice both filters the Host list and
/// pins the connection to that NIC.
enum LinkFilter: Int, CaseIterable {
    case ethernet
    case wifi

    var title: String {
        switch self {
        case .ethernet: return "Ethernet"
        case .wifi: return "Wi-Fi"
        }
    }

    var interfaceType: NWInterface.InterfaceType {
        switch self {
        case .ethernet: return .wiredEthernet
        case .wifi: return .wifi
        }
    }

    /// Wording for the empty-list state, which differs enough per link to be
    /// worth spelling out: a missing cable is a different problem to a Mac that
    /// simply is not running the app.
    var emptyMessage: String {
        switch self {
        case .ethernet:
            return "No Macs found over Ethernet. Check the cable is connected at both ends."
        case .wifi:
            return "No Macs found over Wi-Fi. Check both Macs are on the same network."
        }
    }
}
