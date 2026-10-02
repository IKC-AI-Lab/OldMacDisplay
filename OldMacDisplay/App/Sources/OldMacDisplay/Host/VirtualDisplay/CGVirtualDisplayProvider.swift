import Foundation
import CoreGraphics
import IOKit.pwr_mgt
import OMDPrivateDisplay
import OldMacDisplayShared

/// `VirtualDisplayProvider` backed by private CoreGraphics API.
///
/// All private-API contact is inside the `OMDPrivateDisplay` Objective-C
/// target; this type only adds policy — stable monitor identity, waiting for
/// the display to appear, and teardown ordering.
final class CGVirtualDisplayProvider: VirtualDisplayProvider {

    private(set) var currentDisplay: VirtualDisplay?
    private var handle: OMDVirtualDisplayHandle?
    private let log = Log(.virtualDisplay)

    var isSupported: Bool { OMDVirtualDisplayBridge.isAvailable() }
    var availabilityReport: String { OMDVirtualDisplayBridge.availabilityReport() }

    /// macOS remembers per-monitor settings keyed on
    /// (vendorID, productID, serialNumber) and **restores the last mode it saw
    /// for that identity**, ignoring the mode we just asked for.
    ///
    /// Measured: after creating 1920x1080 once, a later request for 2560x1440
    /// under the same identity came back as 1920x1080.
    ///
    /// So the serial number is derived from the mode. Each resolution gets its
    /// own stable identity: the requested mode is honoured, and the arrangement
    /// for that mode is still remembered across launches.
    private enum Identity {
        static let vendorID: UInt32 = 0x4F4D_4400   // "OMD\0"
        static let productID: UInt32 = 0x0001

        static func serialNumber(for configuration: VirtualDisplayConfiguration) -> UInt32 {
            var hash: UInt32 = 2_166_136_261 // FNV-1a
            for value in [UInt32(configuration.width),
                          UInt32(configuration.height),
                          UInt32(configuration.refreshRate),
                          configuration.hiDPI ? 1 : 0] {
                hash = (hash ^ value) &* 16_777_619
            }
            // Zero is treated as "no serial"; keep it out of range.
            return hash == 0 ? 1 : hash
        }

        /// A second identity for the same mode, tried when the first never
        /// becomes active. macOS remembers per identity whether a display
        /// was mirrored or arranged oddly, and a fresh identity starts clean.
        /// Stable too, so its own arrangement is remembered from then on.
        static func fallbackSerialNumber(for configuration: VirtualDisplayConfiguration) -> UInt32 {
            let serial = serialNumber(for: configuration) ^ 0x5A5A_0000
            return serial == 0 ? 2 : serial
        }
    }

    /// How long one creation attempt waits for the display to become active.
    /// It is usually well under a second; a busy Intel Mac or one whose
    /// screens were just woken can take several.
    private static let appearanceTimeout: TimeInterval = 8

    /// Creating and releasing the display each trigger a display
    /// reconfiguration inside WindowServer, and the calls themselves block for
    /// a noticeable fraction of a second. They run here so the UI never
    /// freezes at connect or disconnect. Serial, so a destroy always lands
    /// before the create that follows it.
    private let workQueue = DispatchQueue(label: "com.oldmacdisplay.host.virtual-display",
                                          qos: .userInitiated)

    deinit { destroyDisplay() }

