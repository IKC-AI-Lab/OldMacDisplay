import AppKit
import OldMacDisplayShared

/// The "Host" tab: advertise this Mac, create the virtual display, stream it.
///
/// AppKit rather than SwiftUI because the app has to launch on Catalina, where
/// the SwiftUI `App` lifecycle does not exist. Every capability that needs a
/// newer macOS is gated at runtime, and the whole pane explains itself when the
/// machine cannot host.
final class HostPaneController: NSViewController {

    /// Hosting needs ScreenCaptureKit (macOS 12.3+) and the virtual display API.
    /// On the 2013 iMac this is false and the pane says so instead of offering
    /// controls that cannot work.
    static var isSupportedOnThisMac: Bool {
        if #available(macOS 13.0, *) { return true }
        return false
    }

    private var server: HostServer?
    private let log = Log(.app)

    private let statusDot = PaneStyle.StatusDot()
    private let statusLabel = NSTextField(labelWithString: "Starting…")
    private let advertisingLabel = NSTextField(labelWithString: "")
    private let receiverLabel = NSTextField(labelWithString: "No receiver connected")
    private let virtualDisplayLabel = NSTextField(labelWithString: "")
    private let negotiatedLabel = NSTextField(labelWithString: "")
    private let streamLabel = NSTextField(labelWithString: "")
    private let latencyLabel = NSTextField(labelWithString: "")
    private let errorLabel = NSTextField(labelWithString: "")
    private let permissionButton = NSButton(title: "Open Screen Recording Settings…",
                                            target: nil, action: nil)
    private let disconnectButton = NSButton(title: "Disconnect", target: nil, action: nil)

    private let resolutionPopUp = NSPopUpButton()
    private let fpsPopUp = NSPopUpButton()
    private let qualityPopUp = NSPopUpButton()
    private let codecPopUp = NSPopUpButton()
    private let retentionPopUp = NSPopUpButton()

    /// Menu order of `retentionPopUp`.
    private static let retentionChoices: [(title: String, value: HostPreferences.DisplayRetention)] = [
        ("Remove at once", .removeImmediately),
        ("5 minutes", .seconds(5 * 60)),
        ("30 minutes", .seconds(30 * 60)),
        ("2 hours", .seconds(2 * 60 * 60)),
        ("Until removed", .untilRemoved)
    ]
    /// Whether the button currently removes a kept display rather than
    /// disconnecting a live Receiver.
    private var buttonRemovesDisplay = false

