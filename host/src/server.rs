//! TCP server and per-connection session: hello exchange, virtual display
//! lifecycle, encoder pump, input reader, keep-alive pings.

use std::net::{SocketAddr, TcpListener, TcpStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Context, Result};
use socket2::{Domain, Protocol, Socket, Type};
use windows::Win32::System::Power::{SetThreadExecutionState, ES_CONTINUOUS, ES_SYSTEM_REQUIRED};

use crate::crypto::{self, Identity, PairLimiter, PeerList, SecureReader, SecureWriter};
use crate::display::{self, Mode, Monitor, OutputLocation, Placement};
use crate::driver::{Attachment, VirtualDisplay};
use crate::encoder::{Encoder, EncoderConfig, Quality};
use crate::gpu::GpuInfo;
use crate::input::Injector;
use crate::protocol::{
    self, msg, stop_reason, ClientHello, Codec, FrameTiming, FLAG_KEYFRAME, UNKNOWN_MICROS,
};
use crate::status::{HostStatus, SessionInfo};
use crate::topology;

const HELLO_TIMEOUT: Duration = Duration::from_secs(5);
/// A human may be reading the PIN off the PC and typing it on the Mac.
const PAIR_TIMEOUT: Duration = Duration::from_secs(120);
const PING_INTERVAL: Duration = Duration::from_secs(1);
const PONG_TIMEOUT: Duration = Duration::from_secs(5);
/// Enough samples for responsive rolling stats without adding a second network
/// message to every video frame.
const FRAME_TIMING_INTERVAL: u64 = 4;
/// Longest a single encrypted frame write may block before the client is
/// treated as stalled. Bounds `pump` so a wedged client cannot freeze it.
const SEND_TIMEOUT: Duration = Duration::from_secs(5);
const ENCODER_RESTART_DELAY: Duration = Duration::from_millis(250);
const ENCODER_RECOVERY_TIMEOUT: Duration = Duration::from_secs(15);
/// Between capture attempts while the desktop refuses us (locked). The
/// client keeps its last picture; input still flows so the PC can be unlocked.
const DESKTOP_RETRY: Duration = Duration::from_secs(2);
/// Let a game's fullscreen modeset finish before we touch display config.
const RECOVERY_SETTLE: Duration = Duration::from_millis(750);
/// Never reassert the virtual-only topology more often than this.
const REASSERT_MIN_INTERVAL: Duration = Duration::from_secs(2);

#[derive(Clone)]
pub struct ServerConfig {
    pub port: u16,
    pub name: String,
    pub ffmpeg: PathBuf,
    pub bitrate_mbps: u32,
    pub fps: Option<u32>,
    pub codec: Codec,
    pub gop_seconds: u32,
    pub quality: Quality,
    pub intra_refresh: bool,
    /// Force the ffmpeg encoder path even on NVIDIA (skip the in-process one).
    pub prefer_ffmpeg: bool,
    /// Disable the physical monitor device nodes for the session (keeps games
    /// from reactivating them). Off = only remove them from the desktop.
    pub lock_physical: bool,
    /// GPU that renders the virtual display and encodes the stream.
    pub gpu: GpuInfo,
    /// Dev mode (`None`): stream the primary monitor instead of adding a virtual one.
    pub driver: Option<Arc<dyn VirtualDisplay>>,
    pub allow_input: bool,
    /// This host's long-lived identity key.
    pub identity: Arc<Identity>,
    /// Clients that have paired (persisted).
    pub paired: Arc<Mutex<PeerList>>,
    /// The pairing PIN and the session in progress, shared with the tray.
    pub status: Arc<Mutex<HostStatus>>,
    pub pair_limiter: Arc<Mutex<PairLimiter>>,
    /// Where `run` parks the mDNS record so a quit can withdraw it.
    pub advertisement: crate::discovery::AdSlot,
}

