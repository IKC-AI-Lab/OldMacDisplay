import Foundation

/// What the user picked in the Host UI. `auto` everywhere means "let the
/// negotiator decide from the Receiver's reported hardware".
public struct HostPreferences: Equatable {
    public enum Resolution: Equatable {
        case auto
        case fixed(width: Int, height: Int)
        /// Match the Receiver's own panel resolution.
        case native
    }

    public enum FrameRate: Equatable {
        case auto
        case fixed(Int)
    }

    public enum Codec: Equatable {
        case auto
        case forced(VideoCodec)
    }

    /// What happens to the virtual display when the Receiver drops off
    /// without saying goodbye: it slept, lost the cable, or the Host itself
    /// slept long enough for the heartbeat to give up.
    ///
    /// Removing the display at once makes macOS move every window on it to
    /// the Host's own screen, so when the Receiver comes back it finds an
    /// empty desktop. Keeping it lets the same windows reappear. A Receiver
    /// that disconnects on purpose always removes it at once.
    public enum DisplayRetention: Equatable {
        case removeImmediately
        case seconds(Int)
        case untilRemoved
    }

    public var resolution: Resolution
    public var frameRate: FrameRate
    public var quality: QualityPreset
    public var codec: Codec
    public var displayRetention: DisplayRetention

    public init(resolution: Resolution = .auto,
                frameRate: FrameRate = .auto,
                quality: QualityPreset = .balanced,
                codec: Codec = .auto,
                displayRetention: DisplayRetention = .seconds(30 * 60)) {
        self.resolution = resolution
        self.frameRate = frameRate
        self.quality = quality
        self.codec = codec
        self.displayRetention = displayRetention
    }

    public static let `default` = HostPreferences()
}
