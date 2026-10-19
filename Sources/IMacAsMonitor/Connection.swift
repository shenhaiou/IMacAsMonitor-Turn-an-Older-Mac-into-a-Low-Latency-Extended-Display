import Foundation
import MAMCore
import Network

final class MessageConnection: @unchecked Sendable {
    enum State {
        case setup
        case ready
        case failed(Error)
        case cancelled
    }

    private let connection: NWConnection
    private let queue: DispatchQueue
    private var parser = WireMessageParser()
    private var sequence: UInt64 = 0
    private var started = false

    var stateChanged: ((State) -> Void)?
    var messageReceived: ((WireMessage) -> Void)?

    init(connection: NWConnection, label: String) {
        self.connection = connection
        queue = DispatchQueue(label: label, qos: .userInteractive)
    }

    convenience init(host: String, port: UInt16) {
        let endpointPort = NWEndpoint.Port(rawValue: port)!
        self.init(endpoint: .hostPort(host: NWEndpoint.Host(host), port: endpointPort))
    }

    convenience init(endpoint: NWEndpoint, requiredInterface: NWInterface? = nil) {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredInterface = requiredInterface
        self.init(
            connection: NWConnection(to: endpoint, using: parameters),
            label: "com.haiou.imac-as-monitor.connection.source"
        )
    }

    func start() {
        guard !started else { return }
        started = true
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.stateChanged?(.ready)
                self.receiveNextChunk()
            case .failed(let error):
                self.stateChanged?(.failed(error))
            case .cancelled:
                self.stateChanged?(.cancelled)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func send(
        type: WireMessageType,
        flags: UInt16 = 0,
        presentationTimeMicroseconds: UInt64 = 0,
        payload: Data = Data(),
        completion: ((NWError?) -> Void)? = nil
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            self.sequence &+= 1
            let message = WireMessage(
                type: type,
                flags: flags,
                sequence: self.sequence,
                presentationTimeMicroseconds: presentationTimeMicroseconds,
                payload: payload
            )
            self.connection.send(
                content: message.encoded(),
                completion: .contentProcessed { error in completion?(error) }
            )
        }
    }

    func cancel() {
        connection.cancel()
    }

    private func receiveNextChunk() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    for message in try self.parser.append(data) {
                        self.messageReceived?(message)
                    }
                } catch {
                    self.stateChanged?(.failed(error))
                    self.connection.cancel()
                    return
                }
            }
            if let error {
                self.stateChanged?(.failed(error))
            } else if complete {
                self.stateChanged?(.cancelled)
            } else {
                self.receiveNextChunk()
            }
        }
    }
}

final class ReceiverListener: @unchecked Sendable {
    static let port: UInt16 = 48_170
    static let serviceType = "_imacasmonitor._tcp"

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.haiou.imac-as-monitor.listener", qos: .userInteractive)

    var stateChanged: ((String) -> Void)?
    var acceptedConnection: ((MessageConnection) -> Void)?

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: Self.port)!)
        listener.service = NWListener.Service(
            name: Host.current().localizedName ?? "IMacAsMonitor Receiver",
            type: Self.serviceType
        )
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.stateChanged?("Receiver advertised automatically on TCP \(Self.port)")
            case .failed(let error):
                self?.stateChanged?("Listener failed: \(error.localizedDescription)")
            case .cancelled:
                self?.stateChanged?("Listener stopped")
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] nwConnection in
            let connection = MessageConnection(
                connection: nwConnection,
                label: "com.haiou.imac-as-monitor.connection.receiver"
            )
            self?.acceptedConnection?(connection)
        }
        self.listener = listener
        listener.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}

final class ReceiverBrowser: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.haiou.imac-as-monitor.browser", qos: .userInitiated)
    private var browser: NWBrowser?
    private var reportedReceiver = false
    private var latestResults = Set<NWBrowser.Result>()
    private var fallbackSelectionScheduled = false

    var stateChanged: ((String) -> Void)?
    var receiverFound: ((_ endpoint: NWEndpoint, _ name: String, _ interface: NWInterface?) -> Void)?

    func start() {
        guard browser == nil else { return }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        let browser = NWBrowser(
            for: .bonjour(type: ReceiverListener.serviceType, domain: nil),
            using: parameters
        )
        browser.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.stateChanged?("Searching for an IMacAsMonitor receiver…")
            case .waiting(let error):
                self?.stateChanged?("Receiver search is waiting: \(error.localizedDescription)")
            case .failed(let error):
                self?.stateChanged?("Receiver search failed: \(error.localizedDescription)")
            default:
                break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, !self.reportedReceiver else { return }
            self.latestResults = results
            if let choice = self.preferredChoice(requireThunderboltBridge: true) {
                self.report(choice)
                return
            }
            guard !results.isEmpty, !self.fallbackSelectionScheduled else { return }
            self.fallbackSelectionScheduled = true
            self.queue.asyncAfter(deadline: .now() + .milliseconds(600)) { [weak self] in
                guard let self, self.browser != nil, !self.reportedReceiver else { return }
                self.fallbackSelectionScheduled = false
                if let choice = self.preferredChoice(requireThunderboltBridge: false) {
                    self.report(choice)
                }
            }
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    func stop() {
        browser?.cancel()
        browser = nil
        reportedReceiver = false
        latestResults.removeAll()
        fallbackSelectionScheduled = false
    }

    private func preferredChoice(
        requireThunderboltBridge: Bool
    ) -> (result: NWBrowser.Result, interface: NWInterface?)? {
        for result in latestResults {
            if let interface = result.interfaces.first(where: { $0.name == "bridge0" }) {
                return (result, interface)
            }
        }
        guard !requireThunderboltBridge, let result = latestResults.first else { return nil }
        let interface = result.interfaces.first(where: { $0.type == .wiredEthernet }) ?? result.interfaces.first
        return (result, interface)
    }

    private func report(_ choice: (result: NWBrowser.Result, interface: NWInterface?)) {
        guard !reportedReceiver else { return }
        reportedReceiver = true
        let interfaceDescription = choice.interface.map { " via \($0.name)" } ?? ""
        receiverFound?(
            choice.result.endpoint,
            choice.result.endpoint.receiverName + interfaceDescription,
            choice.interface
        )
    }
}

private extension NWEndpoint {
    var receiverName: String {
        switch self {
        case .service(let name, _, _, _):
            return name
        case .hostPort(let host, _):
            return "\(host)"
        default:
            return "receiver"
        }
    }
}