pub fn run(cfg: ServerConfig) -> Result<()> {
    let listener = bind_dual_stack(cfg.port)?;
    let facts = crate::sysinfo::HostFacts::gather(&cfg.gpu);
    log::info!(
        "advertising facts: cpu '{}', {} GB {}, gpu '{}' {} GB, os '{}', ip {:?}",
        facts.cpu,
        facts.ram_gb,
        facts.ram_type,
        facts.gpu,
        facts.vram_gb,
        facts.os,
        facts.ips
    );
    let ad =
        crate::discovery::advertise(&cfg.name, cfg.port, cfg.identity.public.as_bytes(), &facts)?;
    *cfg.advertisement.lock().unwrap() = Some(ad);
    log::info!("listening on [::]:{} (dual-stack)", cfg.port);
    let _readvertiser = readvertise_on_address_change(facts, &cfg);

    loop {
        let (stream, peer) = match listener.accept() {
            Ok(x) => x,
            Err(e) => {
                log::warn!("accept failed: {e}");
                continue;
            }
        };
        log::info!("client connected from {peer}");
        match handle_session(&cfg, stream, peer) {
            Ok(()) => log::info!("session with {peer} ended"),
            Err(e) => log::warn!("session with {peer} ended with error: {e:#}"),
        }
        // Cleared here rather than in `handle_session` so every exit path,
        // including `?`, leaves the tray showing "Idle".
        cfg.status.lock().unwrap().session = None;
    }
}

/// Keep the advertised `ip` facts current: a cable plugged in after start
/// (Windows takes a while to self-assign 169.254.x.x) or a move between
/// switch and cable changes the addresses, and the TXT record is static
/// once registered, so re-register when they differ. Polling every few
/// seconds is plenty and avoids the IP Helper notification machinery.
fn readvertise_on_address_change(
    mut facts: crate::sysinfo::HostFacts,
    cfg: &ServerConfig,
) -> thread::JoinHandle<()> {
    let name = cfg.name.clone();
    let port = cfg.port;
    let public_key = *cfg.identity.public.as_bytes();
    let slot = Arc::clone(&cfg.advertisement);
    thread::Builder::new()
        .name("readvertise".into())
        .spawn(move || loop {
            thread::sleep(Duration::from_secs(5));
            let ips = crate::sysinfo::ipv4_addresses();
            if ips == facts.ips {
                continue;
            }
            log::info!(
                "addresses changed {:?} -> {:?}; re-advertising",
                facts.ips,
                ips
            );
            facts.ips = ips;
            // Hold the slot across the swap so a quit in between cannot
            // miss the new record.
            let mut ad = slot.lock().unwrap();
            drop(ad.take()); // unregisters the old record first
            match crate::discovery::advertise(&name, port, &public_key, &facts) {
                Ok(new_ad) => *ad = Some(new_ad),
                Err(e) => log::warn!("re-advertising failed: {e:#}"),
            }
        })
        .expect("spawn readvertise thread")
}

fn bind_dual_stack(port: u16) -> Result<TcpListener> {
    let socket = Socket::new(Domain::IPV6, Type::STREAM, Some(Protocol::TCP))?;
    socket.set_only_v6(false)?;
    socket.set_reuse_address(true)?;
    let addr: SocketAddr = format!("[::]:{port}").parse()?;
    socket
        .bind(&addr.into())
        .with_context(|| format!("binding TCP port {port}"))?;
    socket.listen(4)?;
    Ok(socket.into())
}

/// Keeps the PC awake while a client is connected. Do not request
/// `ES_DISPLAY_REQUIRED`: it applies to every physical connector and can wake
/// monitors that Relay has deliberately removed from the desktop.
/// Per-thread state, so this must live on the session thread.
struct KeepAwake;

impl KeepAwake {
    fn new() -> Self {
        unsafe {
            SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED);
        }
        KeepAwake
    }
}

impl Drop for KeepAwake {
    fn drop(&mut self) {
        unsafe {
            SetThreadExecutionState(ES_CONTINUOUS);
        }
    }
}

/// Everything that has to be undone when the session ends, in order: the
/// user's display layout comes back first, then the virtual monitor goes away.
struct DisplayLease {
    driver: Option<(Arc<dyn VirtualDisplay>, Attachment)>,
    snapshot: Option<topology::Snapshot>,
    monitor: Monitor,
}

impl Drop for DisplayLease {
    fn drop(&mut self) {
        if let Some((driver, _)) = &self.driver {
            if let Err(e) = driver.unlock_physical_outputs() {
                log::warn!("could not re-enable physical monitor devices: {e:#}");
            }
        }
        let restored = self.snapshot.take().is_none_or(|snapshot| {
            match snapshot.restore() {
                Ok(()) => true,
                Err(e) => {
                    // Keep the on-disk snapshot: the next host start or the
                    // `restore` command must still be able to retry it.
                    log::warn!("could not restore the display layout: {e:#}");
                    false
                }
            }
        });
        if let Some((driver, attachment)) = self.driver.take() {
            if let Err(e) = driver.detach(attachment) {
                log::warn!(
                    "failed to remove virtual display {}: {e:#}",
                    self.monitor.device_name
                );
            }
        }
        if restored {
            topology::Snapshot::clear_saved();
        }
    }
}

