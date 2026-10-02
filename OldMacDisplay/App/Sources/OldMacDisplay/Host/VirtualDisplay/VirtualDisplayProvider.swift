import Foundation
import CoreGraphics
import OldMacDisplayShared

/// What the rest of the app knows about a virtual display.
struct VirtualDisplay {
    let displayID: CGDirectDisplayID
    let name: String
    let width: Int
    let height: Int
    let refreshRate: Int
}

struct VirtualDisplayConfiguration: Equatable {
    var name: String
    var width: Int
    var height: Int
    var refreshRate: Int
    /// Advertise Retina modes. Left off by default: the point of this project is
    /// streaming to an old panel, and HiDPI doubles the pixels to encode.
    var hiDPI: Bool = false

    init(name: String = "OldMacDisplay",
         width: Int, height: Int, refreshRate: Int, hiDPI: Bool = false) {
        self.name = name
        self.width = width
        self.height = height
        self.refreshRate = refreshRate
        self.hiDPI = hiDPI
    }

    init(mode: DisplayMode, name: String = "OldMacDisplay") {
        self.init(name: name, width: mode.width, height: mode.height,
                  refreshRate: mode.refreshRate)
    }
}

enum VirtualDisplayError: LocalizedError {
    case unsupported(String)
    case creationFailed(String)
    /// The detail says what macOS did report, for the user to pass on.
    case didNotAppear(String)

    var errorDescription: String? {
        switch self {
        case .unsupported(let detail):
            return "Virtual displays are not available on this macOS version. \(detail)"
        case .creationFailed(let detail):
            return "Could not create the virtual display. \(detail)"
        case .didNotAppear(let detail):
            return "The virtual display was created but macOS never listed it as active. \(detail)"
        }
    }
}

/// Creates and destroys the extra desktop macOS will extend onto.
///
/// Deliberately an abstraction: the only implementation today uses private
/// CoreGraphics API, and if Apple ships a supported route (or breaks this one)
/// only the implementation changes. Nothing above this protocol knows how the
/// display is made.
protocol VirtualDisplayProvider: AnyObject {
    /// Whether this provider can work on the current system. Check before use.
    var isSupported: Bool { get }
    /// Human-readable detail for diagnostics and error messages.
    var availabilityReport: String { get }

    /// Completion-based on purpose. Two reasons:
    ///
    /// * macOS registers the new display through the main run loop, so a caller
    ///   that blocks waiting for it deadlocks and the display never appears
    /// * this binary must stay free of Swift Concurrency for Catalina
    ///
    /// `completion` is called on the main queue.
    func createDisplay(configuration: VirtualDisplayConfiguration,
                       completion: @escaping (Result<VirtualDisplay, Error>) -> Void)
    func destroyDisplay()

    var currentDisplay: VirtualDisplay? { get }
}
