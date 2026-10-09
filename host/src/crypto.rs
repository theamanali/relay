//! Pairing and transport security, protocol v4. See docs/PROTOCOL.md,
//! "Handshake and pairing" and "Records".
//!
//! Model: each side has a long-lived X25519 identity. Every connection runs
//! Noise_XX_25519_ChaChaPoly_SHA256 (Noise revision 34), which carries both
//! identity keys encrypted and gives fresh, forward-secret transport keys.
//! The first time a client connects it proves the host's PIN with CPace
//! inside that channel (`crate::cpace`) and the host proves it back; the host
//! then remembers the client's identity key and the client remembers the
//! host's, and every later connection is authenticated by those keys alone.
//!
//! Handshake (cleartext; each body is prefixed by a u32 BE length):
//!
//! ```text
//! msg1  C->H  "RLY4" | -> e                       36 bytes
//! msg2  H->C  <- e, ee, s, es                     96 bytes
//! msg3  C->H  -> s, se                            64 bytes
//! ```
//!
//! The prologue is "RLY4" and every handshake payload is empty. Afterwards a
//! protocol message (8-byte header + payload) travels as one or more records,
//! each `u32 BE length || Noise transport message` carrying at most 65,519
//! bytes of it; the nonce is a per-direction counter from 0.

use std::collections::HashMap;
use std::fmt;
use std::fs;
use std::io::{self, Read, Write};
use std::net::TcpStream;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Context, Result};
use rand::rngs::OsRng;
use rand::RngCore;
use sha2::{Digest, Sha256};
use snow::{Builder, HandshakeState, StatelessTransportState};
use x25519_dalek::{PublicKey, StaticSecret};

use crate::cpace;
use crate::protocol::{self, msg, pair_result, stop_reason, MAX_PAYLOAD};

/// The Noise prologue, also sent in the clear in front of msg1.
const PROLOGUE: &[u8; 4] = b"RLY4";
const NOISE_PARAMS: &str = "Noise_XX_25519_ChaChaPoly_SHA256";
const MSG1_LEN: usize = 4 + 32;
const MSG2_LEN: usize = 32 + (32 + TAG_LEN) + TAG_LEN;
const MSG3_LEN: usize = (32 + TAG_LEN) + TAG_LEN;
/// The first message of the v2 handshake (protocol v3, the Mac app before v4):
/// "TDH2", u16 version, two keys.
const V2_MAGIC: &[u8; 4] = b"TDH2";
const V2_MSG1_LEN: usize = 70;
const TAG_LEN: usize = 16;
/// Noise's largest message, and so the longest record on the wire.
const MAX_RECORD: usize = 65_535;
/// The most of a protocol message one record carries.
pub const MAX_RECORD_PLAINTEXT: usize = MAX_RECORD - TAG_LEN;

/// Failed PIN attempts allowed per window before pairing is refused outright.
const PAIR_FAILS_ALLOWED: usize = 5;
const PAIR_FAIL_WINDOW: Duration = Duration::from_secs(10 * 60);

pub type Key32 = [u8; 32];

// ---------------------------------------------------------------------------
// Identity and pairing state on disk
// ---------------------------------------------------------------------------

/// Long-lived X25519 identity.
pub struct Identity {
    secret: StaticSecret,
    pub public: PublicKey,
}

impl Identity {
    pub fn generate() -> Self {
        let secret = StaticSecret::random_from_rng(OsRng);
        let public = PublicKey::from(&secret);
        Identity { secret, public }
    }

    pub fn from_bytes(bytes: Key32) -> Self {
        let secret = StaticSecret::from(bytes);
        let public = PublicKey::from(&secret);
        Identity { secret, public }
    }

    /// Load the identity from `path`, creating and saving a new one if absent.
    pub fn load_or_create(path: &Path) -> Result<Self> {
        if let Ok(bytes) = fs::read(path) {
            let key: Key32 = bytes
                .as_slice()
                .try_into()
                .map_err(|_| anyhow!("{} is not a 32-byte key", path.display()))?;
            return Ok(Self::from_bytes(key));
        }
        let id = Self::generate();
        if let Some(dir) = path.parent() {
            fs::create_dir_all(dir)?;
        }
        fs::write(path, id.secret.to_bytes())
            .with_context(|| format!("writing {}", path.display()))?;
        log::info!(
            "created identity {} ({})",
            fingerprint(id.public.as_bytes()),
            path.display()
        );
        Ok(id)
    }

    /// Noise allows an all-zero DH result and snow does not refuse one, but
    /// Relay always has (so does the Mac's Noise.swift). The result is zero
    /// exactly when the peer's key is a low-order point, which X25519 with
    /// any of our scalars shows; checking every key the peer sends covers
    /// each DH of the handshake.
    fn refuse_low_order(&self, peer_key: &[u8], what: &str) -> Result<()> {
        let key: Key32 = peer_key
            .try_into()
            .map_err(|_| anyhow!("{what} is not 32 bytes"))?;
        cpace::scalar_mult_vfy(&self.secret.to_bytes(), &key)
            .map(|_| ())
            .map_err(|_| anyhow!("{what} is a low-order point"))
    }
}

/// Short human-checkable form of a public key.
pub fn fingerprint(public: &Key32) -> String {
    let digest = Sha256::digest(public);
    hex::encode_upper(&digest[..4])
}

/// Domain separation for `PeerList::digest` (part of the wire contract, see
/// docs/PROTOCOL.md).
pub const DIGEST_LABEL: &[u8] = b"relay-pairing-digest-v1";

/// The clients (or hosts) this side has paired with: key -> name.
pub struct PeerList {
    path: PathBuf,
    peers: HashMap<Key32, String>,
    /// The file's modification time as of our last read or write, so
    /// `reload_if_changed` can tell another process's edit (`relay-host
    /// paired --forget` from a terminal) from our own.
    seen_mtime: Option<std::time::SystemTime>,
}

impl PeerList {
    pub fn load(path: &Path) -> Result<Self> {
        Ok(PeerList {
            path: path.to_path_buf(),
            peers: Self::read(path),
            seen_mtime: Self::mtime(path),
        })
    }

    fn read(path: &Path) -> HashMap<Key32, String> {
        let mut peers = HashMap::new();
        if let Ok(text) = fs::read_to_string(path) {
            for line in text.lines() {
                let mut parts = line.splitn(2, ' ');
                let (Some(hexkey), name) = (parts.next(), parts.next().unwrap_or("")) else {
                    continue;
                };
                if let Ok(bytes) = hex::decode(hexkey) {
                    if let Ok(key) = <Key32>::try_from(bytes.as_slice()) {
                        peers.insert(key, name.to_string());
                    }
                }
            }
        }
        peers
    }

    fn mtime(path: &Path) -> Option<std::time::SystemTime> {
        fs::metadata(path).and_then(|m| m.modified()).ok()
    }

    /// Pick up an edit made to the file by someone else since we last read
    /// or wrote it. True when the list was replaced.
    pub fn reload_if_changed(&mut self) -> bool {
        let now = Self::mtime(&self.path);
        if now == self.seen_mtime {
            return false;
        }
        self.peers = Self::read(&self.path);
        self.seen_mtime = now;
        true
    }

    /// What is advertised as `pg`: the first 4 bytes of SHA-256 over
    /// `DIGEST_LABEL` and the paired keys, sorted and concatenated, as hex.
    /// It moves whenever a client is paired or forgotten (not renamed) and
    /// says nothing about who is on the list (the label keeps a one-client
    /// digest from being that client's `fingerprint`); a client that knows
    /// this host re-checks its pairing when it changes.
    pub fn digest(&self) -> String {
        let mut keys: Vec<&Key32> = self.peers.keys().collect();
        keys.sort();
        let mut hasher = Sha256::new();
        hasher.update(DIGEST_LABEL);
        for key in keys {
            hasher.update(key);
        }
        hex::encode(&hasher.finalize()[..4])
    }

