//! Pairing and transport security. See docs/PROTOCOL.md, "Handshake".
//!
//! Model: each side has a long-lived X25519 identity. The first time a client
//! connects it proves knowledge of the host's PIN; the host then remembers the
//! client's identity key and the client remembers the host's, and every later
//! connection is mutually authenticated by those keys alone. Every connection
//! runs a fresh ephemeral X25519 exchange, so session keys are never reused and
//! a recorded session cannot be decrypted later.
//!
//! Handshake (both messages in the clear, each prefixed by a u32 BE length):
//!
//! ```text
//! msg1  C->H  "TDH2" | u16 version | S_c (32) | E_c (32)                 70 bytes
//! msg2  H->C  "TDH2" | u16 version | S_h (32) | E_h (32) | paired (u8)   71 bytes
//! th    = SHA-256(msg1 || msg2)
//! ikm   = X25519(E_c, E_h) || X25519(E_c, S_h) || X25519(S_c, E_h)
//! okm   = HKDF-SHA256(salt = th, ikm, info = "TravelDisplay v2", 96 bytes)
//! k_c2h = okm[0..32]   k_h2c = okm[32..64]   k_pair = okm[64..96]
//! ```
//!
//! Afterwards every message is `u32 BE length || ChaCha20-Poly1305(key = k_dir,
//! nonce = 4 zero bytes || u64 BE counter, plaintext = 8-byte header || payload)`
//! with an independent counter per direction starting at 0. An unpaired client
//! sends PAIR carrying `HMAC-SHA256(k_pair, "pin:" || PIN)`; the host answers
//! PAIR_RESULT and, on success, stores the client's key.
//!
//! Only an attacker who is actively in the middle of the *first* pairing could
//! attack the PIN, which is why pairing should happen on the cable or at home;
//! afterwards the pinned keys make impersonation impossible.

use std::collections::HashMap;
use std::fs;
use std::io::{self, Read, Write};
use std::net::TcpStream;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Context, Result};
use chacha20poly1305::aead::Aead;
use chacha20poly1305::{ChaCha20Poly1305, KeyInit, Nonce};
use hkdf::Hkdf;
use hmac::{Hmac, Mac};
use rand::rngs::OsRng;
use rand::RngCore;
use sha2::{Digest, Sha256};
use x25519_dalek::{PublicKey, StaticSecret};

use crate::protocol::{self, msg, pair_result, MAX_PAYLOAD};

const MAGIC: &[u8; 4] = b"TDH2";
const HANDSHAKE_VERSION: u16 = 2;
const HKDF_INFO: &[u8] = b"TravelDisplay v2"; // wire constant kept from the original name (see PROTOCOL.md)
const PIN_PREFIX: &[u8] = b"pin:";
const TAG_LEN: usize = 16;

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

    fn dh(&self, other: &PublicKey) -> Result<Key32> {
        let shared = self.secret.diffie_hellman(other);
        if !shared.was_contributory() {
            bail!("peer sent a low-order public key");
        }
        Ok(*shared.as_bytes())
    }
}

/// Short human-checkable form of a public key.
pub fn fingerprint(public: &Key32) -> String {
    let digest = Sha256::digest(public);
    hex::encode_upper(&digest[..4])
}

/// The clients (or hosts) this side has paired with: key -> name.
pub struct PeerList {
    path: PathBuf,
    peers: HashMap<Key32, String>,
}