/// Where the stream comes from once the display exists. Dropping it ends the
/// session's claim on the displays.
pub struct Source {
    lease: DisplayLease,
    pub placement: Placement,
    pub location: OutputLocation,
}

impl Source {
    pub fn monitor(&self) -> &Monitor {
        &self.lease.monitor
    }

    /// Games can ask Windows to restore a display topology when entering or
    /// leaving fullscreen.  Keep the virtual monitor as the only output and
    /// then rediscover its DXGI index, which may change after any mode switch.
    ///
    /// `may_reassert` gates the one heavy, dangerous step — forcing a
    /// virtual-only topology with `topology::exclusive`. The caller only sets it
    /// once the game's own fullscreen modeset has had time to settle and not
    /// more than once every couple of seconds, so we never trade blows with an
    /// in-flight display change (that fight hard-froze the whole machine).
    /// Returns `true` when it actually reasserted the topology.
    fn recover_exclusive(
        &mut self,
        driver: Option<&Arc<dyn VirtualDisplay>>,
        gpu: &GpuInfo,
        want: Mode,
        may_reassert: bool,
    ) -> Result<bool> {
        let Some(driver) = driver else {
            self.placement = display::current_placement(&self.lease.monitor.device_name)?;
            self.location = display::dxgi_output_for(&self.lease.monitor.device_name)?;
            return Ok(false);
        };

        let pnp_id = driver.pnp_id();
        let attached: Vec<Monitor> = display::enumerate()
            .into_iter()
            .filter(|monitor| monitor.attached)
            .collect();
        let virtual_monitor = attached
            .iter()
            .find(|monitor| monitor.has_pnp_id(pnp_id))
            .cloned();
        let physical: Vec<&str> = attached
            .iter()
            .filter(|monitor| !monitor.has_pnp_id(pnp_id))
            .map(|monitor| monitor.device_name.as_str())
            .collect();
        let mode_is_correct = virtual_monitor
            .as_ref()
            .and_then(|monitor| display::current_placement(&monitor.device_name).ok())
            .is_some_and(|placement| {
                placement.x == 0
                    && placement.y == 0
                    && placement.width == want.width
                    && placement.height == want.height
                    && placement.hz == want.hz
            });

        let (monitor, reasserted) = match virtual_monitor {
            Some(monitor) if physical.is_empty() && mode_is_correct => (monitor, false),
            _ if !may_reassert => {
                // The topology is not right yet, but it is not our turn to touch
                // display config. Let the caller wait and retry rather than fight
                // the game's in-flight fullscreen modeset.
                bail!("virtual-only topology not restored yet; waiting before reasserting");
            }
            _ => {
                log::warn!(
                    "display topology changed during capture (physical displays active: {}); reasserting virtual-only {}x{}@{}",
                    if physical.is_empty() { "none".to_string() } else { physical.join(", ") },
                    want.width,
                    want.height,
                    want.hz
                );
                (topology::exclusive(pnp_id, want)?, true)
            }
        };

        let placement = display::current_placement(&monitor.device_name)?;
        if (placement.width, placement.height, placement.hz) != (want.width, want.height, want.hz) {
            bail!(
                "virtual display recovered at {}x{}@{} instead of {}x{}@{}",
                placement.width,
                placement.height,
                placement.hz,
                want.width,
                want.height,
                want.hz
            );
        }
        let location = display::dxgi_output_for(&monitor.device_name)?;
        if location.adapter_luid != gpu.luid {
            bail!(
                "recovered virtual display moved to '{}' instead of selected GPU '{}'",
                location.adapter_name,
                gpu.name
            );
        }
        self.lease.monitor = monitor;
        self.placement = placement;
        self.location = location;
        Ok(reasserted)
    }
}