    pub fn contains(&self, key: &Key32) -> bool {
        self.peers.contains_key(key)
    }

    pub fn name_of(&self, key: &Key32) -> Option<&str> {
        self.peers.get(key).map(String::as_str)
    }

    pub fn add(&mut self, key: Key32, name: &str) -> Result<()> {
        self.peers.insert(key, name.replace(['\r', '\n'], " "));
        self.save()
    }

    pub fn remove(&mut self, key: &Key32) -> Result<bool> {
        let removed = self.peers.remove(key).is_some();
        self.save()?;
        Ok(removed)
    }

    pub fn iter(&self) -> impl Iterator<Item = (&Key32, &String)> {
        self.peers.iter()
    }

    pub fn len(&self) -> usize {
        self.peers.len()
    }

    pub fn is_empty(&self) -> bool {
        self.peers.is_empty()
    }

    fn save(&mut self) -> Result<()> {
        if let Some(dir) = self.path.parent() {
            fs::create_dir_all(dir)?;
        }
        let mut text = String::new();
        for (key, name) in &self.peers {
            text.push_str(&format!("{} {}\n", hex::encode(key), name));
        }
        fs::write(&self.path, text).with_context(|| format!("writing {}", self.path.display()))?;
        self.seen_mtime = Self::mtime(&self.path);
        Ok(())
    }
}

/// A 6-digit pairing PIN, persisted so a headless PC keeps the same one.
pub fn load_or_create_pin(path: &Path) -> Result<String> {
    if let Ok(text) = fs::read_to_string(path) {
        let pin = text.trim().to_string();
        if is_valid_pin(&pin) {
            return Ok(pin);
        }
    }
    let pin = generate_pin();
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir)?;
    }
    fs::write(path, &pin).with_context(|| format!("writing {}", path.display()))?;
    Ok(pin)
}

/// Generate a fresh PIN and persist it, replacing whatever `path` held.
pub fn rotate_pin(path: &Path) -> Result<String> {
    let pin = generate_pin();
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir)?;
    }
    fs::write(path, &pin).with_context(|| format!("writing {}", path.display()))?;
    Ok(pin)
}

pub fn generate_pin() -> String {
    // Six digits from a CSPRNG; rejection-free because 2^32 % 10^6 bias is negligible here.
    format!("{:06}", OsRng.next_u32() % 1_000_000)
}

pub fn is_valid_pin(pin: &str) -> bool {
    (4..=8).contains(&pin.len()) && pin.bytes().all(|b| b.is_ascii_digit())
}

/// Sliding-window brake on PIN guessing.
pub struct PairLimiter {
    failures: Vec<Instant>,
}

impl PairLimiter {
    pub fn new() -> Self {
        PairLimiter {
            failures: Vec::new(),
        }
    }

    pub fn allowed(&mut self) -> bool {
        let now = Instant::now();
        self.failures
            .retain(|t| now.duration_since(*t) < PAIR_FAIL_WINDOW);
        self.failures.len() < PAIR_FAILS_ALLOWED
    }

    /// Count a failed attempt; the returned entry lets a pairing that turns
    /// out to succeed take back its own failure (`undo_failure`).
    pub fn record_failure(&mut self) -> Instant {
        let at = Instant::now();
        self.failures.push(at);
        at
    }

    /// Remove the one failure `record_failure` returned, if still counted.
    pub fn undo_failure(&mut self, at: Instant) {
        if let Some(i) = self.failures.iter().position(|t| *t == at) {
            self.failures.remove(i);
        }
    }

    /// How long until `allowed` is true again (zero when it already is).
    pub fn retry_after(&self) -> Duration {
        if self.failures.len() < PAIR_FAILS_ALLOWED {
            return Duration::ZERO;
        }
        // The window reopens once enough of the oldest failures have aged out.
        let oldest = self.failures[self.failures.len() - PAIR_FAILS_ALLOWED];
        PAIR_FAIL_WINDOW.saturating_sub(oldest.elapsed())
    }
}

impl Default for PairLimiter {
    fn default() -> Self {
        Self::new()
    }
}

// ---------------------------------------------------------------------------
// Handshake
// ---------------------------------------------------------------------------

/// What one handshake gives a connection: the transport keys, shared by its
/// reader and writer, and what a pairing on it is bound to.
#[derive(Clone)]
pub struct SessionKeys {
    transport: Arc<StatelessTransportState>,
    /// The Noise handshake hash: CPace's session id.
    pub h: Key32,
    /// CPace's channel identifier: both identity keys, the client's first.
    pub ci: Vec<u8>,
}

impl SessionKeys {
    fn from_handshake(
        noise: HandshakeState,
        client_static: &Key32,
        host_static: &Key32,
    ) -> Result<Self> {
        let h: Key32 = noise
            .get_handshake_hash()
            .try_into()
            .map_err(|_| anyhow!("the handshake hash is not 32 bytes"))?;
        Ok(SessionKeys {
            transport: Arc::new(noise.into_stateless_transport_mode()?),
            h,
            ci: cpace::channel_identifier(client_static, host_static),
        })
    }
}

/// Outcome of a handshake, for either role.
pub struct Handshake {
    pub keys: SessionKeys,
    /// The other side's identity key.
    pub peer: Key32,
    /// Host side: whether the client's key is on the paired list. Client
    /// side: always false; the host says it in SERVER_HELLO.
    pub paired: bool,
}

/// A handshake that ended without a session but not through a fault; the
/// reason is logged where it happened and the connection just closes.
#[derive(Debug)]
pub enum HandshakeEnd {
    /// The client speaks the v2 handshake: a Mac app from before protocol v4.
    OldClient,
    /// The client closed after msg2, which is what a Mac does when it has
    /// pinned a different key for this PC.
    ClosedAfterMsg2,
}

impl fmt::Display for HandshakeEnd {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            HandshakeEnd::OldClient => "the client speaks the v2 handshake",
            HandshakeEnd::ClosedAfterMsg2 => "the client closed after msg2",
        })
    }
}

impl std::error::Error for HandshakeEnd {}

/// The peer went away (as opposed to a timeout or a protocol error).
pub fn peer_closed(e: &io::Error) -> bool {
    matches!(
        e.kind(),
        io::ErrorKind::UnexpectedEof
            | io::ErrorKind::ConnectionReset
            | io::ErrorKind::ConnectionAborted
    )
}

fn start_noise(
    identity: &Identity,
    ephemeral: Option<&Key32>,
    initiator: bool,
) -> Result<HandshakeState> {
    let secret = identity.secret.to_bytes();
    let mut builder = Builder::new(NOISE_PARAMS.parse()?)
        .prologue(PROLOGUE)?
        .local_private_key(&secret)?;
    if let Some(e) = ephemeral {
        builder = builder.fixed_ephemeral_key_for_testing_only(e);
    }
    Ok(if initiator {
        builder.build_initiator()?
    } else {
        builder.build_responder()?
    })
}

fn remote_static(noise: &HandshakeState) -> Result<Key32> {
    noise
        .get_remote_static()
        .and_then(|key| key.try_into().ok())
        .ok_or_else(|| anyhow!("the handshake carried no identity key"))
}

fn write_frame(w: &mut impl Write, body: &[u8]) -> io::Result<()> {
    let mut frame = Vec::with_capacity(4 + body.len());
    frame.extend_from_slice(&(body.len() as u32).to_be_bytes());
    frame.extend_from_slice(body);
    w.write_all(&frame)
}

fn read_frame(r: &mut impl Read, max: usize) -> io::Result<Vec<u8>> {
    let mut len = [0u8; 4];
    r.read_exact(&mut len)?;
    let len = u32::from_be_bytes(len) as usize;
    if len > max {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("frame of {len} bytes exceeds {max}"),
        ));
    }
    let mut body = vec![0u8; len];
    r.read_exact(&mut body)?;
    Ok(body)
}

