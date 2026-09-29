import Foundation
import OldMacDisplayShared

/// Host command-line overrides, for diagnostics and two-machine testing.
///
///   --codec h264|hevc      force a codec instead of negotiating one
///   --fps 30|60            force a frame rate
///   --resolution WxH       force the streamed mode
///   --keep-display S|forever  how long to keep the virtual display after the
///                          Receiver drops off (0 removes it at once)
///
/// Forcing H.264 matters in testing: on a loopback run both ends report HEVC
/// hardware support and auto-negotiation picks HEVC, so the H.264 path — the one
/// a 2013 iMac will actually use — would otherwise never be exercised here.
struct HostLaunchOptions {
    var preferences = HostPreferences.default

    static func parse(_ arguments: [String] = CommandLine.arguments) -> HostLaunchOptions {
        var options = HostLaunchOptions()
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            let value: String? = (index + 1 < arguments.count && !arguments[index + 1].hasPrefix("--"))
                ? arguments[index + 1] : nil

            switch argument {
            case "--codec":
                switch value?.lowercased() {
                case "h264": options.preferences.codec = .forced(.h264)
                case "hevc": options.preferences.codec = .forced(.hevc)
                case "auto": options.preferences.codec = .auto
                default: Log(.app).error("--codec expects h264, hevc or auto")
                }
                if value != nil { index += 1 }

            case "--fps":
                if let fps = value.flatMap(Int.init) {
                    options.preferences.frameRate = .fixed(fps)
                    index += 1
                } else {
                    Log(.app).error("--fps expects a number")
                }

            case "--resolution":
                let parts = value?.lowercased().split(separator: "x") ?? []
                if parts.count == 2, let width = Int(parts[0]), let height = Int(parts[1]) {
                    options.preferences.resolution = .fixed(width: width, height: height)
                    index += 1
                } else {
                    Log(.app).error("--resolution expects WxH, e.g. 1920x1080")
                }

            case "--keep-display":
                if value == "forever" {
                    options.preferences.displayRetention = .untilRemoved
                    index += 1
                } else if let seconds = value.flatMap(Int.init) {
                    options.preferences.displayRetention = seconds <= 0 ? .removeImmediately : .seconds(seconds)
                    index += 1
                } else {
                    Log(.app).error("--keep-display expects seconds or forever")
                }

            default:
                break // macOS passes its own arguments; ignore anything unknown
            }
            index += 1
        }
        return options
    }
}
