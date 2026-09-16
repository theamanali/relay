// Finds the host over Bonjour (or a fixed address), runs the handshake and
// pairing, then speaks the encrypted wire protocol and hands decoded-ready
// payloads to a delegate. All callbacks arrive on `queue`; the delegate hops to
// the main thread where it needs to.

import CryptoKit
import CoreMedia
import Foundation
import Network

protocol HostConnectionDelegate: AnyObject {
    func connection(_ c: HostConnection, didChangeStatus status: String)
    /// A host we have not paired with (or that forgot us) needs the PIN it
    /// displays. Call `completion(nil)` to give up.
    func connection(_ c: HostConnection, needsPINFor host: String, fingerprint: String, completion: @escaping (String?) -> Void)
    func connection(_ c: HostConnection, didStart stream: Proto.StreamStart)
    func connection(_ c: HostConnection, didReceiveCodecConfig parameterSets: [Data])
    func connection(_ c: HostConnection, didReceiveFrame nalUnits: Data, keyframe: Bool, sequence: UInt64, receivedAt: CMTime)
    func connection(_ c: HostConnection, didReceiveFrameTiming timing: Proto.FrameTiming)
    func connectionDidEnd(_ c: HostConnection, reason: String)
}

final class HostConnection {
    struct Options {
        var fixedHost: NWEndpoint? = nil
        var requestedWidth: Int
        var requestedHeight: Int
        var requestedRefresh: Int
        var wantsInput: Bool = true
        var clientName: String
        /// PIN to use without asking (e.g. from the command line).
        var pin: String? = nil
    }

    weak var delegate: HostConnectionDelegate?
    let queue = DispatchQueue(label: "traveldisplay.connection", qos: .userInteractive)

    private let options: Options
    private let identity: Curve25519.KeyAgreement.PrivateKey
    private var browser: NWBrowser?
    private var connection: NWConnection?
    private var serviceName = ""
    /// Interface the current attempt is pinned to (the cable when the host
    /// was seen on one), so a failed attempt can retry unrestricted once.
    private var pinnedInterface: NWInterface?

    // Per-connection security state.
    private var pending: Handshake.Pending?
    private var send: SecureChannel?
    private var receive: SecureChannel?
    private var hostKey = Data()
    private var pairing = false
    private var ready = false
    private var nextFrameSequence: UInt64 = 0
    private var reader = FrameReader(maxFrame: Int(Proto.maxPayload) + Proto.headerSize + 16)
    /// Set while a receive is outstanding so drains never overlap.
    private var receiving = false

    init(options: Options) throws {
        self.options = options
        self.identity = try ClientState.identity()
    }

    // MARK: lifecycle

    func start() {
        queue.async { [self] in
            if let endpoint = options.fixedHost {
                connect(to: endpoint)
            } else {
                browse()
            }
        }
    }

    func stop() {
        queue.async { [self] in
            browser?.cancel()
            browser = nil
            connection?.cancel()
            connection = nil
        }
    }

    /// Send a protocol message (already built by `Proto`) once the session is up.
    func send(_ message: Data) {
        queue.async { [self] in
            guard ready else { return }
            sendRaw(message)
        }
    }

    private func sendRaw(_ message: Data) {
        guard let c = connection, let send else { return }
        do {
            c.send(content: try send.seal(message), completion: .contentProcessed { _ in })
        } catch {
            finish("encryption failed: \(error.localizedDescription)")
        }
    }

    // MARK: discovery