/// Create the virtual display for a session and make it the only active one,
/// or (dev mode, `driver == None`) pick the primary monitor as-is.
pub fn acquire_display(
    driver: Option<&Arc<dyn VirtualDisplay>>,
    gpu: &GpuInfo,
    want: Mode,
    lock_physical: bool,
) -> Result<Source> {
    let Some(driver) = driver else {
        let monitor = display::primary().ok_or_else(|| anyhow!("no primary display"))?;
        let placement = display::current_placement(&monitor.device_name)?;
        let location = display::dxgi_output_for(&monitor.device_name)?;
        log::info!(
            "dev mode: streaming primary display {} ({}x{}@{}) on {}",
            monitor.device_name,
            placement.width,
            placement.height,
            placement.hz,
            location.adapter_name
        );
        return Ok(Source {
            lease: DisplayLease {
                driver: None,
                snapshot: None,
                monitor,
            },
            placement,
            location,
        });
    };

    // The snapshot must describe the user's own layout: a virtual monitor that
    // is still on the desktop from an earlier session must not end up in it.
    let is_virtual = |m: &Monitor| driver.is_virtual(m);
    for m in display::attached_matching(&is_virtual) {
        log::info!(
            "removing leftover virtual display {} before snapshotting",
            m.device_name
        );
        display::detach_display(&m.device_name)?;
    }
    let snapshot = topology::Snapshot::take()?;
    snapshot.save()?;
    log::info!("display layout saved: {}", snapshot.describe());

    let (attachment, monitor) = driver.attach(want, gpu)?;
    // From here on the lease guarantees restore + removal even if activation fails.
    let mut lease = DisplayLease {
        driver: Some((Arc::clone(driver), attachment)),
        snapshot: Some(snapshot),
        monitor,
    };

    let monitor = topology::exclusive(driver.pnp_id(), want)?;
    lease.monitor = monitor;
    if lock_physical {
        driver.lock_physical_outputs()?;
    } else {
        log::info!("physical monitor device lock disabled (--no-lock-physical)");
    }
    let name = lease.monitor.device_name.clone();
    let placement = display::current_placement(&name)?;
    if (placement.width, placement.height, placement.hz) != (want.width, want.height, want.hz) {
        if driver.dynamic_modes() {
            log::warn!(
                "asked {} for {}x{}@{} but got {}x{}@{} — check the driver's settings file",
                driver.name(),
                want.width,
                want.height,
                want.hz,
                placement.width,
                placement.height,
                placement.hz
            );
        } else {
            log::warn!(
                "client asked for {}x{}@{}, closest registered mode is {}x{}@{} \
                 ({} cannot create modes on demand)",
                want.width,
                want.height,
                want.hz,
                placement.width,
                placement.height,
                placement.hz,
                driver.name()
            );
        }
    }
    let location = display::dxgi_output_for(&name)?;
    if location.adapter_luid != gpu.luid {
        log::warn!(
            "virtual display {} is rendered by '{}' instead of the selected '{}'; \
             capture will be copied to the encoder through system memory",
            name,
            location.adapter_name,
            gpu.name
        );
    }
    log::info!(
        "virtual display {} is the only display: {}x{}@{} at ({}, {}) on {} (DXGI adapter {}, output {})",
        name, placement.width, placement.height, placement.hz, placement.x, placement.y,
        location.adapter_name, location.adapter_index, location.output_index
    );
    Ok(Source {
        lease,
        placement,
        location,
    })
}