    func createDisplay(configuration: VirtualDisplayConfiguration,
                       completion: @escaping (Result<VirtualDisplay, Error>) -> Void) {
        let finish: (Result<VirtualDisplay, Error>) -> Void = { result in
            DispatchQueue.main.async { completion(result) }
        }

        guard isSupported else {
            log.error(availabilityReport)
            finish(.failure(VirtualDisplayError.unsupported(availabilityReport)))
            return
        }

        // One at a time; a second display would just be a second thing to keep
        // in sync with the single Receiver.
        destroyDisplay()

        workQueue.async { [weak self] in
            guard let self = self else { return }
            self.log.info("Creating virtual display \(configuration.width)x\(configuration.height) @\(configuration.refreshRate)Hz (hiDPI \(configuration.hiDPI))")

            // A display created while this Mac's screens are asleep is
            // asleep too, and macOS never lists a sleeping display as active.
            // That is the usual state when connecting: the user is at the
            // old Mac and this one has been left alone.
            let wake = Self.wakeDisplays(log: self.log)
            defer { if let wake { IOPMAssertionRelease(wake) } }

            let serials = [Identity.serialNumber(for: configuration),
                           Identity.fallbackSerialNumber(for: configuration)]
            var lastDetail = ""
            for (attempt, serial) in serials.enumerated() {
                // The bridge's NSError** surfaces in Swift as `throws`.
                let handle: OMDVirtualDisplayHandle
                do {
                    handle = try OMDVirtualDisplayBridge.createDisplay(
                        withName: configuration.name,
                        width: UInt32(configuration.width),
                        height: UInt32(configuration.height),
                        refreshRate: Double(configuration.refreshRate),
                        hiDPI: configuration.hiDPI,
                        vendorID: Identity.vendorID,
                        productID: Identity.productID,
                        serialNumber: serial)
                } catch {
                    self.log.failure("Virtual display creation", error)
                    finish(.failure(VirtualDisplayError.creationFailed(error.localizedDescription)))
                    return
                }

                // Creation is asynchronous inside macOS: the object exists
                // before the display is listed, and registration runs on the
                // main run loop, so this poll must never happen on the main
                // thread.
                if Self.waitForDisplay(handle.displayID, timeout: Self.appearanceTimeout, log: self.log) {
                    if attempt > 0 {
                        self.log.notice("Display \(handle.displayID) became active under the fallback identity")
                    }
                    DispatchQueue.main.async {
                        self.finishCreation(handle: handle, configuration: configuration, finish: finish)
                    }
                    return
                }

                lastDetail = Self.diagnose(handle.displayID)
                self.log.error("Display \(handle.displayID) never became active (attempt \(attempt + 1)): \(lastDetail)")
                handle.invalidate()
                // Let WindowServer finish removing it before the retry.
                Thread.sleep(forTimeInterval: 0.5)
            }
            finish(.failure(VirtualDisplayError.didNotAppear(lastDetail)))
        }
    }

    private func finishCreation(handle: OMDVirtualDisplayHandle,
                                configuration: VirtualDisplayConfiguration,
                                finish: @escaping (Result<VirtualDisplay, Error>) -> Void) {
        self.handle = handle

        // Trust macOS over our request: if it restored a remembered mode, the
        // encoder must be configured for the size actually on screen.
        let actualWidth = Int(CGDisplayPixelsWide(handle.displayID))
        let actualHeight = Int(CGDisplayPixelsHigh(handle.displayID))
        if actualWidth != configuration.width || actualHeight != configuration.height {
            log.notice("Requested \(configuration.width)x\(configuration.height) but macOS created \(actualWidth)x\(actualHeight); using the actual size")
        }

        let display = VirtualDisplay(displayID: handle.displayID,
                                     name: configuration.name,
                                     width: actualWidth,
                                     height: actualHeight,
                                     refreshRate: configuration.refreshRate)
        self.currentDisplay = display

        log.info("Virtual display active: id \(display.displayID), \(display.width)x\(display.height)")
        finish(.success(display))
    }

    func destroyDisplay() {
        guard let handle = handle else { return }
        let id = handle.displayID
        self.handle = nil
        self.currentDisplay = nil
        // Releasing the object is what removes the display, and that call
        // blocks while WindowServer reconfigures. Off the main thread.
        // Removal is asynchronous beyond that too; macOS can keep listing it
        // briefly. Nothing downstream depends on it being gone.
        workQueue.async { [log] in
            log.info("Destroying virtual display \(id)")
            handle.invalidate()
        }
    }