    private var preferences = HostPreferences.default {
        didSet { server?.updatePreferences(preferences) }
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 470))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        guard HostPaneController.isSupportedOnThisMac else {
            buildUnsupportedUI()
            return
        }
        buildUI()
        startServer()
    }

    // MARK: - Unsupported machine

    private func buildUnsupportedUI() {
        let title = PaneStyle.title("This Mac can’t host a display")

        let body = NSTextField(wrappingLabelWithString: """
            Sharing a display needs ScreenCaptureKit and the virtual-display \
            API, which require macOS 13 or later. This Mac is running \
            macOS \(SystemFacts.osVersionString).

            Use the Receiver tab to show another Mac’s screen on this one.
            """)
        body.font = .systemFont(ofSize: 12)
        body.textColor = .secondaryLabelColor

        let stack = PaneStyle.column([title, PaneStyle.card(body)], spacing: 12)
        stack.edgeInsets = NSEdgeInsets(top: 24, left: PaneStyle.Metrics.paneInset,
                                        bottom: 24, right: PaneStyle.Metrics.paneInset)
        pin(stack)
        body.widthAnchor.constraint(
            equalTo: stack.widthAnchor,
            constant: -(PaneStyle.Metrics.paneInset * 2 + PaneStyle.Metrics.cardPadding * 2)
        ).isActive = true
    }

    // MARK: - Supported machine

    private func buildUI() {
        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        let statusRow = PaneStyle.row([statusDot, statusLabel], spacing: 8)

        [advertisingLabel, receiverLabel, virtualDisplayLabel,
         negotiatedLabel].forEach {
            $0.font = .systemFont(ofSize: 12)
            $0.textColor = .secondaryLabelColor
            $0.lineBreakMode = .byTruncatingTail
        }
        latencyLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        latencyLabel.textColor = .secondaryLabelColor
        streamLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        streamLabel.textColor = .secondaryLabelColor
        streamLabel.maximumNumberOfLines = 2

        errorLabel.font = .systemFont(ofSize: 11)
        errorLabel.textColor = .systemRed
        errorLabel.maximumNumberOfLines = 4
        errorLabel.lineBreakMode = .byWordWrapping
        errorLabel.isHidden = true

        permissionButton.target = self
        permissionButton.action = #selector(openScreenRecordingSettings)
        permissionButton.controlSize = .small
        permissionButton.isHidden = true

        disconnectButton.target = self
        disconnectButton.action = #selector(disconnectTapped)
        disconnectButton.isEnabled = false

        buildSettingsControls()

        // MARK: Status card

        let statusColumn = PaneStyle.column([
            statusRow, advertisingLabel, receiverLabel, virtualDisplayLabel
        ], spacing: 5)
        let statusCard = PaneStyle.card(statusColumn)

        // MARK: Stream card — empty until something is actually streaming

        let streamColumn = PaneStyle.column([
            negotiatedLabel, streamLabel, latencyLabel
        ], spacing: 5)
        let streamSection = PaneStyle.section("Stream", streamColumn)

        // MARK: Settings card

        let settingsGrid = NSGridView(views: [
            [label("Resolution"), resolutionPopUp],
            [label("Frame Rate"), fpsPopUp],
            [label("Quality"), qualityPopUp],
            [label("Codec"), codecPopUp],
            [label("Keep Display"), retentionPopUp]
        ])
        settingsGrid.rowSpacing = 8
        settingsGrid.columnSpacing = 12
        settingsGrid.column(at: 0).xPlacement = .trailing

        // Each pop-up otherwise sizes to its own longest title, so the four
        // controls end up four different widths in one column.
        let popUps = [resolutionPopUp, fpsPopUp, qualityPopUp, codecPopUp, retentionPopUp]
        popUps.forEach {
            $0.widthAnchor.constraint(equalTo: resolutionPopUp.widthAnchor).isActive = true
        }
        resolutionPopUp.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true

        let settingsSection = PaneStyle.section("Settings", settingsGrid)

        // MARK: Problems — hidden unless there is one

        let problemColumn = PaneStyle.column([errorLabel, permissionButton], spacing: 8)

        let buttons = PaneStyle.row([PaneStyle.spacer(), disconnectButton])

        let stack = NSStackView(views: [
            PaneStyle.title("Sharing This Mac"),
            statusCard, streamSection, settingsSection,
            problemColumn, buttons
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = PaneStyle.Metrics.sectionSpacing
        stack.setCustomSpacing(10, after: stack.views[0])
        stack.edgeInsets = NSEdgeInsets(top: PaneStyle.Metrics.paneInset,
                                        left: PaneStyle.Metrics.paneInset,
                                        bottom: PaneStyle.Metrics.paneInset,
                                        right: PaneStyle.Metrics.paneInset)
        pin(stack)

        // One column: every section spans the pane so the cards align.
        let full = { (child: NSView) in
            child.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                         constant: -PaneStyle.Metrics.paneInset * 2).isActive = true
        }
        [statusCard, streamSection, settingsSection, problemColumn, buttons,
         errorLabel].forEach(full)
    }

    private func buildSettingsControls() {
        resolutionPopUp.addItems(withTitles: ["Auto", "1920 × 1080", "2560 × 1440", "Native"])
        fpsPopUp.addItems(withTitles: ["Auto", "30", "60"])
        qualityPopUp.addItems(withTitles: ["Performance", "Balanced", "Quality"])
        qualityPopUp.selectItem(at: 1)
        codecPopUp.addItems(withTitles: ["Auto", "H.264", "HEVC"])
        retentionPopUp.addItems(withTitles: HostPaneController.retentionChoices.map(\.title))
        retentionPopUp.toolTip = "How long the virtual display, and the windows on it, wait for a Receiver that dropped off without disconnecting (it slept, or lost its cable). Disconnecting on purpose always removes it at once."

        [resolutionPopUp, fpsPopUp, qualityPopUp, codecPopUp, retentionPopUp].forEach {
            $0.target = self
            $0.action = #selector(settingsChanged)
        }
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 12)
        field.textColor = .secondaryLabelColor
        return field
    }

    private func separator() -> NSBox {
        let box = NSBox()
        box.boxType = .separator
        return box
    }

    private func pin(_ stack: NSStackView) {
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: view.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor)
        ])
    }

    // MARK: - Server

    private func startServer() {
        let options = HostLaunchOptions.parse()
        preferences = options.preferences
        applyPreferencesToControls()

        let server = HostServer(preferences: preferences)
        server.onStatusChange = { [weak self] status in self?.render(status) }
        self.server = server
        server.start()
    }

    private func applyPreferencesToControls() {
        switch preferences.resolution {
        case .auto: resolutionPopUp.selectItem(at: 0)
        case .fixed(let w, _): resolutionPopUp.selectItem(at: w == 2560 ? 2 : 1)
        case .native: resolutionPopUp.selectItem(at: 3)
        }
        switch preferences.frameRate {
        case .auto: fpsPopUp.selectItem(at: 0)
        case .fixed(let fps): fpsPopUp.selectItem(at: fps <= 30 ? 1 : 2)
        }
        switch preferences.quality {
        case .performance: qualityPopUp.selectItem(at: 0)
        case .balanced: qualityPopUp.selectItem(at: 1)
        case .quality: qualityPopUp.selectItem(at: 2)
        }
        switch preferences.codec {
        case .auto: codecPopUp.selectItem(at: 0)
        case .forced(.h264): codecPopUp.selectItem(at: 1)
        case .forced(.hevc): codecPopUp.selectItem(at: 2)
        }
        let retentionIndex = HostPaneController.retentionChoices
            .firstIndex { $0.value == preferences.displayRetention } ?? 2
        retentionPopUp.selectItem(at: retentionIndex)
    }

    @objc private func settingsChanged() {
        var updated = preferences
        switch resolutionPopUp.indexOfSelectedItem {
        case 1: updated.resolution = .fixed(width: 1920, height: 1080)
        case 2: updated.resolution = .fixed(width: 2560, height: 1440)
        case 3: updated.resolution = .native
        default: updated.resolution = .auto
        }
        switch fpsPopUp.indexOfSelectedItem {
        case 1: updated.frameRate = .fixed(30)
        case 2: updated.frameRate = .fixed(60)
        default: updated.frameRate = .auto
        }
        switch qualityPopUp.indexOfSelectedItem {
        case 0: updated.quality = .performance
        case 2: updated.quality = .quality
        default: updated.quality = .balanced
        }
        switch codecPopUp.indexOfSelectedItem {
        case 1: updated.codec = .forced(.h264)
        case 2: updated.codec = .forced(.hevc)
        default: updated.codec = .auto
        }
        let choices = HostPaneController.retentionChoices
        if choices.indices.contains(retentionPopUp.indexOfSelectedItem) {
            updated.displayRetention = choices[retentionPopUp.indexOfSelectedItem].value
        }
        preferences = updated
    }

    @objc private func disconnectTapped() {
        if buttonRemovesDisplay {
            server?.removeRetainedDisplay()
        } else {
            server?.disconnectCurrentSession()
        }
    }

    @objc private func openScreenRecordingSettings() {
        if #available(macOS 13.0, *) { DisplayCapturer.openScreenRecordingSettings() }
    }

    // MARK: - Rendering

    private func render(_ status: HostServer.Status) {
        let connected: Bool
        switch status.connectionState {
        case .connected: connected = true
        default: connected = false
        }

        statusDot.apply(connected ? .live : (status.advertising ? .working : .idle))

        switch status.connectionState {
        case .idle:
            statusLabel.stringValue = status.advertising ? "Waiting for a receiver" : "Not advertising"
        case .connecting:   statusLabel.stringValue = "Receiver connecting…"
        case .handshaking:  statusLabel.stringValue = "Negotiating…"
        case .connected:    statusLabel.stringValue = "Connected"
        case .reconnecting(let attempt):
            statusLabel.stringValue = "Reconnecting (attempt \(attempt))…"
        case .disconnected(let reason):
            statusLabel.stringValue = status.displayRetention != nil
                ? "Waiting for the receiver to come back — \(reason)"
                : "Disconnected — \(reason)"
        }

        advertisingLabel.stringValue = status.advertising
            ? "Advertising as “\(SystemFacts.computerName)” on port \(status.port)"
            : ""

        if let peer = status.peer {
            var parts: [String] = [peer.device?.name ?? "Receiver"]
            if let model = peer.device?.model { parts.append(model) }
            parts.append(peer.endpoint)
            if let net = peer.capabilities?.activeNetworkType {
                parts.append(net == .ethernet ? "Ethernet" : net.rawValue.capitalized)
            }
            receiverLabel.stringValue = parts.joined(separator: " · ")
        } else {
            receiverLabel.stringValue = "No receiver connected"
        }

        if let retention = status.displayRetention, let id = status.virtualDisplayID {
            let until = retention.seconds.map { " for up to \(Self.describe(seconds: $0))" } ?? " until you remove it"
            virtualDisplayLabel.stringValue = "Virtual display: kept with its windows\(until) (id \(id))"
        } else if let id = status.virtualDisplayID {
            virtualDisplayLabel.stringValue = "Virtual display: active (id \(id))"
        } else {
            virtualDisplayLabel.stringValue = "Virtual display: not created"
        }

        if let config = status.negotiated {
            PaneStyle.setText(negotiatedLabel, String(
                format: "%@ · %@ · %.1f Mbps target",
                "\(config.mode)", config.codec.rawValue.uppercased(),
                Double(config.targetBitrateBPS) / 1_000_000))
        } else {
            PaneStyle.setText(negotiatedLabel, "")
        }

        if status.streaming {
            var text = String(format: "%.0f fps · %.1f Mbps · encode %.1f ms",
                              status.measuredFPS,
                              Double(status.measuredBitrateBPS) / 1_000_000,
                              status.encodeMillis)
            // Only worth a mention once the adaptive loop has moved off the
            // negotiated target.
            if let current = status.currentBitrateBPS,
               let target = status.negotiated?.targetBitrateBPS, current != target {
                text += String(format: " · adapted to %.1f Mbps", Double(current) / 1_000_000)
            }
            // Only shown once it actually happens: a permanent "dropped: 0" is
            // noise, but a rising count is the clearest sign of a bad link.
            if status.networkDroppedFrames > 0 {
                text += " · dropped \(status.networkDroppedFrames)"
            }
            // The receiver's own figure is the one that matters: it is what is
            // actually on the old Mac's screen. A large gap between the two is
            // the clearest sign that the link or the decoder cannot keep up.
            if let receiverFPS = status.receiverFPS {
                text += String(format: "\n→ receiver: %.0f fps", receiverFPS)
                if let ratio = status.receiverDropRatio, ratio > 0.01 {
                    text += String(format: ", %.0f%% dropped", ratio * 100)
                }
                if let queueing = status.receiverQueueingMillis, queueing >= 5 {
                    text += String(format: ", queueing %.0f ms", queueing)
                }
            }
            // When the controller has had to give up more than half the
            // budget, the link is the problem and no quality setting will fix
            // it; say so rather than letting the user chase encoder settings.
            if let current = status.currentBitrateBPS,
               let target = status.negotiated?.targetBitrateBPS,
               Double(current) < Double(target) * 0.5 {
                text += "\n⚠︎ The link cannot carry this mode. Use Ethernet, or lower the resolution or frame rate."
                streamLabel.maximumNumberOfLines = 3
            }
            PaneStyle.setText(streamLabel, text)
        } else {
            PaneStyle.setText(streamLabel, "")
        }

        var latency = status.latencyMilliseconds
            .map { String(format: "Latency: %.1f ms round trip", $0) } ?? "Latency: —"
        if let endToEnd = status.receiverEndToEndMillis {
            latency += String(format: " · %.0f ms capture → screen", endToEnd)
        }
        latencyLabel.stringValue = latency

        if let error = status.lastError {
            errorLabel.stringValue = error
            errorLabel.isHidden = false
            permissionButton.isHidden = !error.contains("Screen Recording")
        } else {
            errorLabel.isHidden = true
            permissionButton.isHidden = true
        }

        buttonRemovesDisplay = status.peer == nil && status.displayRetention != nil
        disconnectButton.title = buttonRemovesDisplay ? "Remove Display" : "Disconnect"
        disconnectButton.isEnabled = status.peer != nil || buttonRemovesDisplay
    }

    private static func describe(seconds: Int) -> String {
        if seconds % 3600 == 0 { return seconds == 3600 ? "1 hour" : "\(seconds / 3600) hours" }
        if seconds >= 60 { return "\(seconds / 60) min" }
        return "\(seconds) s"
    }
}