fn handle_session(cfg: &ServerConfig, mut stream: TcpStream, peer: SocketAddr) -> Result<()> {
    stream.set_nodelay(true)?;
    stream.set_read_timeout(Some(HELLO_TIMEOUT))?;
    // A stalled client (e.g. its decoder wedges at a game's fullscreen match
    // load) must never block the send loop indefinitely: without this, a full
    // socket send buffer hangs `pump` inside `send_nals`, the stats go silent,
    // and the display lease never drops to restore the physical monitors. With
    // it, a stuck write fails, the session ends, and the layout comes back.
    stream.set_write_timeout(Some(SEND_TIMEOUT))?;

    // --- key agreement, then pairing if this client is new ------------------
    let hs = crypto::host_handshake(&mut stream, &cfg.identity, &cfg.paired.lock().unwrap())
        .context("handshake")?;
    let mut tx = SecureWriter::new(stream.try_clone()?, &hs.keys.h2c);
    let mut rx = SecureReader::new(stream, &hs.keys.c2h);
    let client_fp = crypto::fingerprint(&hs.peer);
    tx.send(msg::SERVER_HELLO, 0, &protocol::server_hello(&cfg.name))?;

    // A known client may still send a PIN (it lost its copy of our key); an unknown one must.
    if !hs.paired {
        log::info!("unpaired client {client_fp} from {peer}: waiting for the PIN");
        rx.set_read_timeout(Some(PAIR_TIMEOUT))?;
    }
    let (mut ty, mut flags, mut payload) = rx.recv().context("waiting for the first message")?;
    if ty == msg::PAIR {
        let proof = payload;
        let mut limiter = cfg.pair_limiter.lock().unwrap();
        if !limiter.allowed() {
            tx.send(msg::PAIR_RESULT, 0, &[0])?;
            bail!("pairing refused for {client_fp}: too many failed PINs recently");
        }
        let pin = cfg.status.lock().unwrap().pin.clone();
        if !crypto::verify_pin_proof(&hs.keys.pair, &pin, &proof) {
            limiter.record_failure();
            tx.send(msg::PAIR_RESULT, 0, &[0])?;
            bail!("wrong PIN from {client_fp} at {peer}");
        }
        drop(limiter);
        if !hs.paired {
            cfg.paired
                .lock()
                .unwrap()
                .add(hs.peer, &format!("paired {}", peer.ip()))?;
        }
        tx.send(msg::PAIR_RESULT, 0, &[1])?;
        log::info!("paired client {client_fp}");
        // Each PIN admits one Mac: a PIN that was read off the screen (or out
        // of a log) stops being useful the moment it has done its job.
        match cfg.status.lock().unwrap().rotate_pin() {
            Ok(true) => log::info!("pairing PIN rotated"),
            Ok(false) => {}
            Err(e) => log::warn!("could not rotate the pairing PIN: {e:#}"),
        }
        (ty, flags, payload) = rx.recv().context("waiting for CLIENT_HELLO")?;
    } else if ty == msg::UNPAIR {
        // The client is forgetting us and asks us to forget it too, so the
        // pairing disappears from both sides at once. Answer even when we
        // never knew it: the outcome is the same either way.
        let removed = cfg.paired.lock().unwrap().remove(&hs.peer)?;
        tx.send(msg::STREAM_STOP, 0, &[stop_reason::UNPAIRED])?;
        log::info!(
            "client {client_fp} unpaired{}",
            if removed { "" } else { " (was not paired)" }
        );
        return Ok(());
    } else if !hs.paired {
        tx.send(msg::STREAM_STOP, 0, &[stop_reason::NOT_PAIRED])?;
        bail!("unpaired client {client_fp} sent 0x{ty:02x} instead of pairing");
    }
    let _ = flags;

    // --- hello exchange -----------------------------------------------------
    if ty != msg::CLIENT_HELLO {
        bail!("expected CLIENT_HELLO, got message type 0x{ty:02x}");
    }
    let hello = ClientHello::parse(&payload).ok_or_else(|| anyhow!("malformed CLIENT_HELLO"))?;
    log::info!(
        "client '{}' ({client_fp}) v{} wants {}x{}@{}Hz, codecs 0b{:03b}, input={}",
        hello.name,
        hello.version,
        hello.width,
        hello.height,
        hello.refresh,
        hello.codecs,
        hello.wants_input
    );
    if hello.version != protocol::VERSION {
        tx.send(msg::STREAM_STOP, 0, &[stop_reason::BAD_VERSION])?;
        bail!("unsupported protocol version {}", hello.version);
    }
    if !hello.name.is_empty() {
        // Remember the client by the name it gives itself.
        let _ = cfg.paired.lock().unwrap().add(hs.peer, &hello.name);
    }
    let codec = if hello.codecs & cfg.codec.bit() != 0 {
        cfg.codec
    } else if hello.codecs & Codec::Hevc.bit() != 0 {
        Codec::Hevc
    } else if hello.codecs & Codec::H264.bit() != 0 {
        Codec::H264
    } else {
        bail!(
            "client supports no codec we can produce (mask 0b{:03b})",
            hello.codecs
        )
    };

    let _awake = KeepAwake::new();
    let want = Mode {
        width: hello.width as u32,
        height: hello.height as u32,
        hz: if hello.refresh == 0 {
            60
        } else {
            hello.refresh as u32
        },
    };
    let mut source = acquire_display(cfg.driver.as_ref(), &cfg.gpu, want, cfg.lock_physical)?;
    let placement = source.placement;
    let fps = cfg.fps.unwrap_or(placement.hz.clamp(30, 240));
    log::info!(
        "capturing {} at {fps} fps, {} {} Mbps via {}",
        source.monitor().device_name,
        if codec == Codec::Hevc {
            "HEVC"
        } else {
            "H.264"
        },
        cfg.bitrate_mbps,
        crate::encoder::encoder_name(cfg.gpu.vendor, codec, cfg.prefer_ffmpeg)
    );

    tx.send(
        msg::STREAM_START,
        0,
        &protocol::stream_start(
            placement.width as u16,
            placement.height as u16,
            fps as u16,
            codec,
        ),
    )?;
    cfg.status.lock().unwrap().session = Some(SessionInfo {
        client: if hello.name.is_empty() {
            client_fp.clone()
        } else {
            hello.name.clone()
        },
        client_key: hs.peer,
        width: placement.width,
        height: placement.height,
        hz: placement.hz,
    });

    let mut encoder_config = EncoderConfig {
        ffmpeg: cfg.ffmpeg.clone(),
        vendor: cfg.gpu.vendor,
        capture_adapter_idx: source.location.adapter_index,
        encode_adapter_idx: cfg.gpu.adapter_index,
        output_idx: source.location.output_index,
        fps,
        bitrate_mbps: cfg.bitrate_mbps,
        codec,
        gop: cfg.gop_seconds.max(1) * fps,
        quality: cfg.quality,
        intra_refresh: cfg.intra_refresh,
        prefer_ffmpeg: cfg.prefer_ffmpeg,
    };
    let mut encoder = match Encoder::spawn(&encoder_config) {
        Ok(e) => e,
        Err(e) if crate::encoder::is_desktop_not_capturable(&e) => {
            log::warn!("{e:#}; the session starts without a picture and retries");
            Encoder::waiting()
        }
        Err(e) => return Err(e),
    };

    // Reader thread: client -> host messages (input, pongs).
    let stop = Arc::new(AtomicBool::new(false));
    let last_pong = Arc::new(Mutex::new(Instant::now()));
    let last_ping_sent = Arc::new(Mutex::new(None));
    let network_rtt = Arc::new(Mutex::new(None));
    rx.set_read_timeout(None)?;
    let reader = {
        let stop = Arc::clone(&stop);
        let last_pong = Arc::clone(&last_pong);
        let last_ping_sent = Arc::clone(&last_ping_sent);
        let network_rtt = Arc::clone(&network_rtt);
        let injector = (cfg.allow_input && hello.wants_input)
            .then(|| Injector::new(placement, cfg.driver.is_some()));
        thread::Builder::new()
            .name(format!("client-rx-{peer}"))
            .spawn(move || {
                // SendInput reaches the secure desktop only from a thread
                // bound to it (and only for a SYSTEM worker).
                if injector.is_some() {
                    if let Ok(name) = crate::desktop::bind_input_desktop() {
                        log::debug!("input thread on the {name} desktop");
                    }
                }
                let r = read_loop(rx, injector, &last_pong, &last_ping_sent, &network_rtt);
                if let Err(e) = r {
                    log::debug!("client reader finished: {e:#}");
                }
                stop.store(true, Ordering::Relaxed);
            })?
    };

    let mut recovery = CaptureRecovery {
        encoder_config: &mut encoder_config,
        source: &mut source,
        driver: cfg.driver.as_ref(),
        gpu: &cfg.gpu,
        want,
    };
    let result = pump(
        &mut tx,
        &mut encoder,
        &mut recovery,
        &stop,
        &last_pong,
        &last_ping_sent,
        &network_rtt,
    );

    tx.shutdown();
    stop.store(true, Ordering::Relaxed);
    drop(encoder);
    let _ = reader.join();
    drop(source);
    result
}