/// Host side: answer a client's msg1 and read its msg3. The paired list is
/// locked only for the lookup, never while waiting on the peer.
pub fn host_handshake(
    stream: &mut (impl Read + Write),
    identity: &Identity,
    paired: &Mutex<PeerList>,
) -> Result<Handshake> {
    host_handshake_with(stream, identity, paired, None)
}

/// `ephemeral` is for test vectors only.
fn host_handshake_with(
    stream: &mut (impl Read + Write),
    identity: &Identity,
    paired: &Mutex<PeerList>,
    ephemeral: Option<&Key32>,
) -> Result<Handshake> {
    let msg1 = read_frame(stream, V2_MSG1_LEN).context("reading msg1")?;
    if msg1.len() == V2_MSG1_LEN && msg1.starts_with(V2_MAGIC) {
        log::warn!("the Mac app speaks the v2 handshake; update it");
        return Err(HandshakeEnd::OldClient.into());
    }
    if msg1.len() != MSG1_LEN || !msg1.starts_with(PROLOGUE) {
        bail!("msg1 is not a Relay v4 handshake ({} bytes)", msg1.len());
    }
    let client_e = &msg1[PROLOGUE.len()..];
    identity.refuse_low_order(client_e, "the client's ephemeral key")?;

    let mut noise = start_noise(identity, ephemeral, false)?;
    let mut buf = [0u8; MSG2_LEN];
    noise.read_message(client_e, &mut buf).context("msg1")?;
    let n = noise.write_message(&[], &mut buf)?;
    write_frame(stream, &buf[..n]).context("sending msg2")?;

    let msg3 = match read_frame(stream, MSG3_LEN) {
        Ok(m) => m,
        Err(e) if peer_closed(&e) => {
            log::info!("the client closed after msg2: it has pinned a different key for this PC");
            return Err(HandshakeEnd::ClosedAfterMsg2.into());
        }
        Err(e) => return Err(anyhow::Error::new(e).context("reading msg3")),
    };
    if msg3.len() != MSG3_LEN {
        bail!("msg3 of {} bytes, expected {MSG3_LEN}", msg3.len());
    }
    noise.read_message(&msg3, &mut buf).context("msg3")?;
    let peer = remote_static(&noise)?;
    identity.refuse_low_order(&peer, "the client's identity key")?;
    let keys = SessionKeys::from_handshake(noise, &peer, identity.public.as_bytes())?;
    let is_paired = paired.lock().unwrap().contains(&peer);
    Ok(Handshake {
        keys,
        peer,
        paired: is_paired,
    })
}

/// Client side: send msg1, read msg2, send msg3. If `expected_host` is given
/// (a host paired with before) the host's identity must match it; when it
/// does not, msg3 is never sent.
pub fn client_handshake(
    stream: &mut (impl Read + Write),
    identity: &Identity,
    expected_host: Option<&Key32>,
) -> Result<Handshake> {
    client_handshake_with(stream, identity, expected_host, None)
}

/// `ephemeral` is for test vectors only.
fn client_handshake_with(
    stream: &mut (impl Read + Write),
    identity: &Identity,
    expected_host: Option<&Key32>,
    ephemeral: Option<&Key32>,
) -> Result<Handshake> {
    let mut noise = start_noise(identity, ephemeral, true)?;
    let mut buf = [0u8; MSG2_LEN];
    let n = noise.write_message(&[], &mut buf)?;
    let mut msg1 = PROLOGUE.to_vec();
    msg1.extend_from_slice(&buf[..n]);
    write_frame(stream, &msg1).context("sending msg1")?;

    let msg2 = read_frame(stream, MSG2_LEN).context("reading msg2")?;
    if msg2.len() != MSG2_LEN {
        bail!("msg2 of {} bytes, expected {MSG2_LEN}", msg2.len());
    }
    identity.refuse_low_order(&msg2[..32], "the host's ephemeral key")?;
    noise.read_message(&msg2, &mut buf).context("msg2")?;
    let peer = remote_static(&noise)?;
    identity.refuse_low_order(&peer, "the host's identity key")?;
    if let Some(expected) = expected_host {
        if expected != &peer {
            bail!(
                "host identity changed: expected {}, got {} (re-pair if this is intended)",
                fingerprint(expected),
                fingerprint(&peer)
            );
        }
    }
    let n = noise.write_message(&[], &mut buf)?;
    write_frame(stream, &buf[..n]).context("sending msg3")?;
    Ok(Handshake {
        keys: SessionKeys::from_handshake(noise, identity.public.as_bytes(), &peer)?,
        peer,
        paired: false,
    })
}

// ---------------------------------------------------------------------------
// Records
// ---------------------------------------------------------------------------

fn invalid(what: impl Into<String>) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, what.into())
}

/// One protocol message as plaintext: the 8-byte header, then the payload.
fn message_plaintext(ty: u8, flags: u8, payload: &[u8]) -> Vec<u8> {
    let mut pt = Vec::with_capacity(8 + payload.len());
    protocol::push_header(&mut pt, ty, flags, payload.len());
    pt.extend_from_slice(payload);
    pt
}

/// Encrypt one protocol message as records, all in one buffer so they go
/// out in a single write.
fn seal_message(
    transport: &StatelessTransportState,
    nonce: &mut u64,
    plaintext: &[u8],
) -> io::Result<Vec<u8>> {
    let records = plaintext.len().div_ceil(MAX_RECORD_PLAINTEXT).max(1);
    let mut out = vec![0u8; plaintext.len() + records * (4 + TAG_LEN)];
    let mut at = 0;
    for chunk in plaintext.chunks(MAX_RECORD_PLAINTEXT) {
        let len = chunk.len() + TAG_LEN;
        out[at..at + 4].copy_from_slice(&(len as u32).to_be_bytes());
        transport
            .write_message(*nonce, chunk, &mut out[at + 4..at + 4 + len])
            .map_err(|_| io::Error::other("encryption failed"))?;
        *nonce += 1;
        at += 4 + len;
    }
    Ok(out)
}

/// Read and decrypt one record of at most `max_len` bytes on the wire.
fn open_record(
    r: &mut impl Read,
    transport: &StatelessTransportState,
    nonce: &mut u64,
    max_len: usize,
) -> io::Result<Vec<u8>> {
    let mut len = [0u8; 4];
    r.read_exact(&mut len)?;
    let len = u32::from_be_bytes(len) as usize;
    if !(TAG_LEN..=max_len).contains(&len) {
        return Err(invalid(format!("record of {len} bytes")));
    }
    let mut ct = vec![0u8; len];
    r.read_exact(&mut ct)?;
    let mut pt = vec![0u8; len - TAG_LEN];
    let n = transport
        .read_message(*nonce, &ct, &mut pt)
        .map_err(|_| invalid("record failed authentication"))?;
    *nonce += 1;
    pt.truncate(n);
    Ok(pt)
}

/// Read the records of one protocol message: (type, flags, payload). A
/// payload over `max_payload` is refused on the first record's header,
/// before anything more is read.
fn open_message(
    r: &mut impl Read,
    transport: &StatelessTransportState,
    nonce: &mut u64,
    max_payload: usize,
) -> io::Result<(u8, u8, Vec<u8>)> {
    // No record of an acceptable message can be longer than the message.
    let max_record = MAX_RECORD.min(8 + max_payload + TAG_LEN);
    let first = open_record(r, transport, nonce, max_record)?;
    if first.len() < 8 {
        return Err(invalid("short message"));
    }
    let len = u32::from_be_bytes([first[4], first[5], first[6], first[7]]) as usize;
    if len > max_payload {
        return Err(invalid(format!(
            "message of {len} bytes exceeds {max_payload}"
        )));
    }
    if first.len() - 8 > len {
        return Err(invalid("record runs past the end of its message"));
    }
    let mut payload = Vec::with_capacity(len);
    payload.extend_from_slice(&first[8..]);
    while payload.len() < len {
        let record = open_record(r, transport, nonce, max_record)?;
        if payload.len() + record.len() > len {
            return Err(invalid("record runs past the end of its message"));
        }
        payload.extend_from_slice(&record);
    }
    Ok((first[0], first[1], payload))
}

