import Foundation
import Network

extension NWInterface {
    /// True for any wired link to the other Mac.
    ///
    /// Network.framework only calls USB/Thunderbolt Ethernet adapters and
    /// built-in ports `.wiredEthernet`. A Thunderbolt cable straight between
    /// two Macs comes up as "Thunderbolt Bridge" (`bridge0`) and is reported
    /// as `.other`, even though it is the fastest wire there is. A MacBook Air
    /// has no Ethernet port, so for one this is a common way to cable it.
    public var isCable: Bool {
        switch type {
        case .wiredEthernet: return true
        case .other: return isBridge
        default: return false
        }
    }

    /// A Thunderbolt Bridge (or any other bridge) interface.
    public var isBridge: Bool { name.hasPrefix("bridge") }
}