struct CaptureRecovery<'a> {
    encoder_config: &'a mut EncoderConfig,
    source: &'a mut Source,
    driver: Option<&'a Arc<dyn VirtualDisplay>>,
    gpu: &'a GpuInfo,
    want: Mode,
}

/// Host -> client: encoder output plus pings, until something ends the session.
fn pump(
    tx: &mut SecureWriter,
    encoder: &mut Encoder,
    recovery: &mut CaptureRecovery<'_>,
    stop: &AtomicBool,
    last_pong: &Mutex<Instant>,
    last_ping_sent: &Mutex<Option<Instant>>,
    network_rtt: &Mutex<Option<Duration>>,
) -> Result<()> {
    let mut last_config: Vec<Vec<u8>> = Vec::new();
    let mut next_ping = Instant::now() + PING_INTERVAL;
    let mut ping_outstanding: Option<Instant> = None;
    let mut frames: u64 = 0;
    let mut bytes: u64 = 0;
    let mut stats_at = Instant::now();
    let mut encoder_wait = Duration::ZERO;
    let mut send_time = Duration::ZERO;
    let mut max_send = Duration::ZERO;
    let mut recovery_started: Option<Instant> = None;
    // Since when the desktop has refused capture (lock screen).
    let mut desktop_wait: Option<Instant> = None;
    let mut restart_attempts = 0u32;
    let mut last_reassert: Option<Instant> = None;
    let mut frame_sequence = 0u64;

    loop {
        if stop.load(Ordering::Relaxed) {
            return Ok(());
        }
        let read_at = Instant::now();
        let au = match encoder.next_access_unit() {
            Ok(Some(au)) => {
                if let Some(started) = recovery_started.take() {
                    log::info!(
                        "capture recovered after {:.1}s and {restart_attempts} encoder restart(s)",
                        started.elapsed().as_secs_f64()
                    );
                    restart_attempts = 0;
                }
                au
            }
            result => {
                let failure = match result {
                    Ok(None) => "capture backend ended".to_string(),
                    Err(error) => format!("{error:#}"),
                    Ok(Some(_)) => unreachable!(),
                };
                let started = *recovery_started.get_or_insert_with(|| {
                    log::warn!(
                        "capture interrupted ({failure}); keeping the display session active while it recovers"
                    );
                    Instant::now()
                });
                // A locked or secure desktop is not a failure to time out on:
                // the stream resumes when it comes back (unlock, sign-in).
                if desktop_wait.is_some() {
                    recovery_started = Some(Instant::now());
                }
                if started.elapsed() >= ENCODER_RECOVERY_TIMEOUT {
                    let _ = tx.send(msg::STREAM_STOP, 0, &[stop_reason::ENCODER_FAILED]);
                    bail!(
                        "capture did not recover within {ENCODER_RECOVERY_TIMEOUT:?} after {restart_attempts} restart(s): {failure}"
                    );
                }

                maintain_connection(
                    tx,
                    &mut next_ping,
                    &mut ping_outstanding,
                    last_pong,
                    last_ping_sent,
                )?;

                // A fullscreen transition can change both the active monitor
                // set and DXGI output numbering. Let the game's own modeset
                // settle first, then restore the session topology before
                // creating a new Desktop Duplication object. Never reassert the
                // topology more than once every REASSERT_MIN_INTERVAL: two
                // agents modesetting the same virtual display at once can freeze
                // the whole machine.
                thread::sleep(RECOVERY_SETTLE);
                if stop.load(Ordering::Relaxed) {
                    return Ok(());
                }
                let may_reassert =
                    last_reassert.is_none_or(|t| t.elapsed() >= REASSERT_MIN_INTERVAL);
                match recovery.source.recover_exclusive(
                    recovery.driver,
                    recovery.gpu,
                    recovery.want,
                    may_reassert,
                ) {
                    Ok(reasserted) => {
                        if reasserted {
                            last_reassert = Some(Instant::now());
                        }
                    }
                    Err(error) => {
                        log::warn!("display topology recovery is not ready yet: {error:#}");
                        thread::sleep(ENCODER_RESTART_DELAY);
                        continue;
                    }
                }
                recovery.encoder_config.capture_adapter_idx =
                    recovery.source.location.adapter_index;
                recovery.encoder_config.output_idx = recovery.source.location.output_index;
                thread::sleep(ENCODER_RESTART_DELAY);
                if stop.load(Ordering::Relaxed) {
                    return Ok(());
                }
                match encoder.restart(recovery.encoder_config) {
                    Ok(()) => {
                        restart_attempts += 1;
                        // A fresh encoder emits its own parameter sets. Forward
                        // them even if their bytes match the previous process.
                        last_config.clear();
                        if desktop_wait.take().is_some() {
                            log::info!(
                                "desktop capturable again ({})",
                                crate::desktop::input_desktop_name()
                            );
                        }
                    }
                    Err(error) if crate::encoder::is_desktop_not_capturable(&error) => {
                        if desktop_wait.is_none() {
                            log::warn!(
                                "the {} desktop cannot be captured (PC locked, or not running as the Relay service); waiting for it to change",
                                crate::desktop::input_desktop_name()
                            );
                            desktop_wait = Some(Instant::now());
                        }
                        thread::sleep(DESKTOP_RETRY);
                    }
                    Err(error) => {
                        log::debug!("encoder restart failed: {error:#}");
                    }
                }
                continue;
            }
        };

        encoder_wait += read_at.elapsed();
        let send_at = Instant::now();
        if !au.param_sets.is_empty() && au.param_sets != last_config {
            tx.send_nals(msg::CODEC_CONFIG, 0, &au.param_sets)?;
            last_config = au.param_sets.clone();
        }
        let flags = if au.keyframe { FLAG_KEYFRAME } else { 0 };
        tx.send_nals(msg::FRAME, flags, &au.nals)?;
        let frame_send = send_at.elapsed();
        if frame_sequence.is_multiple_of(FRAME_TIMING_INTERVAL) {
            let (capture_us, encode_us) = au
                .timing
                .map_or((UNKNOWN_MICROS, UNKNOWN_MICROS), |timing| {
                    (duration_us(timing.capture), duration_us(timing.encode))
                });
            let timing = FrameTiming {
                sequence: frame_sequence,
                capture_us,
                encode_us,
                send_us: duration_us(frame_send),
                network_rtt_us: network_rtt
                    .lock()
                    .unwrap()
                    .map_or(UNKNOWN_MICROS, duration_us),
            };
            tx.send(msg::FRAME_TIMING, 0, &timing.payload())?;
        }
        frame_sequence = frame_sequence.wrapping_add(1);
        let elapsed = send_at.elapsed();
        send_time += elapsed;
        max_send = max_send.max(elapsed);
        frames += 1;
        bytes += au.nals.iter().map(|n| n.len() as u64).sum::<u64>();

        maintain_connection(
            tx,
            &mut next_ping,
            &mut ping_outstanding,
            last_pong,
            last_ping_sent,
        )?;
        let now = Instant::now();
        if now.duration_since(stats_at) >= Duration::from_secs(5) {
            let secs = now.duration_since(stats_at).as_secs_f64();
            log::info!(
                "{:.1} fps, {:.1} Mbps; encoder wait avg {:.2} ms, encrypt/send avg {:.2} ms, max {:.2} ms",
                frames as f64 / secs,
                bytes as f64 * 8.0 / secs / 1e6,
                encoder_wait.as_secs_f64() * 1000.0 / frames.max(1) as f64,
                send_time.as_secs_f64() * 1000.0 / frames.max(1) as f64,
                max_send.as_secs_f64() * 1000.0
            );
            frames = 0;
            bytes = 0;
            stats_at = now;
            encoder_wait = Duration::ZERO;
            send_time = Duration::ZERO;
            max_send = Duration::ZERO;
        }
    }
}

