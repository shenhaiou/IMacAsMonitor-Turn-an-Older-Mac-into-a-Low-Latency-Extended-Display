import AppKit
import Foundation
import IOKit.pwr_mgt
import MAMCore

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var hostField: NSTextField!
    private var statusLabel: NSTextField!
    private var sourceButton: NSButton!
    private var receiverButton: NSButton!
    private var stopButton: NSButton!
    private var extendedDisplayCheckbox: NSButton!

    private var sourceConnection: MessageConnection?
    private var receiverBrowser: ReceiverBrowser?
    private var captureSource: ScreenCaptureSource?
    private var encoder: H264Encoder?
    private var virtualDisplay: VirtualDisplayProvider?

    private var listener: ReceiverListener?
    private var receiverConnection: MessageConnection?
    private var decoder: H264Decoder?
    private var videoWindow: VideoWindowController?
    private var activityAssertion: IOPMAssertionID = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        buildWindow()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopEverything()
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow, closingWindow === window else { return }
        NSApp.terminate(nil)
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu()
        let applicationMenuItem = NSMenuItem()
        mainMenu.addItem(applicationMenuItem)

        let applicationMenu = NSMenu()
        applicationMenu.addItem(
            withTitle: "About IMacAsMonitor",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        applicationMenu.addItem(.separator())
        let quitItem = NSMenuItem(
            title: "Quit IMacAsMonitor",
            action: #selector(quitAction),
            keyEquivalent: "q"
        )
        quitItem.target = self
        applicationMenu.addItem(quitItem)
        applicationMenuItem.submenu = applicationMenu
        NSApp.mainMenu = mainMenu
    }

    private func buildWindow() {
        let contentRect = CGRect(x: 0, y: 0, width: 540, height: 375)
        window = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "IMacAsMonitor Prototype"
        window.delegate = self
        window.center()

        let title = NSTextField(labelWithString: "IMacAsMonitor")
        title.font = .systemFont(ofSize: 26, weight: .semibold)
        title.alignment = .center

        let explanation = NSTextField(wrappingLabelWithString:
            "Run Receiver on the 2017 MacBook Pro. Run Source on the M1 Max. " +
            "The source discovers the receiver automatically. Press Escape to leave full screen."
        )
        explanation.alignment = .center
        explanation.textColor = .secondaryLabelColor

        let hostLabel = NSTextField(labelWithString: "Receiver address (optional)")
        hostField = NSTextField(string: "")
        hostField.placeholderString = "Automatic discovery"

        extendedDisplayCheckbox = NSButton(
            checkboxWithTitle: "Create a virtual extended display on the source (experimental)",
            target: nil,
            action: nil
        )
        extendedDisplayCheckbox.state = .on

        receiverButton = NSButton(title: "Start Receiver", target: self, action: #selector(startReceiver))
        receiverButton.bezelStyle = .rounded
        sourceButton = NSButton(title: "Start Source", target: self, action: #selector(startSource))
        sourceButton.bezelStyle = .rounded
        stopButton = NSButton(title: "Stop", target: self, action: #selector(stopAction))
        stopButton.bezelStyle = .rounded
        stopButton.isEnabled = false
        let quitButton = NSButton(title: "Quit", target: self, action: #selector(quitAction))
        quitButton.bezelStyle = .rounded

        statusLabel = NSTextField(wrappingLabelWithString: "Ready")
        statusLabel.alignment = .center
        statusLabel.textColor = .secondaryLabelColor

        let hostRow = NSStackView(views: [hostLabel, hostField])
        hostRow.orientation = .horizontal
        hostRow.spacing = 12
        hostField.widthAnchor.constraint(equalToConstant: 220).isActive = true

        let buttonRow = NSStackView(views: [receiverButton, sourceButton, stopButton, quitButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 12
        buttonRow.distribution = .fillEqually

        let stack = NSStackView(views: [title, explanation, hostRow, extendedDisplayCheckbox, buttonRow, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 18
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView?.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -32),
            stack.centerYAnchor.constraint(equalTo: window.contentView!.centerYAnchor),
            explanation.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonRow.widthAnchor.constraint(equalToConstant: 440),
            statusLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func startReceiver() {
        stopEverything()
        updateStatus("Starting receiver…")
        do {
            let listener = ReceiverListener()
            listener.stateChanged = { [weak self] status in self?.updateStatus(status) }
            listener.acceptedConnection = { [weak self] connection in
                Task { @MainActor in self?.acceptReceiverConnection(connection) }
            }
            try listener.start()
            self.listener = listener
            receiverButton.isEnabled = false
            sourceButton.isEnabled = false
            stopButton.isEnabled = true
        } catch {
            updateStatus("Receiver failed: \(error.localizedDescription)")
        }
    }

    @objc private func startSource() {
        stopEverything()
        let host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        receiverButton.isEnabled = false
        sourceButton.isEnabled = false
        stopButton.isEnabled = true
        if host.isEmpty {
            discoverReceiver()
        } else {
            connectToReceiver(
                MessageConnection(host: host, port: ReceiverListener.port),
                description: "\(host):\(ReceiverListener.port)"
            )
        }
    }

    private func discoverReceiver() {
        updateStatus("Searching for an IMacAsMonitor receiver…")
        let browser = ReceiverBrowser()
        browser.stateChanged = { [weak self] status in self?.updateStatus(status) }
        browser.receiverFound = { [weak self, weak browser] endpoint, name, interface in
            Task { @MainActor in
                guard let self, self.receiverBrowser === browser else { return }
                browser?.stop()
                self.receiverBrowser = nil
                self.connectToReceiver(
                    MessageConnection(endpoint: endpoint, requiredInterface: interface),
                    description: name
                )
            }
        }
        receiverBrowser = browser
        browser.start()
    }

    private func connectToReceiver(_ connection: MessageConnection, description: String) {
        guard sourceConnection == nil else { return }
        updateStatus("Found \(description). Connecting…")
        connection.stateChanged = { [weak self, weak connection] state in
            guard let connection else { return }
            Task { @MainActor in self?.handleSourceState(state, for: connection) }
        }
        connection.messageReceived = { [weak self, weak connection] message in
            guard let connection else { return }
            Task { @MainActor in self?.handleSourceMessage(message, from: connection) }
        }
        sourceConnection = connection
        connection.start()
    }

    @objc private func stopAction() {
        stopEverything()
        updateStatus("Stopped")
    }

    @objc private func quitAction() {
        NSApp.terminate(nil)
    }

    private func handleSourceState(_ state: MessageConnection.State, for connection: MessageConnection) {
        guard sourceConnection === connection else { return }
        switch state {
        case .ready:
            updateStatus("Connected. Waiting for the receiver's display profile…")
            sourceConnection?.send(type: .hello, payload: Data("M1 Max source".utf8))
            Task { @MainActor [weak self, weak connection] in
                try? await Task.sleep(for: .seconds(3))
                guard
                    let self, let connection,
                    self.sourceConnection === connection,
                    self.captureSource == nil,
                    self.encoder == nil
                else { return }
                self.updateStatus("Receiver did not report a display; using 1440×900 fallback.")
                self.prepareSourceDisplayAndCapture(mode: .fallback)
            }
        case .failed(let error):
            updateStatus("Connection failed: \(error.localizedDescription)")
            stopSourceSession(cancelConnection: false)
        case .cancelled:
            updateStatus("Connection closed")
            stopSourceSession(cancelConnection: false)
        case .setup:
            break
        }
    }

    private func handleSourceMessage(_ message: WireMessage, from connection: MessageConnection) {
        guard sourceConnection === connection else { return }
        switch message.type {
        case .requestKeyframe:
            encoder?.requestKeyframe()
        case .receiverDisplayProfile:
            guard captureSource == nil, encoder == nil else { return }
            do {
                let profile = try ReceiverDisplayProfile(decoding: message.payload)
                let mode = NegotiatedDisplayMode(profile: profile)
                updateStatus(
                    "Receiver: \(profile.pixelWidth)×\(profile.pixelHeight) pixels, " +
                    "\(profile.logicalWidth)×\(profile.logicalHeight) logical. Preparing display…"
                )
                prepareSourceDisplayAndCapture(mode: mode)
            } catch {
                updateStatus("Invalid receiver display profile; using 1440×900 fallback.")
                prepareSourceDisplayAndCapture(mode: .fallback)
            }
        default:
            break
        }
    }

    private func prepareSourceDisplayAndCapture(mode: NegotiatedDisplayMode) {
        guard captureSource == nil, encoder == nil, virtualDisplay == nil else { return }
        var targetDisplayID: CGDirectDisplayID?
        if extendedDisplayCheckbox.state == .on {
            do {
                let virtualDisplay = try VirtualDisplayProvider(
                    logicalWidth: mode.logicalWidth,
                    logicalHeight: mode.logicalHeight,
                    refreshRate: Double(mode.framesPerSecond)
                )
                self.virtualDisplay = virtualDisplay
                targetDisplayID = virtualDisplay.displayID
                updateStatus(
                    "Created \(mode.logicalWidth)×\(mode.logicalHeight) virtual display. " +
                    "Requesting Screen Recording access…"
                )
            } catch {
                updateStatus("Virtual display failed: \(error.localizedDescription)")
                stopSourceSession(cancelConnection: true)
                return
            }
        } else {
            updateStatus("Using the main display. Requesting Screen Recording access…")
        }

        let encoder = H264Encoder(
            width: mode.streamWidth,
            height: mode.streamHeight,
            framesPerSecond: mode.framesPerSecond
        )
        encoder.configurationProduced = { [weak self] configuration in
            self?.sourceConnection?.send(type: .videoConfiguration, payload: configuration.encoded())
        }
        encoder.frameProduced = { [weak self] data, isKeyframe, pts in
            self?.sourceConnection?.send(
                type: .videoFrame,
                flags: isKeyframe ? 1 : 0,
                presentationTimeMicroseconds: pts,
                payload: data
            )
        }
        encoder.failed = { [weak self] message in self?.updateStatus(message) }

        let capture = ScreenCaptureSource(encoder: encoder, targetDisplayID: targetDisplayID)
        capture.statusChanged = { [weak self] status in self?.updateStatus(status) }
        self.encoder = encoder
        captureSource = capture
        Task {
            do {
                try await capture.start()
            } catch {
                updateStatus("Capture failed: \(error.localizedDescription). Check System Settings → Privacy & Security → Screen Recording.")
                stopSourceSession(cancelConnection: true)
            }
        }
    }

    private func acceptReceiverConnection(_ connection: MessageConnection) {
        receiverConnection?.cancel()
        receiverConnection = connection
        let decoder = H264Decoder()
        let videoWindow = VideoWindowController()
        decoder.frameDecoded = { [weak videoWindow] frame in videoWindow?.present(frame) }
        decoder.failed = { [weak self] status in self?.updateStatus(status) }
        self.decoder = decoder
        self.videoWindow = videoWindow

        connection.stateChanged = { [weak self, weak connection] state in
            guard let connection else { return }
            Task { @MainActor in
                guard let self, self.receiverConnection === connection else { return }
                switch state {
                case .ready:
                    let profile = ReceiverDisplayProfile.currentBuiltInDisplay()
                    connection.send(type: .receiverDisplayProfile, payload: profile.encoded())
                    self.updateStatus(
                        "Reported \(profile.pixelWidth)×\(profile.pixelHeight) pixels " +
                        "(\(profile.logicalWidth)×\(profile.logicalHeight) logical); waiting for video…"
                    )
                case .failed(let error):
                    self.updateStatus("Source disconnected: \(error.localizedDescription)")
                    self.stopReceiverSession()
                case .cancelled:
                    self.updateStatus("Source disconnected")
                    self.stopReceiverSession()
                case .setup:
                    break
                }
            }
        }
        connection.messageReceived = { [weak self] message in self?.handleReceiverMessage(message) }
        connection.start()
    }

    private func handleReceiverMessage(_ message: WireMessage) {
        switch message.type {
        case .hello:
            updateStatus("Source connected; waiting for stream configuration…")
        case .videoConfiguration:
            do {
                let configuration = try H264Configuration(decoding: message.payload)
                try decoder?.configure(configuration)
                Task { @MainActor in
                    self.beginActivityAssertion()
                    self.videoWindow?.showPresentation()
                    self.updateStatus(
                        "Receiving \(configuration.width)×\(configuration.height) H.264 " +
                        "— press Escape to reveal controls"
                    )
                }
            } catch {
                updateStatus("Decoder setup failed: \(error.localizedDescription)")
            }
        case .videoFrame:
            decoder?.decode(message.payload, presentationTimeMicroseconds: message.presentationTimeMicroseconds)
        case .ping:
            receiverConnection?.send(type: .pong)
        default:
            break
        }
    }

    private func updateStatus(_ status: String) {
        DispatchQueue.main.async { [weak self] in self?.statusLabel?.stringValue = status }
    }

    private func enableRoleButtons() {
        receiverButton?.isEnabled = true
        sourceButton?.isEnabled = true
        stopButton?.isEnabled = false
    }

    private func stopReceiverSession() {
        decoder?.stop()
        decoder = nil
        videoWindow?.closePresentation()
        videoWindow = nil
        receiverConnection = nil
        endActivityAssertion()
    }

    private func stopEverything() {
        listener?.stop()
        listener = nil
        receiverBrowser?.stop()
        receiverBrowser = nil
        stopSourceSession(cancelConnection: true)
        receiverConnection?.cancel()
        stopReceiverSession()
        enableRoleButtons()
    }

    private func stopSourceSession(cancelConnection: Bool) {
        if cancelConnection {
            sourceConnection?.cancel()
        }
        sourceConnection = nil
        let displayToRelease = virtualDisplay
        virtualDisplay = nil
        let sourceToStop = captureSource
        captureSource = nil
        encoder = nil
        if let sourceToStop {
            Task {
                await sourceToStop.stop()
                withExtendedLifetime(displayToRelease) {}
            }
        }
        enableRoleButtons()
    }

    private func beginActivityAssertion() {
        guard activityAssertion == 0 else { return }
        IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "IMacAsMonitor is presenting a remote display" as CFString,
            &activityAssertion
        )
    }

    private func endActivityAssertion() {
        guard activityAssertion != 0 else { return }
        IOPMAssertionRelease(activityAssertion)
        activityAssertion = 0
    }
}