    private func browse() {
        status("Looking for a TravelDisplay host…")
        let params = NWParameters()
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: Proto.serviceType, domain: nil), using: params)
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let err) = state {
                self?.status("Bonjour browse failed: \(err.localizedDescription) — retrying")
                self?.queue.asyncAfter(deadline: .now() + 2) { self?.browse() }
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self, self.connection == nil, let first = results.first else { return }
            if case .service(let name, _, _, _) = first.endpoint {
                self.serviceName = name
                self.status("Found \(name), connecting…")
            }
            self.browser?.cancel()
            self.browser = nil
            // A Mac on hotel Wi-Fi with the cable to the PC sees the host on
            // both; pin to wired Ethernet so the cable is the path. Wi-Fi-only
            // and same-LAN setups are unaffected (nothing wired, or only the
            // wired LAN interface).
            let wired = first.interfaces.first { $0.type == .wiredEthernet }
            self.connect(to: first.endpoint, via: wired)
        }
        self.browser = browser
        browser.start(queue: queue)
    }

    // MARK: connection

    private func connect(to endpoint: NWEndpoint, via interface: NWInterface? = nil) {
        pinnedInterface = interface
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 5
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        tcp.keepaliveInterval = 1
        tcp.keepaliveCount = 3
        let params = NWParameters(tls: nil, tcp: tcp)
        params.includePeerToPeer = true
        if let interface {
            params.requiredInterface = interface
            NSLog("HostConnection: pinning to %@ (%@)", interface.name, String(describing: interface.type))
        }

        let c = NWConnection(to: endpoint, using: params)
        connection = c
        ready = false
        send = nil
        receive = nil
        pairing = false
        nextFrameSequence = 0
        reader.reset()
        receiving = false
        c.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if let path = c.currentPath {
                    let kind = path.usesInterfaceType(.wiredEthernet) ? "wired Ethernet"
                        : path.usesInterfaceType(.wifi) ? "Wi-Fi" : "other"
                    let names = path.availableInterfaces.map(\.name).joined(separator: ",")
                    NSLog("HostConnection: connected via %@ [%@]", kind, names)
                }
                self.status("Connected, securing…")
                self.startHandshake()
            case .waiting(let err):
                if self.retryUnpinned(endpoint, c, reason: err.localizedDescription) { return }
                self.status("Waiting for host: \(err.localizedDescription)")
            case .failed(let err):
                if self.retryUnpinned(endpoint, c, reason: err.localizedDescription) { return }
                self.finish("connection failed: \(err.localizedDescription)")
            case .cancelled:
                self.finish("connection closed")
            default:
                break
            }
        }
        c.start(queue: queue)
    }

    /// A pinned attempt that cannot get through (cable unplugged mid-browse,
    /// host bound elsewhere) is retried once on any interface.
    private func retryUnpinned(_ endpoint: NWEndpoint, _ c: NWConnection, reason: String) -> Bool {
        guard pinnedInterface != nil, connection === c else { return false }
        NSLog("HostConnection: pinned attempt failed (%@); retrying on any interface", reason)
        c.stateUpdateHandler = nil
        c.cancel()
        connection = nil
        connect(to: endpoint, via: nil)
        return true
    }

    private func finish(_ reason: String) {
        guard connection != nil else { return }
        connection?.cancel()
        connection = nil
        ready = false
        delegate?.connectionDidEnd(self, reason: reason)
        // Go back to looking for a host; the host is probably just restarting.
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.connection == nil else { return }
            if let fixed = self.options.fixedHost {
                self.connect(to: fixed)
            } else {
                self.browse()
            }
        }
    }

    private func status(_ s: String) {
        delegate?.connection(self, didChangeStatus: s)
    }

    // MARK: handshake + pairing

    private func startHandshake() {
        guard let c = connection else { return }
        let pending = Handshake.Pending(identity: identity)
        self.pending = pending
        var frame = Data()
        frame.appendBE32(UInt32(pending.message1.count))
        frame.append(pending.message1)
        c.send(content: frame, completion: .contentProcessed { [weak self] err in
            if let err { self?.finish("send failed: \(err.localizedDescription)") }
        })
        readFrame { [weak self] body in
            guard let self else { return }
            do {
                let result = try pending.complete(message2: body)
                self.pending = nil
                self.send = SecureChannel(key: result.keys.clientToHost)
                self.receive = SecureChannel(key: result.keys.hostToClient)
                self.hostKey = result.hostKey
                let fp = fingerprint(result.hostKey)
                // Pair when the host does not know us, or we do not know the host
                // (lost hosts.txt); a host we both know needs nothing more.
                let known = ClientState.knownHosts()[result.hostKey] != nil
                if !result.paired || !known {
                    self.pairing = true
                    self.askForPIN(fingerprint: fp, keys: result.keys)
                } else {
                    self.status("Secure channel to \(fp)")
                }
                // The host greets first; everything after this is encrypted.
                self.readMessage()
            } catch {
                self.finish("handshake failed: \(error.localizedDescription)")
            }
        }
    }

    private func askForPIN(fingerprint fp: String, keys: SessionKeys) {
        let host = serviceName.isEmpty ? fp : serviceName
        let deliver: (String?) -> Void = { [weak self] pin in
            self?.queue.async {
                guard let self, self.connection != nil else { return }
                guard let pin, !pin.isEmpty else {
                    self.finish("pairing cancelled")
                    return
                }
                self.status("Pairing with \(host)…")
                self.sendRaw(Proto.message(.pair, payload: Handshake.pinProof(keys.pair, pin: pin)))
            }
        }
        if let pin = options.pin {
            deliver(pin)
        } else {
            status("\(host) needs its pairing PIN")
            delegate?.connection(self, needsPINFor: host, fingerprint: fp, completion: deliver)
        }
    }

    private func sendClientHello() {
        let hello = Proto.clientHello(
            width: options.requestedWidth,
            height: options.requestedHeight,
            refresh: options.requestedRefresh,
            wantsInput: options.wantsInput,
            codecs: Proto.Codec.hevc.bit | Proto.Codec.h264.bit,
            name: options.clientName
        )
        sendRaw(hello)
        ready = true
    }

    // MARK: receive loop

    /// Deliver one frame body: from the buffer if it is already there,
    /// otherwise after the next read. Used for the unencrypted handshake reply.
    private func readFrame(_ handler: @escaping (Data) -> Void) {
        do {
            if let body = try reader.next() {
                handler(body)
                return
            }
        } catch {
            finish("protocol error: \(error)")
            return
        }
        receiveMore { [weak self] in self?.readFrame(handler) }
    }

    /// One read sized to complete the current frame (header or body), so a
    /// small message lands in a single callback and a large keyframe waits in
    /// the framework instead of arriving as many small pieces.
    private func receiveMore(_ then: @escaping () -> Void) {
        guard let c = connection, !receiving else { return }
        receiving = true
        let needed = reader.needed
        c.receive(minimumIncompleteLength: needed, maximumLength: max(needed, 256 * 1024)) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.receiving = false
            if let error {
                self.finish("read error: \(error.localizedDescription)")
                return
            }
            if let data, !data.isEmpty {
                self.reader.append(data)
                then()
            } else if isComplete {
                self.finish("host closed the connection")
            } else {
                then()
            }
        }
    }

    /// Handle every complete encrypted message already buffered, then read.
    private func readMessage() {
        while connection != nil {
            guard let receive else { return }
            do {
                guard let body = try reader.next() else { break }
                let (header, payload) = try receive.open(body)
                handle(type: header.type, flags: header.flags, payload: payload)
            } catch let failure as FrameReader.Failure {
                finish("protocol error: \(failure)")
                return
            } catch {
                finish("secure channel error: \(error.localizedDescription)")
                return
            }
        }
        guard connection != nil else { return }
        receiveMore { [weak self] in self?.readMessage() }
    }

    private func handle(type: UInt8, flags: UInt8, payload: Data) {
        guard let msg = Proto.Msg(rawValue: type) else {
            return // unknown message types are ignored by design
        }
        switch msg {
        case .serverHello:
            guard payload.count >= 3 else { return finish("malformed SERVER_HELLO") }
            let version = payload.be16(at: 0)
            let nameLen = Int(payload[payload.startIndex + 2])
            let name = String(decoding: payload.dropFirst(3).prefix(nameLen), as: UTF8.self)
            guard version == Proto.version else {
                return finish("host speaks protocol v\(version), this client v\(Proto.version)")
            }
            if !name.isEmpty { serviceName = name }
            if !pairing {
                ClientState.remember(host: hostKey, name: name)
                status("Connected to \(name)")
                sendClientHello()
            }

        case .pairResult:
            guard pairing else { return }
            pairing = false
            if payload.first == 1 {
                ClientState.remember(host: hostKey, name: serviceName)
                status("Paired with \(serviceName)")
                sendClientHello()
            } else {
                finish("the host rejected the PIN")
            }

        case .streamStart:
            guard let start = Proto.StreamStart(payload) else { return finish("malformed STREAM_START") }
            delegate?.connection(self, didStart: start)

        case .codecConfig:
            delegate?.connection(self, didReceiveCodecConfig: Proto.nalUnits(in: payload))

        case .frame:
            let sequence = nextFrameSequence
            nextFrameSequence &+= 1
            delegate?.connection(
                self,
                didReceiveFrame: payload,
                keyframe: flags & Proto.flagKeyframe != 0,
                sequence: sequence,
                receivedAt: CMClockGetTime(CMClockGetHostTimeClock())
            )

        case .frameTiming:
            guard let timing = Proto.FrameTiming(payload) else {
                return finish("malformed FRAME_TIMING")
            }
            delegate?.connection(self, didReceiveFrameTiming: timing)

        case .ping:
            sendRaw(Proto.pong(payload))

        case .streamStop:
            let reason = payload.first.map { Int($0) } ?? -1
            finish(reason == 4 ? "the host does not know this Mac (pair with its PIN)" : "host stopped the stream (reason \(reason))")

        case .cursor:
            break // cursor is composited into the video for now

        default:
            break
        }
    }
}