/// Sends protocol messages on one connection.
pub struct SecureWriter {
    stream: TcpStream,
    transport: Arc<StatelessTransportState>,
    nonce: u64,
}

impl SecureWriter {
    pub fn new(stream: TcpStream, keys: &SessionKeys) -> Self {
        SecureWriter {
            stream,
            transport: Arc::clone(&keys.transport),
            nonce: 0,
        }
    }

    fn send_plaintext(&mut self, plaintext: &[u8]) -> io::Result<()> {
        let wire = seal_message(&self.transport, &mut self.nonce, plaintext)?;
        self.stream.write_all(&wire)
    }

    pub fn send(&mut self, ty: u8, flags: u8, payload: &[u8]) -> io::Result<()> {
        self.send_plaintext(&message_plaintext(ty, flags, payload))
    }

    /// Message whose payload is a list of 4-byte-length-prefixed NAL units.
    pub fn send_nals(&mut self, ty: u8, flags: u8, nals: &[Vec<u8>]) -> io::Result<()> {
        let total: usize = nals.iter().map(|n| 4 + n.len()).sum();
        let mut pt = Vec::with_capacity(8 + total);
        protocol::push_header(&mut pt, ty, flags, total);
        for n in nals {
            pt.extend_from_slice(&(n.len() as u32).to_be_bytes());
            pt.extend_from_slice(n);
        }
        self.send_plaintext(&pt)
    }

    pub fn shutdown(&self) {
        let _ = self.stream.shutdown(std::net::Shutdown::Both);
    }

    /// Stop sending while leaving the read half open so a final reply is not
    /// discarded by an RST if the peer already has another message in flight.
    pub fn shutdown_write(&self) {
        let _ = self.stream.shutdown(std::net::Shutdown::Write);
    }
}

/// Receives protocol messages on one connection.
pub struct SecureReader {
    stream: io::BufReader<TcpStream>,
    transport: Arc<StatelessTransportState>,
    nonce: u64,
    max_payload: usize,
}

impl SecureReader {
    /// `max_payload` is the largest payload this side accepts. Anything
    /// longer is refused from the first record's header, before more of it
    /// is buffered: the host passes a few KiB, because any peer can finish
    /// the handshake without being paired.
    pub fn new(stream: TcpStream, keys: &SessionKeys, max_payload: usize) -> Self {
        SecureReader {
            stream: io::BufReader::with_capacity(256 * 1024, stream),
            transport: Arc::clone(&keys.transport),
            nonce: 0,
            max_payload: max_payload.min(MAX_PAYLOAD as usize),
        }
    }

    pub fn set_read_timeout(&self, timeout: Option<Duration>) -> io::Result<()> {
        self.stream.get_ref().set_read_timeout(timeout)
    }

    /// Next message as (type, flags, payload).
    pub fn recv(&mut self) -> io::Result<(u8, u8, Vec<u8>)> {
        open_message(
            &mut self.stream,
            &self.transport,
            &mut self.nonce,
            self.max_payload,
        )
    }
}

// ---------------------------------------------------------------------------
// Pairing (CPace inside the channel)
// ---------------------------------------------------------------------------

/// The host's side of pairing, once PAIR has arrived carrying `ya`. Every
/// attempt counts as a failed PIN until the client's confirmation proves
/// otherwise, so a client that walks away after seeing Tb (which is also how
/// a Mac with the wrong PIN leaves) has still spent its guess. `store`
/// remembers the client before it is told it is paired.
///
/// Ok(true): paired and told so. Ok(false): the client left after
/// PAIR_REPLY. A refusal (rate limit, wrong PIN) is answered with
/// PAIR_RESULT and returned as an error.
pub fn host_pairing(
    tx: &mut SecureWriter,
    rx: &mut SecureReader,
    keys: &SessionKeys,
    ya: &[u8],
    pin: &str,
    limiter: &Mutex<PairLimiter>,
    store: impl FnOnce() -> Result<()>,
) -> Result<bool> {
    let failure = {
        let mut limiter = limiter.lock().unwrap();
        if !limiter.allowed() {
            // Checked before anything else so a locked-out guesser learns
            // nothing about the PIN. The wait lets the Mac say when to retry.
            let wait = limiter.retry_after().as_secs().min(u16::MAX as u64) as u16;
            drop(limiter);
            let mut reply = vec![pair_result::RATE_LIMITED];
            reply.extend_from_slice(&wait.to_be_bytes());
            tx.send(msg::PAIR_RESULT, 0, &reply)?;
            bail!("refused: too many failed PINs recently ({wait} s left)");
        }
        limiter.record_failure()
    };
    let ya: cpace::Point = ya
        .try_into()
        .map_err(|_| anyhow!("PAIR carried {} bytes, not a share", ya.len()))?;
    let b = cpace::Responder::new(pin.as_bytes(), &keys.ci, &keys.h, &ya, b"", b"", None)?;
    let mut reply = b.share.to_vec();
    reply.extend_from_slice(&b.tag);
    tx.send(msg::PAIR_REPLY, 0, &reply)?;

    let (ty, _, ta) = match rx.recv() {
        Ok(m) => m,
        Err(e) if peer_closed(&e) => return Ok(false),
        Err(e) => return Err(anyhow::Error::new(e).context("waiting for PAIR_CONFIRM")),
    };
    if ty != msg::PAIR_CONFIRM {
        bail!("expected PAIR_CONFIRM, got 0x{ty:02x}");
    }
    if !b.verify(&ta) {
        tx.send(msg::PAIR_RESULT, 0, &[pair_result::WRONG_PIN])?;
        bail!("wrong PIN");
    }
    limiter.lock().unwrap().undo_failure(failure);
    store()?;
    tx.send(msg::PAIR_RESULT, 0, &[pair_result::PAIRED])?;
    Ok(true)
}

/// The client's side of pairing, as `probe` runs it: PAIR, check the
/// host's proof, PAIR_CONFIRM, PAIR_RESULT. With `abandon_after_reply` it
/// stops after PAIR_REPLY without confirming, which the host must count as a
/// failed PIN.
pub fn client_pairing(
    tx: &mut SecureWriter,
    rx: &mut SecureReader,
    keys: &SessionKeys,
    pin: &str,
    abandon_after_reply: bool,
) -> Result<()> {
    let a = cpace::Initiator::new(pin.as_bytes(), &keys.ci, &keys.h, b"", None)?;
    tx.send(msg::PAIR, 0, &a.share)?;
    let (ty, _, reply) = rx.recv().context("waiting for PAIR_REPLY")?;
    if ty != msg::PAIR_REPLY {
        return Err(pairing_refusal(ty, &reply));
    }
    if reply.len() != 32 + cpace::TAG_LEN {
        bail!("PAIR_REPLY of {} bytes", reply.len());
    }
    if abandon_after_reply {
        return Ok(());
    }
    let yb: cpace::Point = reply[..32].try_into().unwrap();
    let (_, ta) = a
        .finish(&yb, b"", &reply[32..])
        .context("the host's proof did not match: wrong PIN, or not the host it claims to be")?;
    tx.send(msg::PAIR_CONFIRM, 0, &ta)?;
    let (ty, _, result) = rx.recv().context("waiting for the pairing result")?;
    if ty == msg::PAIR_RESULT && result.first() == Some(&pair_result::PAIRED) {
        return Ok(());
    }
    Err(pairing_refusal(ty, &result))
}

