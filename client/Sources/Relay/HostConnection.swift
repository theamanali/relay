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
        var endpoint: NWEndpoint
        /// Interface to pin the connection to (the cable, when the host was seen on one).
        var interface: NWInterface? = nil
        /// Bonjour instance name, for status messages and the paired-host list.
        var serviceName = ""
        /// Re-dial after a drop (fixed --host mode); the picker flow instead
        /// returns to the host list.
        var reconnects = false
        /// Previously paired identity expected for this discovered host.
        var expectedHostKey: Data? = nil
        /// Forget the pairing on the host instead of streaming: UNPAIR is the
        /// first encrypted message and the connection ends with the reply.
        var unpairOnly = false
        /// Pair (PIN exchange) and then close without starting a stream.
        var pairOnly = false
        /// Run the handshake and close: msg2 alone says whether the host
        /// still has this Mac paired (`pairingVerified`). Nothing is sent
        /// after it, no CLIENT_HELLO, so the host's display and any other
        /// Mac's session are untouched.
        var verifyOnly = false
        var requestedWidth = 0
        var requestedHeight = 0
        var requestedRefresh = 60
        var requestedBitrateMbps = VideoBitrate.defaultValue
        var wantsInput: Bool = true
        var clientName = ""
        /// PIN to use without asking (e.g. from the command line).
        var pin: String? = nil
    }

    weak var delegate: HostConnectionDelegate?
    let queue = DispatchQueue(label: "relay.connection", qos: .userInteractive)

    private let options: Options
    private let identity: Curve25519.KeyAgreement.PrivateKey
    private var connection: NWConnection?
    private var serviceName: String
    /// Interface the current attempt is pinned to (the cable when the host
    /// was seen on one), so a failed attempt can retry unrestricted once.
    private var pinnedInterface: NWInterface?

    // Per-connection security state.
    private var send: SecureChannel?
    private var receive: SecureChannel?
    private var hostKey = Data()
    private var pairing = false
    private var ready = false
    private var nextFrameSequence: UInt64 = 0
    private var reader = FrameReader(maxFrame: Int(Proto.maxPayload) + Proto.headerSize + 16)
    /// Set while a receive is outstanding so drains never overlap.
    private var receiving = false
    /// The host answered UNPAIR, so the pairing is gone on both sides.
    private(set) var hostConfirmedUnpair = false
    /// Pair-only mode finished with both sides knowing each other.
    private(set) var pairingCompleted = false
    /// Verify-only mode read msg2: whether the host still knows this Mac.
    private(set) var pairingVerified: Bool?
    /// The host answered the PIN with a refusal (wrong, or too many tries).
    private(set) var pinRejected = false
    /// With `pinRejected`: the host is not checking PINs at all for this many
    /// seconds (too many wrong ones recently), so retyping is pointless.
    private(set) var pairRetryAfter: Int?
    /// The host answered our CLIENT_HELLO with STREAM_STOP(BUSY): another
    /// client owns the display. Older hosts may send this before our request.
    private(set) var hostBusy = false
    /// Actual bitrate returned by STREAM_START; requested value before that.
    private(set) var activeBitrateMbps: Int
    private var bitrateExceeded = false
    private var stopped = true
    private var attempt: UInt64 = 0
    private var reconnectWorkItem: DispatchWorkItem?

    init(options: Options) throws {
        self.options = options
        self.serviceName = options.serviceName
        self.activeBitrateMbps = options.requestedBitrateMbps
        self.identity = try ClientState.identity()
    }

    // MARK: lifecycle

    func start() {
        queue.async { [self] in
            stopped = false
            connect(to: options.endpoint, via: options.interface)
        }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            attempt &+= 1
            reconnectWorkItem?.cancel()
            reconnectWorkItem = nil
            connection?.stateUpdateHandler = nil
            connection?.cancel()
            connection = nil
            ready = false
            receiving = false
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

    // MARK: connection

    private func connect(to endpoint: NWEndpoint, via interface: NWInterface? = nil) {
        guard !stopped else { return }
        attempt &+= 1
        let thisAttempt = attempt
        reconnectWorkItem?.cancel()
        reconnectWorkItem = nil
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
        hostBusy = false
        nextFrameSequence = 0
        reader.reset()
        receiving = false
        c.stateUpdateHandler = { [weak self] state in
            guard let self, self.isCurrent(c, attempt: thisAttempt) else { return }
            switch state {
            case .ready:
                if let path = c.currentPath {
                    let kind = path.usesInterfaceType(.wiredEthernet) ? "wired Ethernet"
                        : path.usesInterfaceType(.wifi) ? "Wi-Fi" : "other"
                    let names = path.availableInterfaces.map(\.name).joined(separator: ",")
                    NSLog("HostConnection: connected via %@ [%@]", kind, names)
                }
                self.status("Connected, securing…")
                self.startHandshake(c, attempt: thisAttempt)
            case .waiting(let err):
                if self.retryUnpinned(endpoint, c, attempt: thisAttempt, reason: err.localizedDescription) { return }
                self.status("Waiting for host: \(err.localizedDescription)")
            case .failed(let err):
                if self.retryUnpinned(endpoint, c, attempt: thisAttempt, reason: err.localizedDescription) { return }
                self.finish("connection failed: \(err.localizedDescription)", from: c, attempt: thisAttempt)
            case .cancelled:
                self.finish("connection closed", from: c, attempt: thisAttempt)
            default:
                break
            }
        }
        c.start(queue: queue)
    }

    /// A pinned attempt that cannot get through (cable unplugged mid-browse,
    /// host bound elsewhere) is retried once on any interface.
    private func retryUnpinned(_ endpoint: NWEndpoint, _ c: NWConnection, attempt: UInt64, reason: String) -> Bool {
        guard pinnedInterface != nil, isCurrent(c, attempt: attempt) else { return false }
        NSLog("HostConnection: pinned attempt failed (%@); retrying on any interface", reason)
        c.stateUpdateHandler = nil
        c.cancel()
        connection = nil
        connect(to: endpoint, via: nil)
        return true
    }

    private func isCurrent(_ c: NWConnection, attempt: UInt64) -> Bool {
        !stopped && self.attempt == attempt && connection === c
    }

    private func finish(_ reason: String, from expected: NWConnection? = nil, attempt expectedAttempt: UInt64? = nil) {
        guard !stopped, let current = connection else { return }
        if let expected, current !== expected { return }
        if let expectedAttempt, attempt != expectedAttempt { return }
        current.stateUpdateHandler = nil
        current.cancel()
        connection = nil
        ready = false
        receiving = false
        delegate?.connectionDidEnd(self, reason: reason)
        guard options.reconnects, !bitrateExceeded else { return }
        // Fixed-host mode: the host is probably just restarting, re-dial. A
        // busy host answers every attempt with a full handshake, so those
        // are spaced out; it may be our own session still being torn down.
        let finishedAttempt = attempt
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.stopped, self.attempt == finishedAttempt,
                  self.connection == nil else { return }
            self.connect(to: self.options.endpoint, via: self.options.interface)
        }
        reconnectWorkItem = work
        queue.asyncAfter(deadline: .now() + (hostBusy ? Self.busyRetryDelay : 1), execute: work)
    }

    private func status(_ s: String) {
        delegate?.connection(self, didChangeStatus: s)
    }

    // MARK: handshake + pairing

    /// How long after the socket connects the host has to answer message 1.
    /// A host in another session still answers the handshake at once (and
    /// later refuses CLIENT_HELLO), so silence means it is not really there:
    /// a stale Bonjour record, a firewall, a service that is down.
    static let handshakeTimeout: TimeInterval = 10
    /// Re-dial interval in --host mode after a busy answer.
    static let busyRetryDelay: TimeInterval = 5

    private func startHandshake(_ c: NWConnection, attempt: UInt64) {
        guard isCurrent(c, attempt: attempt) else { return }
        let pending = Handshake.Pending(identity: identity)
        queue.asyncAfter(deadline: .now() + Self.handshakeTimeout) { [weak self] in
            guard let self, self.isCurrent(c, attempt: attempt), self.send == nil else { return }
            self.finish("the PC didn't answer", from: c, attempt: attempt)
        }
        var frame = Data()
        frame.appendBE32(UInt32(pending.message1.count))
        frame.append(pending.message1)
        c.send(content: frame, completion: .contentProcessed { [weak self] err in
            guard let self, self.isCurrent(c, attempt: attempt) else { return }
            if let err { self.finish("send failed: \(err.localizedDescription)", from: c, attempt: attempt) }
        })
        readFrame(c, attempt: attempt) { [weak self] body in
            guard let self, self.isCurrent(c, attempt: attempt) else { return }
            do {
                let result = try pending.complete(message2: body, expectedHost: self.options.expectedHostKey)
                self.send = SecureChannel(key: result.keys.clientToHost)
                self.receive = SecureChannel(key: result.keys.hostToClient)
                self.hostKey = result.hostKey
                let fp = fingerprint(result.hostKey)
                if self.options.unpairOnly {
                    self.status("Forgetting \(self.serviceName)…")
                    self.sendRaw(Proto.message(.unpair))
                    self.readMessage(c, attempt: attempt)
                    return
                }
                if self.options.verifyOnly {
                    // The answer was msg2's `paired` byte; nothing else to say.
                    self.pairingVerified = result.paired
                    self.finish(result.paired ? "still paired" : "the PC forgot this MacBook", from: c, attempt: attempt)
                    return
                }
                let known = ClientState.knownHosts()[result.hostKey] != nil
                if self.options.pairOnly {
                    // An explicit Pair asks for the PIN when the host does not
                    // know us or we do not know it (lost hosts.txt); a host
                    // both sides know needs nothing more.
                    if !result.paired || !known {
                        self.pairing = true
                        self.askForPIN(fingerprint: fp, keys: result.keys, connection: c, attempt: attempt)
                    } else {
                        self.pairingCompleted = true
                        self.finish("already paired", from: c, attempt: attempt)
                        return
                    }
                } else if !known {
                    // Connect to a host we have no record of (--host, a lost
                    // hosts.txt): pair first. The host takes a PIN from a
                    // client it already knows too.
                    self.pairing = true
                    self.askForPIN(fingerprint: fp, keys: result.keys, connection: c, attempt: attempt)
                } else if !result.paired {
                    // The PC forgot us since we paired. A plain Connect does
                    // not re-pair on its own: drop our half as well, so the
                    // row moves to Available, where Pair asks for the PIN.
                    ClientState.forget(host: result.hostKey)
                    self.finish("the PC forgot this MacBook", from: c, attempt: attempt)
                    return
                } else {
                    self.status("Secure channel to \(fp)")
                }
                // The host greets first; everything after this is encrypted.
                self.readMessage(c, attempt: attempt)
            } catch {
                self.finish("handshake failed: \(error.localizedDescription)", from: c, attempt: attempt)
            }
        }
    }

    private func askForPIN(fingerprint fp: String, keys: SessionKeys, connection c: NWConnection, attempt: UInt64) {
        let host = serviceName.isEmpty ? fp : serviceName
        let deliver: (String?) -> Void = { [weak self] pin in
            self?.queue.async {
                guard let self, self.isCurrent(c, attempt: attempt) else { return }
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
            bitrateMbps: options.requestedBitrateMbps,
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
    private func readFrame(_ c: NWConnection, attempt: UInt64, _ handler: @escaping (Data) -> Void) {
        guard isCurrent(c, attempt: attempt) else { return }
        do {
            if let body = try reader.next() {
                handler(body)
                return
            }
        } catch {
            finish("protocol error: \(error)")
            return
        }
        receiveMore(c, attempt: attempt) { [weak self] in
            self?.readFrame(c, attempt: attempt, handler)
        }
    }

    /// One read sized to complete the current frame (header or body), so a
    /// small message lands in a single callback and a large keyframe waits in
    /// the framework instead of arriving as many small pieces.
    private func receiveMore(_ c: NWConnection, attempt: UInt64, _ then: @escaping () -> Void) {
        guard isCurrent(c, attempt: attempt), !receiving else { return }
        receiving = true
        let needed = reader.needed
        c.receive(minimumIncompleteLength: needed, maximumLength: max(needed, 256 * 1024)) { [weak self] data, _, isComplete, error in
            guard let self, self.isCurrent(c, attempt: attempt) else { return }
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
    private func readMessage(_ c: NWConnection, attempt: UInt64) {
        while isCurrent(c, attempt: attempt) {
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
        guard isCurrent(c, attempt: attempt) else { return }
        receiveMore(c, attempt: attempt) { [weak self] in
            self?.readMessage(c, attempt: attempt)
        }
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
            if options.unpairOnly { return }
            if !pairing {
                ClientState.remember(host: hostKey, name: name)
                status("Connected to \(name)")
                sendClientHello()
            }

        case .pairResult:
            guard pairing else { return }
            pairing = false
            switch Proto.PairResult(payload) {
            case .paired:
                ClientState.remember(host: hostKey, name: serviceName)
                status("Paired with \(serviceName)")
                if options.pairOnly {
                    pairingCompleted = true
                    finish("paired")
                } else {
                    sendClientHello()
                }
            case .rateLimited(let seconds):
                pinRejected = true
                pairRetryAfter = seconds
                finish("too many wrong PINs — the host accepts none for \(seconds) s")
            case .wrongPIN, .rejected:
                pinRejected = true
                finish("the host rejected the PIN")
            }

        case .streamStart:
            guard let start = Proto.StreamStart(payload) else { return finish("malformed STREAM_START") }
            activeBitrateMbps = start.bitrateMbps
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
            switch reason {
            case 4:
                // The PC forgot this Mac while it was streaming (its tray's
                // Forget sends the Mac away as not paired): drop our half too.
                ClientState.forget(host: hostKey)
                finish("the host does not know this MacBook (pair with its PIN)")
            case 5:
                hostConfirmedUnpair = true
                finish("the host forgot this MacBook")
            case 6:
                // Current hosts send this in reply to CLIENT_HELLO. Older
                // hosts sent it immediately after SERVER_HELLO, including
                // while our PIN prompt was open, so keep handling it anywhere.
                hostBusy = true
                finish("the PC is in another session")
            case 7:
                bitrateExceeded = true
                finish("connection couldn't sustain \(activeBitrateMbps) Mbps — choose a lower bitrate")
            default: finish("host stopped the stream (reason \(reason))")
            }

        case .cursor:
            break // cursor is composited into the video for now

        default:
            break
        }
    }
}
