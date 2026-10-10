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
        /// Give up if no attempt has connected this long after `start()`.
        /// A PC that is gone leaves the dial preparing or waiting for ever
        /// (Network.framework only times out a SYN it has sent); the picker
        /// wants an answer, --host mode keeps waiting and re-dials.
        var dialTimeout: TimeInterval? = nil
        /// Forget the pairing on the host instead of streaming: UNPAIR is the
        /// first encrypted message and the connection ends with the reply.
        var unpairOnly = false
        /// Pair (PIN exchange) and then close without starting a stream.
        var pairOnly = false
        /// Run the handshake and close: SERVER_HELLO's `paired` says whether
        /// the host still has this Mac paired (`pairingVerified`). Nothing is
        /// sent after msg3, no CLIENT_HELLO, so the host's display and any
        /// other Mac's session are untouched.
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
    /// Noise's handshake hash: CPace binds the PIN exchange to it.
    private var handshakeHash = Data()
    /// SERVER_HELLO has arrived (the handshake timeout runs until it does).
    private var greeted = false
    private var supportsPairName = false
    private var pairing = false
    /// Our half of the PIN exchange, from PAIR until PAIR_REPLY.
    private var cpace: CPaceInitiator?
    private var ready = false
    private var nextFrameSequence: UInt64 = 0
    /// Every frame on the wire is a handshake message or one record, so none
    /// is longer than Noise's largest message.
    private var reader = FrameReader(maxFrame: SecureChannel.maxRecord)
    /// Set while a receive is outstanding so drains never overlap.
    private var receiving = false
    /// The host answered UNPAIR, so the pairing is gone on both sides.
    private(set) var hostConfirmedUnpair = false
    /// Pair-only mode finished with both sides knowing each other.
    private(set) var pairingCompleted = false
    /// Verify-only mode read SERVER_HELLO: whether the host still knows this Mac.
    private(set) var pairingVerified: Bool?
    /// Some attempt reached the socket-connected state: the PC was there,
    /// whatever happened next. Never set means it could not be reached at
    /// all, and its Bonjour record may be stale.
    private(set) var everConnected = false
    /// The PIN was refused: it did not match the host's (we see that from
    /// PAIR_REPLY), or the host is refusing PINs after too many tries.
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
            if let limit = options.dialTimeout {
                // One deadline for the whole dial, pinned attempt and its
                // unpinned retry together.
                queue.asyncAfter(deadline: .now() + limit) { [weak self] in
                    guard let self, !self.stopped, !self.everConnected else { return }
                    self.finish("couldn't reach the PC in \(Int(limit)) s")
                }
            }
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
        handshakeHash = Data()
        greeted = false
        supportsPairName = false
        pairing = false
        cpace = nil
        hostBusy = false
        nextFrameSequence = 0
        reader.reset()
        receiving = false
        c.stateUpdateHandler = { [weak self] state in
            guard let self, self.isCurrent(c, attempt: thisAttempt) else { return }
            switch state {
            case .ready:
                self.everConnected = true
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

    /// How long after the socket connects the host has to get through the
    /// handshake to SERVER_HELLO. A host in another session still answers at
    /// once (and later refuses CLIENT_HELLO), so silence means it is not
    /// really there: a stale Bonjour record, a firewall, a service that is
    /// down, or a PC on an older protocol that hangs up.
    static let handshakeTimeout: TimeInterval = 10
    /// Re-dial interval in --host mode after a busy answer.
    static let busyRetryDelay: TimeInterval = 5

    /// Noise XX: msg1 ("RLY4" + e), read msg2 (the host's identity), check
    /// it, msg3 (ours). Then everything is records, and the host greets
    /// with SERVER_HELLO, where the pairing decisions are made.
    private func startHandshake(_ c: NWConnection, attempt: UInt64) {
        guard isCurrent(c, attempt: attempt) else { return }
        let noise = Handshake.initiator(identity: identity)
        queue.asyncAfter(deadline: .now() + Self.handshakeTimeout) { [weak self] in
            guard let self, self.isCurrent(c, attempt: attempt), !self.greeted else { return }
            self.finish("the PC didn't answer", from: c, attempt: attempt)
        }
        do {
            sendFrame(Handshake.magic + (try noise.writeMessage()), c, attempt: attempt)
        } catch {
            return finish("handshake failed: \(error.localizedDescription)", from: c, attempt: attempt)
        }
        readFrame(c, attempt: attempt) { [weak self] body in
            guard let self, self.isCurrent(c, attempt: attempt) else { return }
            do {
                guard body.count == Handshake.message2Length else {
                    throw CryptoError.badHello("not a Relay v4 handshake (msg2 of \(body.count) bytes)")
                }
                _ = try noise.readMessage(body)
                guard let hostStatic = noise.remoteStatic else { throw CryptoError.malformed }
                if let expected = self.options.expectedHostKey, expected != hostStatic {
                    // Close before msg3: a PC with another key never learns ours.
                    throw CryptoError.hostChanged(expected: fingerprint(expected), got: fingerprint(hostStatic))
                }
                self.sendFrame(try noise.writeMessage(), c, attempt: attempt)
                let (send, receive) = try noise.split()
                self.send = SecureChannel(cipher: send)
                self.receive = SecureChannel(cipher: receive)
                self.hostKey = hostStatic
                self.handshakeHash = noise.handshakeHash
                if self.options.unpairOnly {
                    // UNPAIR may follow msg3 at once; the host greets, then answers it.
                    self.status("Forgetting \(self.serviceName)…")
                    self.sendRaw(Proto.message(.unpair))
                }
                self.readMessage(c, attempt: attempt)
            } catch {
                self.finish("handshake failed: \(error.localizedDescription)", from: c, attempt: attempt)
            }
        }
    }

    /// One cleartext handshake message with its u32 length.
    private func sendFrame(_ body: Data, _ c: NWConnection, attempt: UInt64) {
        var frame = Data(capacity: 4 + body.count)
        frame.appendBE32(UInt32(body.count))
        frame.append(body)
        c.send(content: frame, completion: .contentProcessed { [weak self] err in
            guard let self, self.isCurrent(c, attempt: attempt) else { return }
            if let err { self.finish("send failed: \(err.localizedDescription)", from: c, attempt: attempt) }
        })
    }

    /// SERVER_HELLO says whether the host knows this Mac; with what we know
    /// about the host, that decides what this connection does next.
    private func handleServerHello(_ hello: Proto.ServerHello) {
        greeted = true
        supportsPairName = hello.supportsPairName
        if !hello.name.isEmpty { serviceName = hello.name }
        if options.unpairOnly { return } // UNPAIR is already on its way
        if options.verifyOnly {
            pairingVerified = hello.paired
            return finish(hello.paired ? "still paired" : "the PC forgot this MacBook")
        }
        let known = ClientState.knownHosts()[hostKey] != nil
        if options.pairOnly {
            // An explicit Pair asks for the PIN when the host does not know
            // us or we do not know it (lost hosts.txt); a host both sides
            // know needs nothing more.
            if hello.paired && known {
                pairingCompleted = true
                return finish("already paired")
            }
            askForPIN()
        } else if !known {
            // Connect to a host we have no record of (--host, a lost
            // hosts.txt): pair first. The host takes a PIN from a client it
            // already knows too.
            askForPIN()
        } else if !hello.paired {
            // The PC forgot us since we paired. A plain Connect does not
            // re-pair on its own: drop our half as well, so the row moves to
            // Available, where Pair asks for the PIN.
            ClientState.forget(host: hostKey)
            finish("the PC forgot this MacBook")
        } else {
            ClientState.remember(host: hostKey, name: hello.name)
            status("Connected to \(hello.name)")
            sendClientHello()
        }
    }

    /// Get the PIN (command line or the sheet), then open CPace with PAIR.
    /// The host's PAIR_REPLY proves it knows the same PIN before we confirm.
    private func askForPIN() {
        guard let c = connection else { return }
        let attempt = self.attempt
        pairing = true
        let fp = fingerprint(hostKey)
        let host = serviceName.isEmpty ? fp : serviceName
        let deliver: (String?) -> Void = { [weak self] pin in
            self?.queue.async {
                guard let self, self.isCurrent(c, attempt: attempt) else { return }
                guard let pin, !pin.isEmpty else {
                    self.finish("pairing cancelled")
                    return
                }
                do {
                    let ci = CPace.channelIdentifier(clientStatic: self.identity.publicKey.rawRepresentation,
                                                     hostStatic: self.hostKey)
                    let ad = self.supportsPairName ? Proto.pairNameAD(self.options.clientName) : Data()
                    let cpace = try CPaceInitiator(prs: Data(pin.utf8), ci: ci, sid: self.handshakeHash, ad: ad)
                    self.cpace = cpace
                    self.status("Pairing with \(host)…")
                    self.sendRaw(Proto.message(.pair, payload: cpace.share + ad))
                } catch {
                    self.finish("pairing failed: \(error.localizedDescription)")
                }
            }
        }
        if let pin = options.pin {
            deliver(pin)
        } else {
            status("\(host) needs its pairing PIN")
            delegate?.connection(self, needsPINFor: host, fingerprint: fp, completion: deliver)
        }
    }

    /// PAIR_REPLY: the host's share and tag. A tag that does not check out
    /// means the PINs differ (or the PC is not who it claims; the two look
    /// the same), and we close without confirming. The host has already
    /// counted the attempt.
    private func pairReplied(_ payload: Data) {
        guard let cpace else { return finish("unexpected PAIR_REPLY") }
        self.cpace = nil
        guard payload.count == 64 else { return finish("malformed PAIR_REPLY") }
        do {
            let (_, tag) = try cpace.finish(peerShare: Data(payload.prefix(32)), peerTag: Data(payload.suffix(32)))
            sendRaw(Proto.message(.pairConfirm, payload: tag))
        } catch CPaceError.confirmationFailed {
            pinRejected = true
            finish("the PIN didn't match the PC's")
        } catch {
            finish("pairing failed: \(error.localizedDescription)")
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
    /// otherwise after the next read. Used for the cleartext msg2.
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

    /// One read sized to complete the current message, so a small message
    /// lands in a single callback and a large keyframe waits in the framework
    /// instead of arriving as many small pieces. Until a message's first
    /// record is in, that is the rest of the record; after it, the header
    /// gives the size of the rest.
    private func receiveMore(_ c: NWConnection, attempt: UInt64, _ then: @escaping () -> Void) {
        guard isCurrent(c, attempt: attempt), !receiving else { return }
        receiving = true
        let needed = max(reader.needed, (receive?.remainingWireBytes ?? 0) - reader.buffered)
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
                // A PC on protocol v3 or older reads msg1, cannot parse it and
                // hangs up before msg2.
                self.finish(self.send == nil ? "the PC hung up during the handshake (it may need the latest Relay)"
                                             : "host closed the connection")
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
                guard let record = try reader.next() else { break }
                guard let (header, payload) = try receive.open(record) else { continue }
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
            guard !greeted else { return }
            guard payload.count >= 2 else { return finish("malformed SERVER_HELLO") }
            let version = payload.be16(at: 0)
            guard version == Proto.version else {
                return finish("host speaks protocol v\(version), this client v\(Proto.version)")
            }
            guard let hello = Proto.ServerHello(payload) else { return finish("malformed SERVER_HELLO") }
            handleServerHello(hello)

        case .pairReply:
            guard pairing else { return }
            pairReplied(payload)

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