    /// Polls `CGGetActiveDisplayList` until the new display shows up.
    ///
    /// A display can be online (macOS knows it) without being active (drawable).
    /// When that is because macOS put it in a mirror set, mirroring is undone
    /// once, here: the point of the display is to extend the desktop.
    ///
    /// Must be called off the main thread: macOS registers the display via the
    /// main run loop, so blocking that thread here stops the very event being
    /// waited for and the display never appears.
    private static func waitForDisplay(_ displayID: CGDirectDisplayID,
                                       timeout: TimeInterval, log: Log) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var triedUnmirroring = false
        repeat {
            if activeDisplayIDs().contains(displayID) { return true }
            if !triedUnmirroring, onlineDisplayIDs().contains(displayID),
               CGDisplayIsInMirrorSet(displayID) != 0 {
                triedUnmirroring = true
                log.notice("Display \(displayID) came up mirrored; switching it to extend the desktop")
                stopMirroring(displayID, log: log)
            }
            Thread.sleep(forTimeInterval: 0.05)
        } while Date() < deadline
        return false
    }

    private static func stopMirroring(_ displayID: CGDirectDisplayID, log: Log) {
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else {
            log.error("Could not begin a display configuration to undo mirroring")
            return
        }
        // Covers both directions: our display mirroring the main one, and the
        // main one mirroring ours.
        CGConfigureDisplayMirrorOfDisplay(config, displayID, kCGNullDirectDisplay)
        let mirrored = CGDisplayMirrorsDisplay(displayID)
        let primary = CGDisplayPrimaryDisplay(displayID)
        if primary != displayID {
            CGConfigureDisplayMirrorOfDisplay(config, primary, kCGNullDirectDisplay)
        } else if mirrored != kCGNullDirectDisplay {
            CGConfigureDisplayMirrorOfDisplay(config, mirrored, kCGNullDirectDisplay)
        }
        // Permanently, so macOS remembers "extend" for this display identity.
        let result = CGCompleteDisplayConfiguration(config, .permanently)
        if result != .success {
            log.error("Undoing mirroring failed: \(result.rawValue)")
        }
    }

    /// Wakes this Mac's screens and keeps them awake until released.
    private static func wakeDisplays(log: Log) -> IOPMAssertionID? {
        var assertion: IOPMAssertionID = 0
        let result = IOPMAssertionDeclareUserActivity(
            "OldMacDisplay is creating a virtual display" as CFString,
            kIOPMUserActiveLocal, &assertion)
        guard result == kIOReturnSuccess else {
            log.error("Could not wake the displays: \(result)")
            return nil
        }
        // Waking takes a moment; creating the display before it finishes
        // makes the new one start out asleep as well.
        let deadline = Date().addingTimeInterval(3)
        while CGDisplayIsAsleep(CGMainDisplayID()) != 0, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 {
            log.notice("The main display is still asleep after asking it to wake")
        }
        return assertion
    }

    /// What macOS reports about a display that never became active, in words
    /// a user can paste into a bug report.
    private static func diagnose(_ displayID: CGDirectDisplayID) -> String {
        let online = onlineDisplayIDs()
        var facts: [String] = []
        if online.contains(displayID) {
            facts.append("macOS lists it as online but not active")
            if CGDisplayIsAsleep(displayID) != 0 { facts.append("it is asleep") }
            if CGDisplayIsInMirrorSet(displayID) != 0 { facts.append("it is mirrored") }
        } else {
            facts.append("macOS does not list it at all")
        }
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 {
            facts.append("this Mac's main screen is asleep")
        }
        facts.append("\(activeDisplayIDs().count) active and \(online.count) online displays")
        let version = ProcessInfo.processInfo.operatingSystemVersion
        facts.append("macOS \(version.majorVersion).\(version.minorVersion).\(version.patchVersion)")
        return "Details: " + facts.joined(separator: "; ") + "."
    }

    static func onlineDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    static func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }
}