fn pairing_refusal(ty: u8, payload: &[u8]) -> anyhow::Error {
    if ty == msg::STREAM_STOP && payload.first() == Some(&stop_reason::BUSY) {
        return anyhow!("the host is busy with another client");
    }
    if ty != msg::PAIR_RESULT {
        return anyhow!("unexpected message 0x{ty:02x} while pairing");
    }
    match payload.first() {
        Some(&pair_result::RATE_LIMITED) => {
            let secs = payload
                .get(1..3)
                .map(|b| u16::from_be_bytes([b[0], b[1]]))
                .unwrap_or(0);
            anyhow!("the host is refusing PINs after too many failures; try again in {secs} s")
        }
        _ => anyhow!("the host rejected the PIN"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;
    use std::thread;

    /// Reads from a prepared input, collects what is written: enough to run
    /// one side of a handshake against recorded messages.
    struct Duplex {
        input: io::Cursor<Vec<u8>>,
        output: Vec<u8>,
    }

    impl Duplex {
        fn new(input: Vec<u8>) -> Self {
            Duplex {
                input: io::Cursor::new(input),
                output: Vec::new(),
            }
        }
    }

    impl Read for Duplex {
        fn read(&mut self, buf: &mut [u8]) -> io::Result<usize> {
            self.input.read(buf)
        }
    }

    impl Write for Duplex {
        fn write(&mut self, buf: &[u8]) -> io::Result<usize> {
            self.output.write(buf)
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    fn frame(body: &[u8]) -> Vec<u8> {
        let mut f = (body.len() as u32).to_be_bytes().to_vec();
        f.extend_from_slice(body);
        f
    }

    fn empty_list(tag: &str) -> Mutex<PeerList> {
        let dir = std::env::temp_dir().join(format!("td-{tag}-{}", std::process::id()));
        Mutex::new(PeerList::load(&dir.join("none.txt")).unwrap())
    }

    struct Side {
        hs: Handshake,
        tx: SecureWriter,
        rx: SecureReader,
    }

    /// A real handshake over loopback; the host side's paired list has the
    /// client on it when `client_paired`.
    fn connected(client_paired: bool) -> (Side, Side) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let client_id = Identity::generate();
        let list = empty_list(&format!("conn{}", OsRng.next_u32()));
        if client_paired {
            list.lock()
                .unwrap()
                .add(*client_id.public.as_bytes(), "mac")
                .unwrap();
        }
        let host = thread::spawn(move || {
            let (mut s, _) = listener.accept().unwrap();
            let hs = host_handshake(&mut s, &Identity::generate(), &list).unwrap();
            let tx = SecureWriter::new(s.try_clone().unwrap(), &hs.keys);
            let rx = SecureReader::new(s, &hs.keys, 4096);
            Side { hs, tx, rx }
        });
        let mut c = TcpStream::connect(addr).unwrap();
        let hs = client_handshake(&mut c, &client_id, None).unwrap();
        let tx = SecureWriter::new(c.try_clone().unwrap(), &hs.keys);
        let rx = SecureReader::new(c, &hs.keys, MAX_PAYLOAD as usize);
        (host.join().unwrap(), Side { hs, tx, rx })
    }

    #[test]
    fn handshake_agrees_and_messages_flow_both_ways() {
        let (mut host, mut client) = connected(false);
        assert_eq!(host.hs.keys.h, client.hs.keys.h);
        assert_eq!(host.hs.keys.ci, client.hs.keys.ci);
        assert!(!host.hs.paired && !client.hs.paired);
        client.tx.send(msg::CLIENT_HELLO, 0, b"hello").unwrap();
        assert_eq!(
            host.rx.recv().unwrap(),
            (msg::CLIENT_HELLO, 0, b"hello".to_vec())
        );
        host.tx
            .send_nals(msg::FRAME, 1, &[vec![1, 2], vec![3]])
            .unwrap();
        assert_eq!(
            client.rx.recv().unwrap(),
            (msg::FRAME, 1, vec![0, 0, 0, 2, 1, 2, 0, 0, 0, 1, 3])
        );
        // The peers are each other's identities.
        assert_eq!(
            host.hs.keys.ci,
            cpace::channel_identifier(&host.hs.peer, &client.hs.peer)
        );

        let (host, _client) = connected(true);
        assert!(host.hs.paired);
    }

    #[test]
    fn a_pinned_host_key_mismatch_closes_before_msg3() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let host = thread::spawn(move || {
            let (mut s, _) = listener.accept().unwrap();
            host_handshake(&mut s, &Identity::generate(), &empty_list("pin")).map(|_| ())
        });
        let mut c = TcpStream::connect(addr).unwrap();
        let other = *Identity::generate().public.as_bytes();
        let err = client_handshake(&mut c, &Identity::generate(), Some(&other))
            .err()
            .expect("a different host identity must fail");
        assert!(err.to_string().contains("host identity changed"));
        drop(c);
        let host_err = host.join().unwrap().unwrap_err();
        assert!(matches!(
            host_err.downcast_ref::<HandshakeEnd>(),
            Some(HandshakeEnd::ClosedAfterMsg2)
        ));
    }

    #[test]
    fn handshake_input_is_checked() {
        let pc = Identity::generate();
        let list = empty_list("input");
        let run = |msg1: Vec<u8>| {
            let mut wire = Duplex::new(frame(&msg1));
            let result = host_handshake(&mut wire, &pc, &list).map(|_| ());
            (result, wire.output)
        };

        // The Mac app before v4.
        let mut v2 = b"TDH2".to_vec();
        v2.resize(V2_MSG1_LEN, 7);
        let (result, written) = run(v2);
        assert!(matches!(
            result.unwrap_err().downcast_ref::<HandshakeEnd>(),
            Some(HandshakeEnd::OldClient)
        ));
        assert!(written.is_empty());

        // Wrong magic, wrong length, a low-order ephemeral key: refused
        // before msg2.
        let mut wrong_magic = b"RLY3".to_vec();
        wrong_magic.extend_from_slice(Identity::generate().public.as_bytes());
        let mut short = PROLOGUE.to_vec();
        short.extend_from_slice(&[9; 31]);
        let mut zero_e = PROLOGUE.to_vec();
        zero_e.extend_from_slice(&[0; 32]);
        for msg1 in [wrong_magic, short, zero_e] {
            let (result, written) = run(msg1);
            let err = result.unwrap_err();
            assert!(err.downcast_ref::<HandshakeEnd>().is_none(), "{err:#}");
            assert!(written.is_empty());
        }
    }

    #[test]
    fn a_tampered_msg2_fails() {
        let mut msg2 = hex::decode(vector::MSG2).unwrap();
        msg2[40] ^= 1; // inside the encrypted static key
        let mut wire = Duplex::new(frame(&msg2));
        let mac = Identity::from_bytes([0x11; 32]);
        assert!(client_handshake_with(&mut wire, &mac, None, Some(&[0x22; 32])).is_err());
        // msg1 went out, msg3 did not.
        assert_eq!(wire.output, frame(&hex::decode(vector::MSG1).unwrap()));
    }

    /// Both ends of a session without sockets, from the v4 vector.
    fn vector_keys() -> (SessionKeys, SessionKeys) {
        let list = empty_list("vec");
        let mut wire = Duplex::new(
            [
                frame(&hex::decode(vector::MSG1).unwrap()),
                frame(&hex::decode(vector::MSG3).unwrap()),
            ]
            .concat(),
        );
        let pc = Identity::from_bytes([0x33; 32]);
        let host = host_handshake_with(&mut wire, &pc, &list, Some(&[0x44; 32])).unwrap();
        let mut wire = Duplex::new(frame(&hex::decode(vector::MSG2).unwrap()));
        let mac = Identity::from_bytes([0x11; 32]);
        let client = client_handshake_with(&mut wire, &mac, None, Some(&[0x22; 32])).unwrap();
        (host.keys, client.keys)
    }

    fn open(
        wire: &[u8],
        keys: &SessionKeys,
        nonce: &mut u64,
        max: usize,
    ) -> io::Result<(u8, u8, Vec<u8>)> {
        open_message(&mut &wire[..], &keys.transport, nonce, max)
    }

    #[test]
    fn records_split_at_65519_bytes() {
        let (host, client) = vector_keys();
        for (size, lengths) in [
            (MAX_RECORD_PLAINTEXT, vec![MAX_RECORD]),
            (MAX_RECORD_PLAINTEXT + 1, vec![MAX_RECORD, 1 + TAG_LEN]),
        ] {
            let payload: Vec<u8> = (0..size - 8).map(|i| i as u8).collect();
            let pt = message_plaintext(msg::FRAME, 0, &payload);
            assert_eq!(pt.len(), size);
            let (mut send, mut recv) = (0, 0);
            let wire = seal_message(&host.transport, &mut send, &pt).unwrap();
            // Walk the length prefixes.
            let mut seen = Vec::new();
            let mut at = 0;
            while at < wire.len() {
                let len = u32::from_be_bytes(wire[at..at + 4].try_into().unwrap()) as usize;
                seen.push(len);
                at += 4 + len;
            }
            assert_eq!(seen, lengths, "{size} bytes");
            assert_eq!(send, lengths.len() as u64);
            let got = open(&wire, &client, &mut recv, MAX_PAYLOAD as usize).unwrap();
            assert_eq!(got, (msg::FRAME, 0, payload));
            assert_eq!(recv, send);
        }
    }

    #[test]
    fn a_3_mb_keyframe_round_trips() {
        let (mut host, mut client) = connected(true);
        let nal: Vec<u8> = (0..3_000_000u32).map(|i| (i * 7) as u8).collect();
        let sender = thread::spawn(move || {
            host.tx
                .send_nals(msg::FRAME, 1, std::slice::from_ref(&nal))
                .unwrap();
            host.tx.send(msg::PING, 0, b"after").unwrap();
            (host, nal)
        });
        let (ty, flags, payload) = client.rx.recv().unwrap();
        let (_host, nal) = sender.join().unwrap();
        assert_eq!((ty, flags), (msg::FRAME, 1));
        assert_eq!(&payload[..4], &(nal.len() as u32).to_be_bytes());
        assert!(payload[4..] == nal[..]);
        assert_eq!(client.rx.recv().unwrap(), (msg::PING, 0, b"after".to_vec()));
    }

    #[test]
    fn an_oversized_client_message_is_refused_on_its_first_record() {
        let (host, client) = vector_keys();
        // A first record holding only a header that claims 1 MiB: refused on
        // the header, nothing after it read.
        let mut header = Vec::new();
        protocol::push_header(&mut header, msg::CLIENT_HELLO, 0, 1 << 20);
        let mut wire = seal_message(&client.transport, &mut 0, &header).unwrap();
        let first = wire.len();
        wire.extend_from_slice(&[0xAA; 1000]);
        let mut cursor = io::Cursor::new(&wire[..]);
        let err = open_message(&mut cursor, &host.transport, &mut 0, 4096).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::InvalidData);
        assert_eq!(cursor.position() as usize, first);

        // A 70 kB message in full-size records: the first record is longer
        // than any acceptable message, so not even it is read.
        let pt = message_plaintext(msg::CLIENT_HELLO, 0, &[0; 70_000]);
        let wire = seal_message(&client.transport, &mut 0, &pt).unwrap();
        let mut cursor = io::Cursor::new(&wire[..]);
        let err = open_message(&mut cursor, &host.transport, &mut 0, 4096).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::InvalidData);
        assert_eq!(cursor.position(), 4);
    }

    #[test]
    fn broken_records_fail() {
        let (host, client) = vector_keys();
        let pt = message_plaintext(msg::PING, 0, b"12345678");
        let a = seal_message(&host.transport, &mut 0, &pt).unwrap();
        let b = seal_message(&host.transport, &mut 1, &pt).unwrap();

        // Truncated.
        let err = open(&a[..a.len() - 5], &client, &mut 0, 4096).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::UnexpectedEof);
        // Tampered.
        let mut tampered = a.clone();
        tampered[10] ^= 1;
        let err = open(&tampered, &client, &mut 0, 4096).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::InvalidData);
        // Out of order.
        assert!(open(&b, &client, &mut 0, 4096).is_err());
        // Our own direction's key does not open it.
        assert!(open(&a, &host, &mut 0, 4096).is_err());
        // In order, under the peer's key, it does.
        let mut nonce = 0;
        assert!(open(&a, &client, &mut nonce, 4096).is_ok());
        assert!(open(&b, &client, &mut nonce, 4096).is_ok());
        // A record that carries more than its message.
        let mut long = Vec::new();
        protocol::push_header(&mut long, msg::PING, 0, 2);
        long.extend_from_slice(b"abc");
        let wire = seal_message(&host.transport, &mut 2, &long).unwrap();
        let err = open(&wire, &client, &mut nonce, 4096).unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::InvalidData);
    }

    // --- pairing -----------------------------------------------------------

    const PIN: &str = "123456";

    /// One pairing attempt over loopback: the host waits for PAIR and runs
    /// `host_pairing`; the client runs `client`. Returns the client's result,
    /// the host's, and whether the host stored the client.
    fn pair_attempt(
        limiter: &Arc<Mutex<PairLimiter>>,
        client: impl FnOnce(&mut Side) -> Result<()>,
    ) -> (Result<()>, Result<bool>, bool) {
        let (host, mut mac) = connected(false);
        let limiter = Arc::clone(limiter);
        let host = thread::spawn(move || {
            let Side { hs, mut tx, mut rx } = host;
            rx.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
            let (ty, _, ya) = rx.recv().unwrap();
            assert_eq!(ty, msg::PAIR);
            let mut stored = false;
            let result = host_pairing(&mut tx, &mut rx, &hs.keys, &ya, PIN, &limiter, || {
                stored = true;
                Ok(())
            });
            (result, stored)
        });
        let client_result = client(&mut mac);
        mac.tx.shutdown();
        let (host_result, stored) = host.join().unwrap();
        (client_result, host_result, stored)
    }

    fn failures(limiter: &Arc<Mutex<PairLimiter>>) -> usize {
        limiter.lock().unwrap().failures.len()
    }

    fn client_with(pin: &'static str, abandon: bool) -> impl FnOnce(&mut Side) -> Result<()> {
        move |mac| client_pairing(&mut mac.tx, &mut mac.rx, &mac.hs.keys, pin, abandon)
    }

    #[test]
    fn the_right_pin_pairs_and_takes_back_its_failure() {
        let limiter = Arc::new(Mutex::new(PairLimiter::new()));
        let (client, host, stored) = pair_attempt(&limiter, client_with(PIN, false));
        client.unwrap();
        assert!(host.unwrap());
        assert!(stored);
        assert_eq!(failures(&limiter), 0);

        // With four failures on the books, a success leaves exactly those.
        for _ in 0..4 {
            limiter.lock().unwrap().record_failure();
        }
        let (client, host, _) = pair_attempt(&limiter, client_with(PIN, false));
        client.unwrap();
        assert!(host.unwrap());
        assert_eq!(failures(&limiter), 4);
        assert!(limiter.lock().unwrap().allowed());
    }

    #[test]
    fn a_wrong_pin_is_seen_by_the_mac_and_counted_by_the_pc() {
        let limiter = Arc::new(Mutex::new(PairLimiter::new()));
        let (client, host, stored) = pair_attempt(&limiter, client_with("654321", false));
        assert!(client.unwrap_err().to_string().contains("did not match"));
        // The Mac closed without confirming.
        assert!(!host.unwrap());
        assert!(!stored);
        assert_eq!(failures(&limiter), 1);
    }

    #[test]
    fn walking_away_after_the_reply_counts_as_a_failure() {
        let limiter = Arc::new(Mutex::new(PairLimiter::new()));
        let (client, host, stored) = pair_attempt(&limiter, client_with(PIN, true));
        client.unwrap();
        assert!(!host.unwrap());
        assert!(!stored);
        assert_eq!(failures(&limiter), 1);
    }

    #[test]
    fn a_forged_confirmation_gets_wrong_pin() {
        let limiter = Arc::new(Mutex::new(PairLimiter::new()));
        let (client, host, stored) = pair_attempt(&limiter, |mac| {
            let a =
                cpace::Initiator::new(PIN.as_bytes(), &mac.hs.keys.ci, &mac.hs.keys.h, b"", None)?;
            mac.tx.send(msg::PAIR, 0, &a.share)?;
            let (ty, _, _) = mac.rx.recv()?;
            assert_eq!(ty, msg::PAIR_REPLY);
            mac.tx.send(msg::PAIR_CONFIRM, 0, &[0; cpace::TAG_LEN])?;
            let (ty, _, result) = mac.rx.recv()?;
            assert_eq!(
                (ty, result),
                (msg::PAIR_RESULT, vec![pair_result::WRONG_PIN])
            );
            Ok(())
        });
        client.unwrap();
        assert!(host.unwrap_err().to_string().contains("wrong PIN"));
        assert!(!stored);
        assert_eq!(failures(&limiter), 1);
    }

    #[test]
    fn five_failures_refuse_pairing_with_a_wait() {
        let limiter = Arc::new(Mutex::new(PairLimiter::new()));
        for _ in 0..PAIR_FAILS_ALLOWED {
            let (_, host, _) = pair_attempt(&limiter, client_with("000000", false));
            assert!(!host.unwrap());
        }
        assert_eq!(failures(&limiter), PAIR_FAILS_ALLOWED);
        let (client, host, stored) = pair_attempt(&limiter, |mac| {
            let a =
                cpace::Initiator::new(PIN.as_bytes(), &mac.hs.keys.ci, &mac.hs.keys.h, b"", None)?;
            mac.tx.send(msg::PAIR, 0, &a.share)?;
            let (ty, _, result) = mac.rx.recv()?;
            assert_eq!(ty, msg::PAIR_RESULT);
            assert_eq!(result[0], pair_result::RATE_LIMITED);
            assert!(u16::from_be_bytes([result[1], result[2]]) > 0);
            Ok(())
        });
        client.unwrap();
        assert!(host.is_err());
        assert!(!stored);
        // The refusal is not itself a failure.
        assert_eq!(failures(&limiter), PAIR_FAILS_ALLOWED);
    }

    // --- state on disk and the limiter ---------------------------------------

    #[test]
    fn peer_list_persists() {
        let dir = std::env::temp_dir().join(format!("td-peers3-{}", std::process::id()));
        let path = dir.join("paired.txt");
        let mut list = PeerList::load(&path).unwrap();
        let key = [1u8; 32];
        list.add(key, "Aman's MacBook\n").unwrap();
        let again = PeerList::load(&path).unwrap();
        assert!(again.contains(&key));
        assert_eq!(again.name_of(&key), Some("Aman's MacBook "));
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn digest_follows_the_key_set_only() {
        let dir = std::env::temp_dir().join(format!("td-peers4-{}", std::process::id()));
        let mut list = PeerList::load(&dir.join("paired.txt")).unwrap();
        let empty = list.digest();
        assert_eq!(empty.len(), 8);
        list.add([1u8; 32], "a").unwrap();
        list.add([2u8; 32], "b").unwrap();
        let both = list.digest();
        assert_ne!(both, empty);
        // Renaming is not a pairing change.
        list.add([1u8; 32], "renamed").unwrap();
        assert_eq!(list.digest(), both);
        // Order of insertion does not matter.
        let mut other = PeerList::load(&dir.join("other.txt")).unwrap();
        other.add([2u8; 32], "x").unwrap();
        other.add([1u8; 32], "y").unwrap();
        assert_eq!(other.digest(), both);
        list.remove(&[2u8; 32]).unwrap();
        assert_ne!(list.digest(), both);
        // A lone client's digest must not be its fingerprint: `pg` is public.
        assert_ne!(
            list.digest().to_uppercase(),
            fingerprint(&[1u8; 32]),
            "digest leaks the fingerprint"
        );
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn reload_sees_another_writer_but_not_itself() {
        let dir = std::env::temp_dir().join(format!("td-peers5-{}", std::process::id()));
        let path = dir.join("paired.txt");
        let mut list = PeerList::load(&path).unwrap();
        list.add([1u8; 32], "mine").unwrap();
        assert!(!list.reload_if_changed(), "own save must not count");
        // Another process (the CLI) forgets the peer; make sure the mtime
        // differs even on a coarse filesystem clock.
        let later = std::time::SystemTime::now() + std::time::Duration::from_secs(5);
        fs::write(&path, "").unwrap();
        fs::File::options()
            .write(true)
            .open(&path)
            .unwrap()
            .set_modified(later)
            .unwrap();
        assert!(list.reload_if_changed());
        assert!(list.is_empty());
        assert!(!list.reload_if_changed());
        let _ = fs::remove_dir_all(dir);
    }

    #[test]
    fn pins_are_six_digits() {
        for _ in 0..20 {
            let pin = generate_pin();
            assert_eq!(pin.len(), 6);
            assert!(is_valid_pin(&pin));
        }
        assert!(!is_valid_pin("12a4"));
        assert!(!is_valid_pin("123"));
    }

    #[test]
    fn limiter_trips_after_five_failures() {
        let mut l = PairLimiter::new();
        for _ in 0..5 {
            assert!(l.allowed());
            l.record_failure();
        }
        assert!(!l.allowed());
        let wait = l.retry_after();
        assert!(wait > Duration::ZERO && wait <= PAIR_FAIL_WINDOW);
    }

    #[test]
    fn limiter_retry_after_is_zero_while_allowed() {
        let mut l = PairLimiter::new();
        assert_eq!(l.retry_after(), Duration::ZERO);
        l.record_failure();
        assert_eq!(l.retry_after(), Duration::ZERO);
    }

    #[test]
    fn undo_failure_removes_only_its_own_entry() {
        let mut l = PairLimiter::new();
        let mine = l.record_failure();
        let (before, after) = (mine - Duration::from_secs(1), mine + Duration::from_secs(1));
        l.failures = vec![before, mine, after];
        l.undo_failure(mine);
        assert_eq!(l.failures, [before, after]);
        // Already gone: nothing else is taken instead.
        l.undo_failure(mine);
        assert_eq!(l.failures, [before, after]);
    }

    // --- the v4 vector -------------------------------------------------------

    /// docs/PROTOCOL.md's test vector, generated by the Mac's Swift
    /// implementation: every secret is one byte repeated (Mac static 0x11,
    /// Mac ephemeral 0x22, PC static 0x33, PC ephemeral 0x44, ya 0x55,
    /// yb 0x66), PIN "123456", PC name "Test PC", paired 0. Records are
    /// shown without their length prefix.
    mod vector {
        pub const MSG1: &str =
            "524c59340faa684ed28867b97f4a6a2dee5df8ce974e76b7018e3f22a1c4cf2678570f20";
        pub const MSG2: &str = "ff2ee45601ec1b67310c7790404585ae697331eee1c1f8cf2419731c1fff3e6b5cda1c2d8029877d73fad62823946ccd0c5da35c129100f43d33a59cf19ea8fc8a34ab0906b247c442369fee33d074a3cd84501b7ddd1c5eb1e0902fdeea606b";
        pub const MSG3: &str = "f4e4988e97bdcbf0f799d02dd2242624bda72d200e97e322c4f723213896a31ebf3f7e0cea270326c10b7a70497b6dc220995f6d75f9fdc693ad73606f56b4b7";
        pub const H: &str = "78c958b2116d50f7f7e07d8f7334849359c14d6e9d3524f8b091d25d172dfcbb";
        pub const CI: &str = "0872656c61792d7634207b4e909bbe7ffe44c465a220037d608ee35897d31ef972f07f74892cb0f73f13207b0d47d93427f8311160781c7c733fd89f88970aef490d8aa0ee19a4cb8a1b14";
        pub const G: &str = "4da8240a286e94f94e63fb7a308fafab75d5ba9625097ccc0960c08ee5510912";
        pub const YA: &str = "d2ff03377c6866e7910d272a562919d586cc30c289a7e93baa6a11d16ae58c4a";
        pub const YB: &str = "f9d2846618c6c5eba1b22562444d002b263dcea78848303ca2e07715f4044673";
        pub const K: &str = "5cd19a85622eab280d34b347deec67c9143cacd11c2679f5f45bba50e7731a50";
        pub const ISK: &str = "b5cff33f2f751fd6d89e0679a2db943b92b84c9a31347d94d396c35c70fc3393ed331f63baef05915514bf5d417487d42580a838927e2cbadd90dffe9e9b488a";
        pub const TA: &str = "3f1656c004be3c70b2928e9d59596b41c594b184fbdd0daa875ccf738fa95f66";
        pub const TB: &str = "424d696ffbb7e8ef252e742f3541191ca4842c8cedcfe31189c86ad24e9dafd8";
        pub const REC_HELLO: &str =
            "799e0c48aae62c91b0554ec35f909866393910523f91db8612ce2ae07994640b3a3e8c";
        pub const REC_PAIR: &str = "8746b8a0817bd1b7961cdc80a04a68e507a49cb60203a1be841663bf145d5dab7558f3a726bb4f9b1c454fb29b2cfa4fa4ca4a2793bb094b";
        pub const REC_REPLY: &str = "af30f22934cf7e9ef62b1c7e1d0703f756607a55bafd4a03f1c4dfb29937acd2f8f21b6f273d0075ee41be91a2cfc9fb5046777cf311f82a69efb3e0cd08507c16ca3090fa04f5791da57849f85765950b99643b6896fbfb";
        pub const REC_CONFIRM: &str = "2fc518fc7bf0afdd9ed6dde4ac630eb08bdd61249b288e9329cef276b99f26732c0c6730e7d3050486b170e3a31d4d49ff313829fe5594a3";
    }

    #[test]
    fn v4_vector() {
        let unhex = |s: &str| hex::decode(s).unwrap();
        let mac = Identity::from_bytes([0x11; 32]);
        let pc = Identity::from_bytes([0x33; 32]);

        // The PC answers the recorded msg1 and msg3.
        let list = empty_list("v4");
        let mut wire =
            Duplex::new([frame(&unhex(vector::MSG1)), frame(&unhex(vector::MSG3))].concat());
        let host = host_handshake_with(&mut wire, &pc, &list, Some(&[0x44; 32])).unwrap();
        assert_eq!(wire.output, frame(&unhex(vector::MSG2)), "msg2");
        assert_eq!(hex::encode(host.keys.h), vector::H, "h (PC)");
        assert_eq!(host.peer, *mac.public.as_bytes());
        assert!(!host.paired);

        // The Mac's side produces msg1 and msg3.
        let mut wire = Duplex::new(frame(&unhex(vector::MSG2)));
        let client = client_handshake_with(
            &mut wire,
            &mac,
            Some(pc.public.as_bytes()),
            Some(&[0x22; 32]),
        )
        .unwrap();
        assert_eq!(
            wire.output,
            [frame(&unhex(vector::MSG1)), frame(&unhex(vector::MSG3))].concat(),
            "msg1, msg3"
        );
        assert_eq!(hex::encode(client.keys.h), vector::H, "h (Mac)");
        assert_eq!(client.peer, *pc.public.as_bytes());

        // CPace.
        assert_eq!(hex::encode(&host.keys.ci), vector::CI, "CI");
        assert_eq!(client.keys.ci, host.keys.ci);
        let pin = b"123456";
        let g = cpace::generator(pin, &host.keys.ci, &host.keys.h);
        assert_eq!(hex::encode(g), vector::G, "g");
        let a = cpace::Initiator::new(pin, &client.keys.ci, &client.keys.h, b"", Some([0x55; 32]))
            .unwrap();
        assert_eq!(hex::encode(a.share), vector::YA, "Ya");
        let b = cpace::Responder::new(
            pin,
            &host.keys.ci,
            &host.keys.h,
            &a.share,
            b"",
            b"",
            Some([0x66; 32]),
        )
        .unwrap();
        assert_eq!(hex::encode(b.share), vector::YB, "Yb");
        let k = cpace::scalar_mult_vfy(&[0x55; 32], &b.share).unwrap();
        assert_eq!(hex::encode(k), vector::K, "K");
        assert_eq!(hex::encode(b.isk), vector::ISK, "ISK");
        assert_eq!(hex::encode(b.tag), vector::TB, "Tb");
        let (isk, ta) = a.finish(&b.share, b"", &b.tag).unwrap();
        assert_eq!(isk, b.isk);
        assert_eq!(hex::encode(ta), vector::TA, "Ta");
        assert!(b.verify(&ta));

        // Records, each opened by the other side.
        let (mut pc_out, mut mac_in, mut mac_out, mut pc_in) = (0, 0, 0, 0);
        let record = |keys: &SessionKeys, nonce: &mut u64, ty: u8, payload: &[u8]| {
            let wire =
                seal_message(&keys.transport, nonce, &message_plaintext(ty, 0, payload)).unwrap();
            assert_eq!(&wire[..4], &((wire.len() - 4) as u32).to_be_bytes());
            wire
        };
        let hello = protocol::server_hello("Test PC", false);
        let wire = record(&host.keys, &mut pc_out, msg::SERVER_HELLO, &hello);
        assert_eq!(hex::encode(&wire[4..]), vector::REC_HELLO, "rec_hello");
        assert_eq!(
            open(&wire, &client.keys, &mut mac_in, MAX_PAYLOAD as usize).unwrap(),
            (msg::SERVER_HELLO, 0, hello)
        );

        let wire = record(&client.keys, &mut mac_out, msg::PAIR, &a.share);
        assert_eq!(hex::encode(&wire[4..]), vector::REC_PAIR, "rec_pair");
        assert_eq!(
            open(&wire, &host.keys, &mut pc_in, 4096).unwrap(),
            (msg::PAIR, 0, a.share.to_vec())
        );

        let reply = [b.share.as_slice(), b.tag.as_slice()].concat();
        let wire = record(&host.keys, &mut pc_out, msg::PAIR_REPLY, &reply);
        assert_eq!(hex::encode(&wire[4..]), vector::REC_REPLY, "rec_reply");
        assert_eq!(
            open(&wire, &client.keys, &mut mac_in, MAX_PAYLOAD as usize).unwrap(),
            (msg::PAIR_REPLY, 0, reply)
        );

        let wire = record(&client.keys, &mut mac_out, msg::PAIR_CONFIRM, &ta);
        assert_eq!(hex::encode(&wire[4..]), vector::REC_CONFIRM, "rec_confirm");
        assert_eq!(
            open(&wire, &host.keys, &mut pc_in, 4096).unwrap(),
            (msg::PAIR_CONFIRM, 0, ta.to_vec())
        );
    }
}