fn maintain_connection(
    tx: &mut SecureWriter,
    next_ping: &mut Instant,
    ping_outstanding: &mut Option<Instant>,
    last_pong: &Mutex<Instant>,
    last_ping_sent: &Mutex<Option<Instant>>,
) -> Result<()> {
    let now = Instant::now();
    if let Some(sent) = *ping_outstanding {
        if *last_pong.lock().unwrap() >= sent {
            *ping_outstanding = None;
        } else if now.duration_since(sent) > PONG_TIMEOUT {
            bail!("client stopped answering pings");
        } else {
            return Ok(());
        }
    }
    if now < *next_ping {
        return Ok(());
    }
    let us = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_micros() as u64)
        .unwrap_or(0);
    *last_ping_sent.lock().unwrap() = Some(now);
    tx.send(msg::PING, 0, &us.to_be_bytes())?;
    *ping_outstanding = Some(now);
    *next_ping = now + PING_INTERVAL;
    Ok(())
}

fn read_loop(
    mut rx: SecureReader,
    mut injector: Option<Injector>,
    last_pong: &Mutex<Instant>,
    last_ping_sent: &Mutex<Option<Instant>>,
    network_rtt: &Mutex<Option<Duration>>,
) -> Result<()> {
    loop {
        let (ty, _flags, p) = rx.recv()?;
        match ty {
            msg::PONG => {
                *last_pong.lock().unwrap() = Instant::now();
                if let Some(sent) = *last_ping_sent.lock().unwrap() {
                    *network_rtt.lock().unwrap() = Some(sent.elapsed());
                }
            }
            msg::MOUSE_MOVE if p.len() >= 4 => {
                if let Some(inj) = &injector {
                    inj.mouse_move(
                        u16::from_be_bytes([p[0], p[1]]),
                        u16::from_be_bytes([p[2], p[3]]),
                    );
                }
            }
            msg::MOUSE_BUTTON if p.len() >= 2 => {
                if let Some(inj) = injector.as_mut() {
                    inj.mouse_button(p[0], p[1] != 0);
                }
            }
            msg::MOUSE_WHEEL if p.len() >= 4 => {
                if let Some(inj) = &injector {
                    inj.mouse_wheel(
                        i16::from_be_bytes([p[0], p[1]]),
                        i16::from_be_bytes([p[2], p[3]]),
                    );
                }
            }
            msg::KEY if p.len() >= 3 => {
                if let Some(inj) = injector.as_mut() {
                    inj.key(u16::from_be_bytes([p[0], p[1]]), p[2] != 0);
                }
            }
            msg::CLIENT_HELLO => log::debug!("ignoring duplicate CLIENT_HELLO"),
            other => log::debug!("ignoring client message 0x{other:02x} ({} bytes)", p.len()),
        }
    }
}

fn duration_us(duration: Duration) -> u32 {
    duration.as_micros().min(u128::from(u32::MAX - 1)) as u32
}