impl PeerList {
    pub fn load(path: &Path) -> Result<Self> {
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
        Ok(PeerList {
            path: path.to_path_buf(),
            peers,
        })
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

    fn save(&self) -> Result<()> {
        if let Some(dir) = self.path.parent() {
            fs::create_dir_all(dir)?;
        }
        let mut text = String::new();
        for (key, name) in &self.peers {
            text.push_str(&format!("{} {}\n", hex::encode(key), name));
        }
        fs::write(&self.path, text).with_context(|| format!("writing {}", self.path.display()))
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

// ---------------------------------------------------------------------------
// Key agreement
// ---------------------------------------------------------------------------

/// Keys for one connection.
pub struct SessionKeys {
    pub c2h: Key32,
    pub h2c: Key32,
    pub pair: Key32,
}

fn derive(transcript: &[u8], dh: [Key32; 3]) -> SessionKeys {
    let th = Sha256::digest(transcript);
    let mut ikm = Vec::with_capacity(96);
    for d in &dh {
        ikm.extend_from_slice(d);
    }
    let hk = Hkdf::<Sha256>::new(Some(&th), &ikm);
    let mut okm = [0u8; 96];
    hk.expand(HKDF_INFO, &mut okm)
        .expect("96 bytes is a valid HKDF length");
    SessionKeys {
        c2h: okm[0..32].try_into().unwrap(),
        h2c: okm[32..64].try_into().unwrap(),
        pair: okm[64..96].try_into().unwrap(),
    }
}

fn msg1_bytes(client_static: &PublicKey, client_eph: &PublicKey) -> Vec<u8> {
    let mut m = Vec::with_capacity(70);
    m.extend_from_slice(MAGIC);
    m.extend_from_slice(&HANDSHAKE_VERSION.to_be_bytes());
    m.extend_from_slice(client_static.as_bytes());
    m.extend_from_slice(client_eph.as_bytes());
    m
}

fn msg2_bytes(host_static: &PublicKey, host_eph: &PublicKey, paired: bool) -> Vec<u8> {
    let mut m = Vec::with_capacity(71);
    m.extend_from_slice(MAGIC);
    m.extend_from_slice(&HANDSHAKE_VERSION.to_be_bytes());
    m.extend_from_slice(host_static.as_bytes());
    m.extend_from_slice(host_eph.as_bytes());
    m.push(paired as u8);
    m
}

fn write_frame(w: &mut impl Write, body: &[u8]) -> io::Result<()> {
    w.write_all(&(body.len() as u32).to_be_bytes())?;
    w.write_all(body)
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

fn parse_hello(
    body: &[u8],
    expected_len: usize,
    what: &str,
) -> Result<(PublicKey, PublicKey, Option<bool>)> {
    if body.len() != expected_len || &body[..4] != MAGIC {
        bail!("{what}: not a Relay v2 handshake");
    }
    let version = u16::from_be_bytes([body[4], body[5]]);
    if version != HANDSHAKE_VERSION {
        bail!("{what}: handshake version {version}, this side speaks {HANDSHAKE_VERSION}");
    }
    let stat: Key32 = body[6..38].try_into().unwrap();
    let eph: Key32 = body[38..70].try_into().unwrap();
    let paired = body.get(70).map(|b| *b != 0);
    Ok((PublicKey::from(stat), PublicKey::from(eph), paired))
}

/// Outcome of a handshake, for either role.
pub struct Handshake {
    pub keys: SessionKeys,
    /// The other side's identity key.
    pub peer: Key32,
    /// Whether the host considers the client paired.
    pub paired: bool,
}

/// Host side: answer a client's msg1, derive keys.
pub fn host_handshake(
    stream: &mut TcpStream,
    identity: &Identity,
    paired: &PeerList,
) -> Result<Handshake> {
    let msg1 = read_frame(stream, 70).context("reading client hello")?;
    let (client_static, client_eph, _) = parse_hello(&msg1, 70, "client hello")?;
    let is_paired = paired.contains(client_static.as_bytes());

    let eph = Identity::generate();
    let msg2 = msg2_bytes(&identity.public, &eph.public, is_paired);
    write_frame(stream, &msg2).context("sending host hello")?;

    let dh = [
        eph.dh(&client_eph)?,      // E_c · E_h
        identity.dh(&client_eph)?, // E_c · S_h
        eph.dh(&client_static)?,   // S_c · E_h
    ];
    let mut transcript = msg1;
    transcript.extend_from_slice(&msg2);
    Ok(Handshake {
        keys: derive(&transcript, dh),
        peer: *client_static.as_bytes(),
        paired: is_paired,
    })
}

/// Client side: send msg1, read msg2, derive keys. If `expected_host` is given
/// (a host paired with before) the host's identity must match it.
pub fn client_handshake(
    stream: &mut TcpStream,
    identity: &Identity,
    expected_host: Option<&Key32>,
) -> Result<Handshake> {
    let eph = Identity::generate();
    let msg1 = msg1_bytes(&identity.public, &eph.public);
    write_frame(stream, &msg1).context("sending client hello")?;
    let msg2 = read_frame(stream, 71).context("reading host hello")?;
    let (host_static, host_eph, paired) = parse_hello(&msg2, 71, "host hello")?;
    if let Some(expected) = expected_host {
        if expected != host_static.as_bytes() {
            bail!(
                "host identity changed: expected {}, got {} (re-pair if this is intended)",
                fingerprint(expected),
                fingerprint(host_static.as_bytes())
            );
        }
    }
    let dh = [
        eph.dh(&host_eph)?,      // E_c · E_h
        eph.dh(&host_static)?,   // E_c · S_h
        identity.dh(&host_eph)?, // S_c · E_h
    ];
    let mut transcript = msg1;
    transcript.extend_from_slice(&msg2);
    Ok(Handshake {
        keys: derive(&transcript, dh),
        peer: *host_static.as_bytes(),
        paired: paired.unwrap_or(false),
    })
}

/// What a client sends to pair: proof of the PIN bound to this session.
pub fn pin_proof(pair_key: &Key32, pin: &str) -> Key32 {
    let mut mac = <Hmac<Sha256> as Mac>::new_from_slice(pair_key).expect("any key length is fine");
    mac.update(PIN_PREFIX);
    mac.update(pin.as_bytes());
    mac.finalize().into_bytes().into()
}

pub fn verify_pin_proof(pair_key: &Key32, pin: &str, proof: &[u8]) -> bool {
    let mut mac = <Hmac<Sha256> as Mac>::new_from_slice(pair_key).expect("any key length is fine");
    mac.update(PIN_PREFIX);
    mac.update(pin.as_bytes());
    mac.verify_slice(proof).is_ok()
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

    pub fn record_failure(&mut self) {
        self.failures.push(Instant::now());
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
// Encrypted message framing
// ---------------------------------------------------------------------------

fn nonce(counter: u64) -> Nonce {
    let mut n = [0u8; 12];
    n[4..].copy_from_slice(&counter.to_be_bytes());
    Nonce::from(n)
}

/// Sends protocol messages encrypted under one direction's key.
pub struct SecureWriter {
    stream: TcpStream,
    cipher: ChaCha20Poly1305,
    counter: u64,
}

impl SecureWriter {
    pub fn new(stream: TcpStream, key: &Key32) -> Self {
        SecureWriter {
            stream,
            cipher: ChaCha20Poly1305::new(key.into()),
            counter: 0,
        }
    }

    fn send_plaintext(&mut self, plaintext: &[u8]) -> io::Result<()> {
        let ct = self
            .cipher
            .encrypt(&nonce(self.counter), plaintext)
            .map_err(|_| io::Error::other("encryption failed"))?;
        self.counter += 1;
        write_frame(&mut self.stream, &ct)
    }

    pub fn send(&mut self, ty: u8, flags: u8, payload: &[u8]) -> io::Result<()> {
        let mut pt = Vec::with_capacity(8 + payload.len());
        protocol::push_header(&mut pt, ty, flags, payload.len());
        pt.extend_from_slice(payload);
        self.send_plaintext(&pt)
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

/// Receives protocol messages encrypted under one direction's key.
pub struct SecureReader {
    stream: io::BufReader<TcpStream>,
    cipher: ChaCha20Poly1305,
    counter: u64,
}

impl SecureReader {
    pub fn new(stream: TcpStream, key: &Key32) -> Self {
        SecureReader {
            stream: io::BufReader::with_capacity(256 * 1024, stream),
            cipher: ChaCha20Poly1305::new(key.into()),
            counter: 0,
        }
    }

    pub fn set_read_timeout(&self, timeout: Option<Duration>) -> io::Result<()> {
        self.stream.get_ref().set_read_timeout(timeout)
    }

    /// Next message as (type, flags, payload).
    pub fn recv(&mut self) -> io::Result<(u8, u8, Vec<u8>)> {
        let ct = read_frame(&mut self.stream, MAX_PAYLOAD as usize + 8 + TAG_LEN)?;
        let pt = self
            .cipher
            .decrypt(&nonce(self.counter), ct.as_slice())
            .map_err(|_| {
                io::Error::new(io::ErrorKind::InvalidData, "message failed authentication")
            })?;
        self.counter += 1;
        if pt.len() < 8 {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "short message"));
        }
        let len = u32::from_be_bytes([pt[4], pt[5], pt[6], pt[7]]) as usize;
        if pt.len() != 8 + len {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "message length mismatch",
            ));
        }
        Ok((pt[0], pt[1], pt[8..].to_vec()))
    }
}

/// Client-side pairing exchange after the handshake: send the PIN proof and
/// wait for the verdict.
pub fn pair_as_client(
    writer: &mut SecureWriter,
    reader: &mut SecureReader,
    keys: &SessionKeys,
    pin: &str,
) -> Result<()> {
    writer.send(msg::PAIR, 0, &pin_proof(&keys.pair, pin))?;
    let (ty, _, payload) = reader.recv().context("waiting for the pairing result")?;
    if ty == msg::STREAM_STOP && payload.first() == Some(&protocol::stop_reason::BUSY) {
        bail!("the host is busy with another client");
    }
    if ty != msg::PAIR_RESULT {
        bail!("expected PAIR_RESULT, got 0x{ty:02x}");
    }
    match payload.first() {
        Some(&pair_result::PAIRED) => Ok(()),
        Some(&pair_result::RATE_LIMITED) => {
            let secs = payload
                .get(1..3)
                .map(|b| u16::from_be_bytes([b[0], b[1]]))
                .unwrap_or(0);
            bail!("the host is refusing PINs after too many failures; try again in {secs} s")
        }
        _ => bail!("the host rejected the PIN"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;
    use std::thread;

    #[test]
    fn keys_match_and_transcript_binds_them() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let host_id = Identity::generate();
        let client_id = Identity::generate();
        let host_pub = *host_id.public.as_bytes();
        let client_pub = *client_id.public.as_bytes();
        let dir = std::env::temp_dir().join(format!("td-peers-{}", std::process::id()));
        let paired = PeerList::load(&dir.join("none.txt")).unwrap();

        let host = thread::spawn(move || {
            let (mut s, _) = listener.accept().unwrap();
            host_handshake(&mut s, &host_id, &paired).unwrap()
        });
        let mut c = TcpStream::connect(addr).unwrap();
        let client = client_handshake(&mut c, &client_id, None).unwrap();
        let host = host.join().unwrap();

        assert_eq!(client.keys.c2h, host.keys.c2h);
        assert_eq!(client.keys.h2c, host.keys.h2c);
        assert_eq!(client.keys.pair, host.keys.pair);
        assert_ne!(client.keys.c2h, client.keys.h2c);
        assert_eq!(client.peer, host_pub);
        assert_eq!(host.peer, client_pub);
        assert!(!host.paired && !client.paired);
        assert!(verify_pin_proof(
            &host.keys.pair,
            "123456",
            &pin_proof(&client.keys.pair, "123456")
        ));
        assert!(!verify_pin_proof(
            &host.keys.pair,
            "123457",
            &pin_proof(&client.keys.pair, "123456")
        ));
    }

    #[test]
    fn client_rejects_a_different_host_identity() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let host_id = Identity::generate();
        let dir = std::env::temp_dir().join(format!("td-peers2-{}", std::process::id()));
        let paired = PeerList::load(&dir.join("none.txt")).unwrap();
        thread::spawn(move || {
            let (mut s, _) = listener.accept().unwrap();
            let _ = host_handshake(&mut s, &host_id, &paired);
        });
        let mut c = TcpStream::connect(addr).unwrap();
        let other = *Identity::generate().public.as_bytes();
        let err = match client_handshake(&mut c, &Identity::generate(), Some(&other)) {
            Ok(_) => panic!("handshake must fail for a different host identity"),
            Err(e) => e,
        };
        assert!(err.to_string().contains("host identity changed"));
    }

    #[test]
    fn encrypted_frames_round_trip_and_detect_tampering() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let key = [7u8; 32];
        let server = thread::spawn(move || {
            let (s, _) = listener.accept().unwrap();
            let mut r = SecureReader::new(s, &key);
            let a = r.recv().unwrap();
            let b = r.recv().unwrap();
            (a, b)
        });
        let s = TcpStream::connect(addr).unwrap();
        let mut w = SecureWriter::new(s, &key);
        w.send(0x04, 0x01, b"frame").unwrap();
        w.send_nals(0x03, 0, &[vec![1, 2], vec![3]]).unwrap();
        let (a, b) = server.join().unwrap();
        assert_eq!(a, (0x04, 0x01, b"frame".to_vec()));
        assert_eq!(b, (0x03, 0, vec![0, 0, 0, 2, 1, 2, 0, 0, 0, 1, 3]));

        // Same bytes under a different key (or replayed with the wrong counter) fail.
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = listener.local_addr().unwrap();
        let server = thread::spawn(move || {
            let (s, _) = listener.accept().unwrap();
            let mut r = SecureReader::new(s, &[8u8; 32]);
            r.recv().is_err()
        });
        let mut w = SecureWriter::new(TcpStream::connect(addr).unwrap(), &key);
        w.send(0x04, 0, b"x").unwrap();
        assert!(server.join().unwrap());
    }

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
}

#[cfg(test)]
mod vectors {
    //! Deterministic vector so the Swift implementation can be checked against
    //! this one: fixed identity/ephemeral secrets on both sides.
    use super::*;

    #[test]
    fn known_answer() {
        let client_static = Identity::from_bytes([0x11; 32]);
        let client_eph = Identity::from_bytes([0x22; 32]);
        let host_static = Identity::from_bytes([0x33; 32]);
        let host_eph = Identity::from_bytes([0x44; 32]);
        let msg1 = msg1_bytes(&client_static.public, &client_eph.public);
        let msg2 = msg2_bytes(&host_static.public, &host_eph.public, false);
        let dh = [
            client_eph.dh(&host_eph.public).unwrap(),
            client_eph.dh(&host_static.public).unwrap(),
            client_static.dh(&host_eph.public).unwrap(),
        ];
        let mut transcript = msg1.clone();
        transcript.extend_from_slice(&msg2);
        let keys = derive(&transcript, dh);
        // Values documented in docs/PROTOCOL.md; a Swift implementation must reproduce them.
        assert_eq!(hex::encode(&msg1), "5444483200027b4e909bbe7ffe44c465a220037d608ee35897d31ef972f07f74892cb0f73f130faa684ed28867b97f4a6a2dee5df8ce974e76b7018e3f22a1c4cf2678570f20");
        assert_eq!(hex::encode(&msg2), "5444483200027b0d47d93427f8311160781c7c733fd89f88970aef490d8aa0ee19a4cb8a1b14ff2ee45601ec1b67310c7790404585ae697331eee1c1f8cf2419731c1fff3e6b00");
        assert_eq!(
            hex::encode(keys.c2h),
            "d8a97f4a0b7c64b0be967bbc40644991d83dc7e8660ee9c1afdfabe570be86a5"
        );
        assert_eq!(
            hex::encode(keys.h2c),
            "f62792bb52e27a09c5932048f06bf373e6a680cf3d7ea78693e394d426405c9b"
        );
        assert_eq!(
            hex::encode(keys.pair),
            "abcb29c363b089c882c6c4a4fe0d815fed0c48b0ab99fcf8a968b953e83f029f"
        );
        assert_eq!(
            hex::encode(pin_proof(&keys.pair, "123456")),
            "11ef35ab8b2347a264019c1995103913f92db8ef3080cea0407a04bd6adcc397"
        );
        let cipher = ChaCha20Poly1305::new((&keys.c2h).into());
        let mut pt = Vec::new();
        protocol::push_header(&mut pt, msg::PAIR, 0, 32);
        pt.extend_from_slice(&pin_proof(&keys.pair, "123456"));
        let ct = cipher.encrypt(&nonce(0), pt.as_slice()).unwrap();
        assert_eq!(hex::encode(&ct), "47de84ee17d1168e959caa9768dd9532bdb13b964fbc3a614f30f853a16741f1270b1867ff11f18833740b2f1f5aa82d66b3c34c85db1f7c");
    }
}
