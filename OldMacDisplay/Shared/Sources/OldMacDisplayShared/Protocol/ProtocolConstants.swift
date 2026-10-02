import Foundation

/// Static facts about the OldMacDisplay wire protocol.
public enum OMDProtocol {
    /// Bumped whenever the wire format or message set changes incompatibly.
    ///
    /// v2: separate video connection (`attachVideo`), out-of-band cursor,
    /// clock-sync fields in `pong`, queueing/latency fields in `networkStats`.
    public static let version: UInt8 = 2

    /// Bonjour service type advertised by the Host and browsed by the Receiver.
    public static let bonjourServiceType = "_oldmacdisplay._tcp"

    /// Default TCP port. 0 would let the system pick, but a fixed port makes
    /// manual/direct-Ethernet fallback (typing an IP by hand) possible.
    public static let defaultPort: UInt16 = 51843

    /// Keys used in the Bonjour TXT record so the Receiver can render a useful
    /// list entry before it has connected to anything.
    public enum TXTKey {
        public static let protocolVersion = "pv"
        public static let deviceName = "name"
        public static let deviceModel = "model"
        public static let osVersion = "os"
        /// The Host's IPv4 address on each link, so a Receiver that wants a
        /// specific link can connect straight to that address instead of
        /// letting the resolver pick whichever of the Host's interfaces
        /// answers first (usually Wi-Fi, even with a cable in).
        public static let ethernetAddress = "eth"
        public static let wifiAddress = "wifi"
        public static let port = "port"
    }

    /// Upper bound on a single frame payload. Guards the receive loop against a
    /// corrupt or hostile length field causing a huge allocation.
    public static let maxPayloadLength: UInt32 = 32 * 1024 * 1024
}

/// Logical channels multiplexed over the transport.
///
/// Phase 1 carries only `.control` and all channels share a single TCP
/// connection, but the channel byte is on the wire from day one so video/audio/
/// input can be split onto their own connections (or QUIC streams) later without
/// a protocol break.
public enum OMDChannel: UInt8, CaseIterable, Equatable {
    case control = 0
    case video   = 1
    case audio   = 2
    case input   = 3
}
