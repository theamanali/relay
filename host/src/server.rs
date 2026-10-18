//! TCP server and per-connection session: hello exchange, virtual display
//! lifecycle, encoder pump, input reader, keep-alive pings.

use std::collections::VecDeque;
use std::net::{SocketAddr, TcpListener, TcpStream};
use std::sync::atomic::{AtomicBool, AtomicU8, AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Context, Result};
use socket2::{Domain, Protocol, Socket, Type};
use windows::Win32::System::Power::{SetThreadExecutionState, ES_CONTINUOUS, ES_SYSTEM_REQUIRED};

use crate::crypto::{self, Identity, PairLimiter, PeerList, SecureReader, SecureWriter};
use crate::display::{self, Mode, Monitor, OutputLocation, Placement};
use crate::driver::{Attachment, VirtualDisplay};
use crate::encoder::{Encoder, EncoderConfig, Quality, VideoCaps};
use crate::gpu::{GpuInfo, Luid};
use crate::input::Injector;
use crate::nvenc_caps::{codec_label, EncoderCaps, Requirement};
use crate::protocol::{
    self, msg, stop_reason, video_flags, ClientHello, Codec, FrameTiming, VideoFormat,
    FLAG_KEYFRAME, UNKNOWN_MICROS,
};
use crate::status::{HostStatus, SessionInfo, NO_END_REQUEST};
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
/// A selected bitrate is unsustainable when the sender spends nearly all of
/// this interval writing yet cannot deliver frames at the requested rate.
const CONGESTION_WINDOW: Duration = Duration::from_secs(5);
const CONGESTION_MIN_FPS_RATIO: f64 = 0.95;
const CONGESTION_MIN_SEND_UTILIZATION: f64 = 0.80;
const ENCODER_RESTART_DELAY: Duration = Duration::from_millis(250);
const ENCODER_RECOVERY_TIMEOUT: Duration = Duration::from_secs(15);
/// Between capture attempts while the desktop refuses us (locked). The
/// client keeps its last picture; input still flows so the PC can be unlocked.
const DESKTOP_RETRY: Duration = Duration::from_secs(2);
/// Let a game's fullscreen modeset finish before we touch display config.
const RECOVERY_SETTLE: Duration = Duration::from_millis(750);
/// Never reassert the virtual-only topology more often than this.
const REASSERT_MIN_INTERVAL: Duration = Duration::from_secs(2);
/// After a tray-requested STREAM_STOP, how long to let the client close first.
const END_DRAIN_TIMEOUT: Duration = Duration::from_secs(2);
/// The largest payload accepted from a client. Any peer can finish the
/// handshake without being paired, so this bounds what it can make us
/// buffer; the largest real message (CLIENT_HELLO) is under 300 bytes.
const MAX_CLIENT_PAYLOAD: usize = 4096;
/// Connections handled at once; more are closed as soon as they are accepted.
/// One Mac streaming plus a few pairing, forgetting or checking `pg` fit well
/// under it.
const MAX_CONNECTIONS: usize = 8;

#[derive(Clone)]
pub struct ServerConfig {
    pub port: u16,
    pub name: String,
    /// Explicit administrator override. Without it, CLIENT_HELLO owns bitrate.
    pub bitrate_override_mbps: Option<u16>,
    pub fps: Option<u32>,
    pub codec: Codec,
    pub gop_seconds: u32,
    /// Explicit administrator override, like `bitrate_override_mbps`. Without
    /// it, CLIENT_HELLO's `encoder_quality` decides, else `Quality::Speed`.
    pub quality_override: Option<Quality>,
    /// What the encoder can do (TXT `enc`), found once at startup.
    pub video_caps: VideoCaps,
    /// The selected GPU's NVENC record, queried once at startup; every
    /// session is checked against it before the display is touched.
    pub encoder_caps: EncoderCaps,
    pub intra_refresh: bool,
    /// Disable the physical monitor device nodes for the session (keeps games
    /// from reactivating them). Off = only remove them from the desktop.
    pub lock_physical: bool,
    /// GPU that renders the virtual display and encodes the stream, as
    /// selected at startup; each session selects it again (`session_gpu`).
    pub gpu: GpuInfo,
    /// The `--gpu` the startup selection used, for those re-selections.
    pub gpu_want: Option<String>,
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
    let facts = crate::sysinfo::HostFacts::gather(&cfg.gpu, cfg.video_caps);
    log::info!(
        "advertising facts: cpu '{}', {} GB {}, gpu '{}' {} GB, os '{}', ip {:?}, enc '{}'{}",
        facts.cpu,
        facts.ram_gb,
        facts.ram_type,
        facts.gpu,
        facts.vram_gb,
        facts.os,
        facts.ips,
        facts.encoder_features,
        if cfg.video_caps.hevc {
            ""
        } else {
            " (no HEVC encoder: sessions use H.264)"
        }
    );
    let digest = cfg.paired.lock().unwrap().digest();
    let ad = crate::discovery::advertise(
        &cfg.name,
        cfg.port,
        cfg.identity.public.as_bytes(),
        &facts,
        &digest,
    )?;
    *cfg.advertisement.lock().unwrap() = Some(ad);
    log::info!("listening on [::]:{} (dual-stack)", cfg.port);
    let _readvertiser = readvertise_on_change(facts, digest, &cfg);

    // Every connection gets its own control thread. Pairing and unpairing do
    // not touch the display and may overlap anything; a connection competes
    // for the single display lease only after it sends CLIENT_HELLO.
    let cfg = &cfg;
    let display_claimed = Arc::new(AtomicBool::new(false));
    let connections = Arc::new(AtomicUsize::new(0));
    thread::scope(|s| -> Result<()> {
        loop {
            let (stream, peer) = match listener.accept() {
                Ok(x) => x,
                Err(e) => {
                    log::warn!("accept failed: {e}");
                    continue;
                }
            };
            let Some(slot) = ConnectionSlot::acquire(&connections, MAX_CONNECTIONS) else {
                log::warn!("refused {peer}: {MAX_CONNECTIONS} connections are already open");
                drop(stream);
                continue;
            };
            log::info!("client connected from {peer}");
            let display_claimed = Arc::clone(&display_claimed);
            let spawned = thread::Builder::new()
                .name(format!("client-{peer}"))
                .spawn_scoped(s, move || {
                    let _slot = slot;
                    match handle_session(cfg, stream, peer, &display_claimed) {
                        Ok(()) => log::info!("connection with {peer} ended"),
                        Err(e) => log::warn!("connection with {peer} ended with error: {e:#}"),
                    }
                });
            if let Err(e) = spawned {
                log::warn!("could not start a connection for {peer}: {e}");
            }
        }
    })
}

/// Keep the advertised record current. The TXT record is static once
/// registered, so re-register when something in it moves: the `ip` facts
/// (a cable plugged in after start, Windows' late 169.254 self-assignment, a
/// switch/cable move; checked every 5 s, which avoids the IP Helper
/// notification machinery) or the pairing digest `pg` (checked every second,
/// so a Forget from the tray is on the air about as fast as the Mac can
/// notice). The same tick also picks up an edit of `paired-clients.txt` by
/// another process (`relay-host paired --forget` in a terminal), which the
/// running host would otherwise overwrite on its next save. On the other
/// ticks it sends the few start-up re-announcements of each new record
/// (`Advertisement::reannounce_if_due`; none after the first minute).
fn readvertise_on_change(
    mut facts: crate::sysinfo::HostFacts,
    mut digest: String,
    cfg: &ServerConfig,
) -> thread::JoinHandle<()> {
    let name = cfg.name.clone();
    let port = cfg.port;
    let public_key = *cfg.identity.public.as_bytes();
    let slot = Arc::clone(&cfg.advertisement);
    let paired = Arc::clone(&cfg.paired);
    thread::Builder::new()
        .name("readvertise".into())
        .spawn(move || {
            let mut tick: u32 = 0;
            loop {
                thread::sleep(Duration::from_secs(1));
                tick = tick.wrapping_add(1);
                let mut why = Vec::new();

                let now = {
                    let mut list = paired.lock().unwrap();
                    if list.reload_if_changed() {
                        log::info!(
                            "paired list changed on disk; reloaded ({} client(s))",
                            list.len()
                        );
                    }
                    list.digest()
                };
                if now != digest {
                    why.push(format!("pairing digest {digest} -> {now}"));
                    digest = now;
                }
                if tick.is_multiple_of(5) {
                    let ips = crate::sysinfo::ipv4_addresses();
                    if ips != facts.ips {
                        why.push(format!("addresses {:?} -> {:?}", facts.ips, ips));
                        facts.ips = ips;
                    }
                }
                if why.is_empty() {
                    if let Some(ad) = slot.lock().unwrap().as_mut() {
                        ad.reannounce_if_due(Instant::now());
                    }
                    continue;
                }
                log::info!("{}; re-advertising", why.join(", "));
                // Hold the slot across the swap so a quit in between cannot
                // miss the new record.
                let mut ad = slot.lock().unwrap();
                drop(ad.take()); // unregisters the old record first
                match crate::discovery::advertise(&name, port, &public_key, &facts, &digest) {
                    Ok(new_ad) => *ad = Some(new_ad),
                    Err(e) => log::warn!("re-advertising failed: {e:#}"),
                }
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

/// Keeps the displays on while a client watches without sending input
/// (Observe, or simply not touching the Mac). Windows turns the displays off
/// after its "turn off the display" timeout, and Desktop Duplication then
/// delivers no frames, so the stream would freeze. Capture freshness cannot
/// tell that apart from a desktop that is not changing, so this acts on idle
/// time instead: once the session has had no input for `DISPLAY_NUDGE_AFTER`,
/// it sends the same zero-distance move as `input::wake_displays`. Tested
/// 2026-10-17: the move keeps capture going and the physical monitors the
/// session disabled stay dark. Like any input, it also holds off the screen
/// saver and an inactivity lock while a client is connected.
struct DisplayKeepAlive {
    stop: Arc<AtomicBool>,
    thread: Option<thread::JoinHandle<()>>,
}

/// Below the shortest display-off timeout Windows offers (1 minute).
const DISPLAY_NUDGE_AFTER: Duration = Duration::from_secs(30);
const DISPLAY_IDLE_POLL: Duration = Duration::from_millis(250);

impl DisplayKeepAlive {
    fn start() -> Self {
        let stop = Arc::new(AtomicBool::new(false));
        let thread = {
            let stop = Arc::clone(&stop);
            thread::Builder::new()
                .name("display-keepalive".into())
                .spawn(move || keep_displays_on(&stop))
        };
        let thread = match thread {
            Ok(thread) => Some(thread),
            Err(e) => {
                log::warn!("could not start the display keep-alive: {e}");
                None
            }
        };
        DisplayKeepAlive { stop, thread }
    }
}

impl Drop for DisplayKeepAlive {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

/// Nudge once the session has been idle long enough, and never more often
/// than that even if Windows did not count the last nudge as input.
fn display_nudge_due(idle: Duration, since_last_nudge: Option<Duration>) -> bool {
    idle >= DISPLAY_NUDGE_AFTER && since_last_nudge.is_none_or(|d| d >= DISPLAY_NUDGE_AFTER)
}

fn keep_displays_on(stop: &AtomicBool) {
    // SendInput reaches the input desktop only from a thread bound to it.
    if let Err(e) = crate::desktop::bind_input_desktop() {
        log::debug!("display keep-alive: {e:#}; binding again at the first nudge");
    }
    let mut last_nudge: Option<Instant> = None;
    let mut nudges = 0u32;
    let mut failed = false;
    while !stop.load(Ordering::Relaxed) {
        thread::sleep(DISPLAY_IDLE_POLL);
        let idle = match crate::input::idle_time() {
            Ok(idle) => idle,
            Err(e) => {
                if !failed {
                    log::warn!("display keep-alive: GetLastInputInfo: {e}");
                    failed = true;
                }
                continue;
            }
        };
        if !display_nudge_due(idle, last_nudge.map(|t| t.elapsed())) {
            continue;
        }
        last_nudge = Some(Instant::now());
        let result = crate::input::wake_displays().or_else(|_| -> Result<()> {
            // The input desktop changed (lock, unlock, UAC): bind and retry.
            crate::desktop::bind_input_desktop()?;
            Ok(crate::input::wake_displays()?)
        });
        match result {
            Ok(()) => {
                nudges += 1;
                if nudges == 1 {
                    log::info!(
                        "no input for {} s: nudging the displays to keep them on",
                        idle.as_secs()
                    );
                }
            }
            Err(e) if !failed => {
                log::warn!("display keep-alive: could not nudge the displays: {e:#}");
                failed = true;
            }
            Err(_) => {}
        }
    }
    if nudges > 0 {
        log::info!("display keep-alive: {nudges} nudge(s) this session");
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
            let location = display::dxgi_output_for(&self.lease.monitor.device_name)?;
            if location.adapter_luid != gpu.luid {
                bail!(
                    "{} moved to '{}' instead of selected GPU '{}'",
                    self.lease.monitor.device_name,
                    location.adapter_name,
                    gpu.name
                );
            }
            self.placement = display::current_placement(&self.lease.monitor.device_name)?;
            self.location = location;
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
    if driver.is_some() {
        return crate::desktop::with_input_desktop("acquire display", || {
            acquire_display_bound(driver, gpu, want, lock_physical)
        });
    }
    acquire_display_bound(driver, gpu, want, lock_physical)
}

fn acquire_display_bound(
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

    // Do not overwrite a failed restore with a potentially damaged/new-session
    // layout. Retry it in the current console before beginning another lease.
    topology::recover_saved()?;

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
             a session needs capture and encode on one adapter",
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

/// One of the `MAX_CONNECTIONS` connection threads; dropping it frees the slot.
struct ConnectionSlot(Arc<AtomicUsize>);

impl ConnectionSlot {
    /// Only the accept loop acquires, so taking a slot and handing it back
    /// when there was none cannot turn another connection away.
    fn acquire(open: &Arc<AtomicUsize>, max: usize) -> Option<Self> {
        if open.fetch_add(1, Ordering::AcqRel) >= max {
            open.fetch_sub(1, Ordering::AcqRel);
            return None;
        }
        Some(Self(Arc::clone(open)))
    }
}

impl Drop for ConnectionSlot {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::AcqRel);
    }
}

/// The one connection allowed to own the virtual display. Releasing this on
/// every exit path also keeps the tray's session state honest after errors.
struct DisplayClaim<'a> {
    claimed: &'a AtomicBool,
    status: &'a Mutex<HostStatus>,
}

impl<'a> DisplayClaim<'a> {
    fn acquire(claimed: &'a AtomicBool, status: &'a Mutex<HostStatus>) -> Option<Self> {
        claimed
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .ok()
            .map(|_| Self { claimed, status })
    }
}

impl Drop for DisplayClaim<'_> {
    fn drop(&mut self) {
        self.status.lock().unwrap().session = None;
        self.claimed.store(false, Ordering::Release);
    }
}

/// Run the authenticated control prelude, then atomically claim the display
/// when the client asks to stream it. Pairing and unpairing are control-plane
/// operations and remain available while another connection owns the display.
fn handle_session(
    cfg: &ServerConfig,
    mut stream: TcpStream,
    peer: SocketAddr,
    display_claimed: &AtomicBool,
) -> Result<()> {
    stream.set_nodelay(true)?;
    stream.set_read_timeout(Some(HELLO_TIMEOUT))?;
    // A stalled client (e.g. its decoder wedges at a game's fullscreen match
    // load) must never block the send loop indefinitely: without this, a full
    // socket send buffer hangs `pump` inside `send_nals`, the stats go silent,
    // and the display lease never drops to restore the physical monitors. With
    // it, a stuck write fails, the session ends, and the layout comes back.
    stream.set_write_timeout(Some(SEND_TIMEOUT))?;

    // --- Noise handshake, then pairing if this client is new ----------------
    let hs = match crypto::host_handshake(&mut stream, &cfg.identity, &cfg.paired) {
        Ok(hs) => hs,
        // Logged where it happened (an old Mac app, or a Mac that pinned
        // another key for this PC); not a fault on either side.
        Err(e) if e.is::<crypto::HandshakeEnd>() => return Ok(()),
        Err(e) => return Err(e.context("handshake")),
    };
    let mut tx = SecureWriter::new(stream.try_clone()?, &hs.keys);
    let mut rx = SecureReader::new(stream, &hs.keys, MAX_CLIENT_PAYLOAD);
    let client_fp = crypto::fingerprint(&hs.peer);
    tx.send(
        msg::SERVER_HELLO,
        0,
        &protocol::server_hello_with_capabilities(&cfg.name, hs.paired),
    )?;

    // A known client can need the PIN too (it forgot us or lost hosts.txt).
    // Give every client the human PIN-entry window before its first request;
    // no display lease is held here. PAIR confirmation still uses HELLO_TIMEOUT.
    rx.set_read_timeout(Some(PAIR_TIMEOUT))?;
    if !hs.paired {
        log::info!("unpaired client {client_fp} from {peer}: waiting for the PIN");
    }
    let (mut ty, mut flags, mut payload) = match rx.recv() {
        Ok(first) => first,
        Err(e) if crypto::peer_closed(&e) => {
            // A Mac checking whether we still know it (`pg` moved) reads
            // `paired` from SERVER_HELLO and leaves.
            log::info!("client {client_fp} closed after SERVER_HELLO");
            return Ok(());
        }
        Err(e) => return Err(anyhow::Error::new(e).context("waiting for the first message")),
    };
    if ty == msg::PAIR {
        let pin = cfg.status.lock().unwrap().pin.clone();
        // The Mac confirms as soon as PAIR_REPLY arrives: the human part (the
        // PIN) was typed before PAIR.
        rx.set_read_timeout(Some(HELLO_TIMEOUT))?;
        let store = |name: Option<&str>| -> Result<()> {
            cfg.paired.lock().unwrap().add_pairing(hs.peer, name)
        };
        let paired = crypto::host_pairing(
            &mut tx,
            &mut rx,
            &hs.keys,
            &payload,
            &pin,
            &cfg.pair_limiter,
            store,
        )
        .with_context(|| format!("pairing client {client_fp} at {peer}"))?;
        if !paired {
            log::info!(
                "client {client_fp} left after PAIR_REPLY (its PIN did not match, or it gave up); \
                 counted as a failed PIN"
            );
            return Ok(());
        }
        log::info!("paired client {client_fp}");
        // Each PIN admits one Mac: a PIN that was read off the screen (or out
        // of a log) stops being useful the moment it has done its job.
        match cfg.status.lock().unwrap().rotate_pin() {
            Ok(true) => log::info!("pairing PIN rotated"),
            Ok(false) => {}
            Err(e) => log::warn!("could not rotate the pairing PIN: {e:#}"),
        }
        match rx.recv() {
            Ok(next) => (ty, flags, payload) = next,
            Err(e) => {
                // Pair-only clients deliberately close as soon as they have
                // PAIR_RESULT. The durable pairing is already complete.
                log::info!(
                    "paired client {client_fp} disconnected before requesting a stream: {e}"
                );
                return Ok(());
            }
        }
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
        "client '{}' ({client_fp}) v{} wants {}x{}@{}Hz at {} Mbps, codecs 0b{:03b}, input={}, {}",
        hello.name,
        hello.version,
        hello.width,
        hello.height,
        hello.refresh,
        hello.bitrate_mbps,
        hello.codecs,
        hello.wants_input,
        match (hello.encoder_quality, hello.video_flags) {
            (None, _) => "no picture options".to_string(),
            (Some(q), flags) => format!(
                "picture options quality {q}, flags 0b{:02b}",
                flags.unwrap_or(0)
            ),
        }
    );
    if hello.version != protocol::VERSION {
        tx.send(msg::STREAM_STOP, 0, &[stop_reason::BAD_VERSION])?;
        bail!("unsupported protocol version {}", hello.version);
    }
    let Some(_display_claim) = DisplayClaim::acquire(display_claimed, &cfg.status) else {
        log::info!("refused stream request from client {client_fp}: display is in another session");
        refuse_stream(&mut tx, &mut rx, stop_reason::BUSY);
        return Ok(());
    };
    if !hello.name.is_empty() {
        // Remember the client by the name it gives itself.
        let _ = cfg.paired.lock().unwrap().add(hs.peer, &hello.name);
    }

    // --- preflight: everything that can fail without touching a display ---
    let selected = crate::gpu::enumerate().and_then(|gpus| {
        session_gpu(
            &cfg.gpu,
            &cfg.encoder_caps,
            &gpus,
            cfg.gpu_want.as_deref(),
            cfg.intra_refresh,
            crate::nvenc_caps::query,
        )
    });
    let (gpu, encoder_caps) = match selected {
        Ok(selected) => selected,
        Err(e) => {
            refuse_stream(&mut tx, &mut rx, stop_reason::ENCODER_FAILED);
            return Err(e.context("session preflight could not find the selected GPU"));
        }
    };
    let host_video = HostVideo::new(cfg, &encoder_caps);
    let bitrate_mbps = selected_bitrate(hello.bitrate_mbps, cfg.bitrate_override_mbps);
    let plan = match plan_session(&hello, &host_video)
        .and_then(|plan| trial_encoder(cfg, &gpu, &plan, bitrate_mbps).map(|()| plan))
    {
        Ok(plan) => plan,
        Err(e) => {
            // STREAM_STOP carries only the reason code: the Mac shows a
            // generic stop and the detail stays in this log.
            refuse_stream(&mut tx, &mut rx, stop_reason::ENCODER_FAILED);
            return Err(e.context("session preflight refused the stream (no display was changed)"));
        }
    };
    if !encoder_caps.video_caps(cfg.intra_refresh).hevc && hello.codecs & Codec::Hevc.bit() != 0 {
        log::info!("client offers HEVC, but this GPU's HEVC encoder is not usable: using H.264");
    }

    let _awake = KeepAwake::new();
    let want = Mode {
        width: plan.width,
        height: plan.height,
        hz: if hello.refresh == 0 {
            60
        } else {
            u32::from(hello.refresh)
        },
    };
    // Displays powered down after inactivity give Desktop Duplication no
    // frames until there is input, and KeepAwake must not wake them (see there).
    // The physical monitors are still on the desktop here, so this lights only
    // what the session is about to take over. Never fail the session over it.
    match crate::desktop::with_input_desktop("wake displays", || {
        crate::input::wake_displays().context("SendInput")
    }) {
        Ok(()) => log::info!("woke displays before session setup"),
        Err(e) => log::warn!("could not wake displays before session setup: {e:#}"),
    }
    let mut source = acquire_display(cfg.driver.as_ref(), &gpu, want, cfg.lock_physical)?;
    let placement = source.placement;
    let actual = Mode {
        width: placement.width,
        height: placement.height,
        hz: placement.hz,
    };
    let mut display_luid = source.location.adapter_luid;
    if crate::test_fault("display-gpu") {
        // What a hybrid laptop does when Windows renders the virtual display
        // on the iGPU.
        display_luid.low ^= 0xffff_ffff;
    }
    let plan = match revalidate_plan(plan, actual, display_luid, &host_video)
        .with_context(|| {
            format!(
                "the display came up at {}x{}@{} on '{}'",
                actual.width, actual.height, actual.hz, source.location.adapter_name
            )
        })
        .and_then(|checked| {
            if checked == plan {
                Ok(checked)
            } else {
                log::info!(
                    "display runs at {}x{}@{}, not the requested {}x{}@{}; checked the encoder again",
                    checked.width,
                    checked.height,
                    checked.fps,
                    plan.width,
                    plan.height,
                    plan.fps
                );
                trial_encoder(cfg, &gpu, &checked, bitrate_mbps).map(|()| checked)
            }
        }) {
        Ok(plan) => plan,
        Err(e) => {
            // Roll back first: the user's layout comes back before the
            // client hears anything.
            drop(source);
            refuse_stream(&mut tx, &mut rx, stop_reason::ENCODER_FAILED);
            return Err(e.context("the attached display failed revalidation (layout restored)"));
        }
    };
    let displays_on = DisplayKeepAlive::start();
    let (codec, video, fps) = (plan.codec, plan.video, plan.fps);
    let asked = hello.video_flags.unwrap_or(0) & (video_flags::FULL_COLOR | video_flags::TEN_BIT);
    if asked != video.flags() {
        log::info!(
            "not applying the client's {} request: {}",
            describe_flags(asked & !video.flags()),
            if codec != Codec::Hevc {
                "the session is H.264"
            } else {
                "this GPU's encoder cannot"
            }
        );
    }
    log::info!(
        "capturing {} at {fps} fps, {}{} {bitrate_mbps} Mbps{}, preset {}{} via NVENC on {}",
        source.monitor().device_name,
        codec_label(codec),
        match video.flags() {
            0 => String::new(),
            flags => format!(" {}", describe_flags(flags)),
        },
        if cfg.bitrate_override_mbps.is_some() {
            " (host override)"
        } else {
            ""
        },
        video.quality.label(),
        if cfg.quality_override.is_some() {
            " (host override)"
        } else if hello.encoder_quality.and_then(Quality::from_wire).is_none() {
            " (default)"
        } else {
            ""
        },
        gpu.name,
    );

    tx.send(
        msg::STREAM_START,
        0,
        &protocol::stream_start(
            plan.width as u16,
            plan.height as u16,
            fps as u16,
            bitrate_mbps as u16,
            codec,
            video.format(),
        ),
    )?;
    // The tray ends the session by storing a stop reason here.
    let end_request = Arc::new(AtomicU8::new(NO_END_REQUEST));
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
        end_request: Arc::clone(&end_request),
    });

    let mut encoder_config = encoder_config(cfg, &gpu, &plan, bitrate_mbps, Some(&source.location));
    // The preflight already initialized this configuration, so a failed start
    // is a capture that is not ready yet (a refused desktop, a mode change
    // settling, a GPU reset): the recovery loop retries it like a restart,
    // and gives up after ENCODER_RECOVERY_TIMEOUT unless the desktop refused.
    let mut encoder = match Encoder::spawn(&encoder_config) {
        Ok(e) => e,
        Err(e) => {
            log::warn!(
                "native capture did not start ({}: {e:#}); the session starts without a picture and retries",
                crate::encoder::classify_start_failure(&e).label()
            );
            Encoder::waiting()
        }
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
        gpu: &gpu,
        want,
    };
    let ending = SessionEnding {
        stop: &stop,
        end_request: &end_request,
    };
    let result = pump(
        &mut tx,
        &mut encoder,
        &mut recovery,
        &ending,
        &last_pong,
        &last_ping_sent,
        &network_rtt,
    );

    if matches!(result, Ok(PumpEnd::Ended)) {
        // We sent the final STREAM_STOP while the client may still be sending
        // input. Half-close and let the reader drain until the client closes
        // (it does on STREAM_STOP): a full close with unread bytes can turn
        // into an RST that discards the stop on Windows.
        tx.shutdown_write();
        let deadline = Instant::now() + END_DRAIN_TIMEOUT;
        while !stop.load(Ordering::Relaxed) && Instant::now() < deadline {
            thread::sleep(Duration::from_millis(20));
        }
    }
    tx.shutdown();
    stop.store(true, Ordering::Relaxed);
    drop(encoder);
    let _ = reader.join();
    // No nudges while the user's layout comes back.
    drop(displays_on);
    drop(source);
    result.map(|_| ())
}

/// Why `pump` returned normally.
#[derive(Debug, PartialEq, Eq)]
enum PumpEnd {
    /// The client closed or stopped answering; nothing more to send.
    ClientGone,
    /// The tray asked for the end and the client was told with STREAM_STOP.
    Ended,
}

/// The two ways a session is asked to stop: the reader thread saw the client
/// go (`stop`), or the tray stored a stop reason (`end_request`).
struct SessionEnding<'a> {
    stop: &'a AtomicBool,
    end_request: &'a AtomicU8,
}

impl SessionEnding<'_> {
    /// `Some(end)` when the pump should return now. A tray request sends the
    /// STREAM_STOP here so every check site behaves the same.
    fn check(&self, tx: &mut SecureWriter) -> Option<PumpEnd> {
        if self.stop.load(Ordering::Relaxed) {
            return Some(PumpEnd::ClientGone);
        }
        let reason = self.end_request.load(Ordering::Relaxed);
        if reason == NO_END_REQUEST {
            return None;
        }
        log::info!("session ended from the tray (stop reason {reason})");
        if let Err(e) = tx.send(msg::STREAM_STOP, 0, &[reason]) {
            log::debug!("final STREAM_STOP not delivered: {e:#}");
        }
        Some(PumpEnd::Ended)
    }
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
    ending: &SessionEnding<'_>,
    last_pong: &Mutex<Instant>,
    last_ping_sent: &Mutex<Option<Instant>>,
    network_rtt: &Mutex<Option<Duration>>,
) -> Result<PumpEnd> {
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
    let mut congestion = CongestionWindow::new();

    loop {
        if let Some(end) = ending.check(tx) {
            return Ok(end);
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
                if let Some(end) = ending.check(tx) {
                    return Ok(end);
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
                recovery.encoder_config.capture_luid = recovery.source.location.adapter_luid;
                recovery.encoder_config.output_idx = recovery.source.location.output_index;
                thread::sleep(ENCODER_RESTART_DELAY);
                if let Some(end) = ending.check(tx) {
                    return Ok(end);
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
                    Err(error) if crate::encoder::is_capture_mismatch(&error) => {
                        log::warn!("capture restart refused: {error:#}");
                    }
                    Err(error) => {
                        log::warn!(
                            "capture restart failed ({}): {error:#}",
                            crate::encoder::classify_start_failure(&error).label()
                        );
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
        if congestion.observe(frame_send, recovery.encoder_config.fps) {
            let bitrate = recovery.encoder_config.bitrate_mbps;
            log::warn!(
                "connection could not sustain {bitrate} Mbps at {} fps; ending the session",
                recovery.encoder_config.fps
            );
            let _ = tx.send(msg::STREAM_STOP, 0, &[stop_reason::BANDWIDTH_EXCEEDED]);
            bail!("connection could not sustain the selected {bitrate} Mbps bitrate");
        }
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

fn selected_bitrate(requested: u16, override_mbps: Option<u16>) -> u32 {
    u32::from(override_mbps.unwrap_or(requested))
}

/// End a stream request with a STREAM_STOP reason code (it carries no text),
/// then drain what the client already sent: HostConnection is input-ready as
/// soon as it sends CLIENT_HELLO, and closing with unread bytes can produce an
/// RST that discards the stop on Windows.
fn refuse_stream(tx: &mut SecureWriter, rx: &mut SecureReader, reason: u8) {
    if let Err(e) = tx.send(msg::STREAM_STOP, 0, &[reason]) {
        log::debug!("STREAM_STOP {reason} not delivered: {e:#}");
        return;
    }
    tx.shutdown_write();
    if rx.set_read_timeout(Some(HELLO_TIMEOUT)).is_ok() {
        while rx.recv().is_ok() {}
    }
}

/// The encoder settings for a plan. Before the display exists `location` is
/// `None` and the selected GPU stands in for the capture adapter.
fn encoder_config(
    cfg: &ServerConfig,
    gpu: &GpuInfo,
    plan: &SessionPlan,
    bitrate_mbps: u32,
    location: Option<&OutputLocation>,
) -> EncoderConfig {
    EncoderConfig {
        capture_adapter_idx: location.map_or(gpu.adapter_index, |l| l.adapter_index),
        capture_luid: location.map_or(gpu.luid, |l| l.adapter_luid),
        encode_luid: gpu.luid,
        output_idx: location.map_or(0, |l| l.output_index),
        width: plan.width,
        height: plan.height,
        fps: plan.fps,
        bitrate_mbps,
        codec: plan.codec,
        gop: cfg.gop_seconds.max(1) * plan.fps,
        quality: plan.video.quality,
        full_color: plan.video.full_color,
        ten_bit: plan.video.ten_bit,
        intra_refresh: cfg.intra_refresh,
    }
}

/// Initialize Relay's real encoder configuration on the selected GPU at the
/// plan's size and tear it down again, so a driver that refuses it is found
/// before any display changes.
fn trial_encoder(
    cfg: &ServerConfig,
    gpu: &GpuInfo,
    plan: &SessionPlan,
    bitrate_mbps: u32,
) -> Result<()> {
    let started = Instant::now();
    crate::nvenc_caps::trial_initialize(gpu, &encoder_config(cfg, gpu, plan, bitrate_mbps, None))
        .with_context(|| {
        format!(
            "NVENC on {} refused {} {}x{}@{}",
            gpu.name,
            codec_label(plan.codec),
            plan.width,
            plan.height,
            plan.fps
        )
    })?;
    log::info!(
        "encoder preflight: {} {}x{}@{} {} initializes ({:.0} ms)",
        codec_label(plan.codec),
        plan.width,
        plan.height,
        plan.fps,
        plan.video.quality.preset_name(),
        started.elapsed().as_secs_f64() * 1000.0
    );
    Ok(())
}

/// The host's preferred codec when the client offers it, else HEVC, else
/// H.264; only codecs in `host_mask`, the ones this GPU can run.
fn choose_codec(offered: u8, preferred: Codec, host_mask: u8) -> Option<Codec> {
    [preferred, Codec::Hevc, Codec::H264]
        .into_iter()
        .find(|&codec| offered & host_mask & codec.bit() != 0)
}

/// The selected GPU as it is now, and its NVENC record. A driver restart or
/// update gives the adapter a new LUID, and the startup record would then
/// refuse every session (no adapter has its LUID): select again by the same
/// policy, and query NVENC again when the LUID moved.
fn session_gpu(
    startup: &GpuInfo,
    startup_caps: &EncoderCaps,
    gpus: &[GpuInfo],
    want: Option<&str>,
    intra_refresh: bool,
    query: impl FnOnce(&GpuInfo) -> Result<EncoderCaps>,
) -> Result<(GpuInfo, EncoderCaps)> {
    let current = crate::gpu::choose(gpus, want)?;
    if current.luid == startup.luid {
        return Ok((current, startup_caps.clone()));
    }
    log::warn!(
        "{} has LUID {:x}:{:x}, not {:x}:{:x} as at startup (the driver restarted or was updated); querying NVENC again",
        current.name,
        current.luid.high,
        current.luid.low,
        startup.luid.high,
        startup.luid.low
    );
    let caps = query(&current).with_context(|| format!("querying NVENC on {}", current.name))?;
    caps.ensure_usable(intra_refresh)?;
    Ok((current, caps))
}

/// What a session will encode, decided before any display is touched.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct SessionPlan {
    codec: Codec,
    video: SessionVideo,
    width: u32,
    height: u32,
    fps: u32,
}

/// The host's side of the preflight.
struct HostVideo<'a> {
    preferred: Codec,
    quality_override: Option<Quality>,
    fps_override: Option<u32>,
    intra_refresh: bool,
    caps: &'a EncoderCaps,
}

impl<'a> HostVideo<'a> {
    fn new(cfg: &ServerConfig, caps: &'a EncoderCaps) -> Self {
        HostVideo {
            preferred: cfg.codec,
            quality_override: cfg.quality_override,
            fps_override: cfg.fps,
            intra_refresh: cfg.intra_refresh,
            caps,
        }
    }

    /// The session frame rate for a display refresh rate.
    fn fps(&self, hz: u32) -> u32 {
        self.fps_override.unwrap_or(hz.clamp(30, 240))
    }

    fn video_caps(&self) -> VideoCaps {
        self.caps.video_caps(self.intra_refresh)
    }

    /// Everything a session at this size and rate needs from its codec.
    fn check(
        &self,
        codec: Codec,
        video: SessionVideo,
        width: u32,
        height: u32,
        fps: u32,
    ) -> Result<()> {
        let caps = self.caps.codec(codec).ok_or_else(|| {
            anyhow!(
                "{} has no {} encoder",
                self.caps.adapter,
                codec_label(codec)
            )
        })?;
        caps.check(&Requirement {
            width,
            height,
            fps,
            quality: video.quality,
            full_color: video.full_color,
            ten_bit: video.ten_bit,
            intra_refresh: self.intra_refresh,
        })
    }
}

/// The session's codec is the host's preference among what the Mac offers
/// and this GPU can run; picture options follow the GPU; the requested mode
/// must be one the encoder accepts. Pure: no display or driver call.
fn plan_session(hello: &ClientHello, host: &HostVideo) -> Result<SessionPlan> {
    let host_mask = host.caps.codec_mask(host.intra_refresh);
    let codec = choose_codec(hello.codecs, host.preferred, host_mask).ok_or_else(|| {
        anyhow!(
            "no codec in common: the Mac offers {}, this GPU encodes {}",
            codec_names(hello.codecs),
            codec_names(host_mask)
        )
    })?;
    let video = negotiate_video(
        hello.encoder_quality,
        hello.video_flags,
        host.quality_override,
        codec,
        host.video_caps(),
    );
    let hz = if hello.refresh == 0 {
        60
    } else {
        u32::from(hello.refresh)
    };
    let (width, height, fps) = (
        u32::from(hello.width),
        u32::from(hello.height),
        host.fps(hz),
    );
    host.check(codec, video, width, height, fps)?;
    Ok(SessionPlan {
        codec,
        video,
        width,
        height,
        fps,
    })
}

/// After the display is attached, and before capture starts: it must be on
/// the selected GPU (capture and encode share one adapter), and a mode other
/// than the planned one must pass the same checks.
fn revalidate_plan(
    plan: SessionPlan,
    actual: Mode,
    display_luid: Luid,
    host: &HostVideo,
) -> Result<SessionPlan> {
    if display_luid != host.caps.luid {
        bail!(
            "the display is not on the selected GPU {} (LUID {:x}:{:x} instead of {:x}:{:x}); capture and encode must share one adapter",
            host.caps.adapter,
            display_luid.high,
            display_luid.low,
            host.caps.luid.high,
            host.caps.luid.low
        );
    }
    let fps = host.fps(actual.hz);
    if (actual.width, actual.height, fps) == (plan.width, plan.height, plan.fps) {
        return Ok(plan);
    }
    host.check(plan.codec, plan.video, actual.width, actual.height, fps)?;
    Ok(SessionPlan {
        width: actual.width,
        height: actual.height,
        fps,
        ..plan
    })
}

fn codec_names(mask: u8) -> String {
    let names: Vec<&str> = [Codec::Hevc, Codec::H264]
        .into_iter()
        .filter(|c| mask & c.bit() != 0)
        .map(codec_label)
        .collect();
    if names.is_empty() {
        "nothing Relay knows".into()
    } else {
        names.join(" and ")
    }
}

/// One session's encoder quality and picture flags.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct SessionVideo {
    quality: Quality,
    full_color: bool,
    ten_bit: bool,
}

impl SessionVideo {
    fn flags(self) -> u8 {
        (if self.full_color {
            video_flags::FULL_COLOR
        } else {
            0
        }) | (if self.ten_bit {
            video_flags::TEN_BIT
        } else {
            0
        })
    }

    fn format(self) -> VideoFormat {
        VideoFormat {
            quality: self.quality.wire(),
            full_color: self.full_color,
            ten_bit: self.ten_bit,
        }
    }
}

/// An explicit host `--quality` wins over the client, like `--bitrate`; then
/// the client's `encoder_quality`; then `Quality::Speed`. A flag applies only
/// to an HEVC session whose encoder caps allow it.
fn negotiate_video(
    requested_quality: Option<u8>,
    requested_flags: Option<u8>,
    quality_override: Option<Quality>,
    codec: Codec,
    caps: VideoCaps,
) -> SessionVideo {
    let quality = quality_override
        .or_else(|| {
            requested_quality
                .filter(|_| caps.quality)
                .and_then(Quality::from_wire)
        })
        .unwrap_or(Quality::Speed);
    let flags = requested_flags.unwrap_or(0);
    let hevc = codec == Codec::Hevc;
    SessionVideo {
        quality,
        full_color: hevc && caps.full_color && flags & video_flags::FULL_COLOR != 0,
        ten_bit: hevc && caps.ten_bit && flags & video_flags::TEN_BIT != 0,
    }
}

fn describe_flags(flags: u8) -> String {
    [
        (flags & video_flags::FULL_COLOR != 0).then_some("4:4:4"),
        (flags & video_flags::TEN_BIT != 0).then_some("10-bit"),
    ]
    .into_iter()
    .flatten()
    .collect::<Vec<_>>()
    .join(" ")
}

/// A rolling five-second window distinguishes a slow encoder from a sender
/// that is consuming the whole frame budget. An isolated keyframe or scheduler
/// stall ages out instead of accumulating toward failure.
struct CongestionWindow {
    samples: VecDeque<(Instant, Duration)>,
    send_time: Duration,
}

impl CongestionWindow {
    fn new() -> Self {
        Self {
            samples: VecDeque::new(),
            send_time: Duration::ZERO,
        }
    }

    fn observe(&mut self, frame_send: Duration, target_fps: u32) -> bool {
        let now = Instant::now();
        self.samples.push_back((now, frame_send));
        self.send_time += frame_send;
        while self.samples.len() > 1 && now.duration_since(self.samples[1].0) >= CONGESTION_WINDOW {
            if let Some((_, removed_send)) = self.samples.pop_front() {
                self.send_time = self.send_time.saturating_sub(removed_send);
            }
        }
        let elapsed = now.duration_since(self.samples.front().expect("sample just added").0);
        if elapsed < CONGESTION_WINDOW {
            return false;
        }
        is_congested(
            elapsed,
            self.samples.len() as u64,
            self.send_time,
            target_fps,
        )
    }
}

fn is_congested(elapsed: Duration, frames: u64, send_time: Duration, target_fps: u32) -> bool {
    let seconds = elapsed.as_secs_f64();
    let achieved_fps = frames as f64 / seconds;
    let send_utilization = send_time.as_secs_f64() / seconds;
    achieved_fps < f64::from(target_fps) * CONGESTION_MIN_FPS_RATIO
        && send_utilization >= CONGESTION_MIN_SEND_UTILIZATION
}

#[cfg(test)]
mod pairing_wait_tests {
    use super::*;
    use std::path::PathBuf;

    struct TestState(PathBuf);

    impl TestState {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "relay-pair-wait-{}-{}",
                std::process::id(),
                rand::random::<u64>()
            ));
            std::fs::create_dir(&path).unwrap();
            Self(path)
        }
    }

    impl Drop for TestState {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    /// These pair-only tests must never reach display setup or cleanup.
    struct NoDisplay;

    impl VirtualDisplay for NoDisplay {
        fn name(&self) -> &'static str {
            "test"
        }

        fn pnp_id(&self) -> &'static str {
            "test"
        }

        fn dynamic_modes(&self) -> bool {
            true
        }

        fn attach(&self, _: Mode, _: &GpuInfo) -> Result<(Attachment, Monitor)> {
            panic!("pair-only attempted to attach a display")
        }

        fn lock_physical_outputs(&self) -> Result<()> {
            panic!("pair-only attempted to lock physical displays")
        }

        fn unlock_physical_outputs(&self) -> Result<()> {
            panic!("pair-only attempted to unlock physical displays")
        }

        fn detach(&self, _: Attachment) -> Result<()> {
            panic!("pair-only attempted to detach a display")
        }

        fn cleanup(&self) -> Result<()> {
            panic!("pair-only attempted display cleanup")
        }
    }

    fn delayed_pair(known: bool, busy: bool) {
        let state = TestState::new();
        let peer_path = state.0.join("peers.txt");
        let client = Identity::generate();
        let client_key = client.public.to_bytes();
        let mut peers = PeerList::load(&peer_path).unwrap();
        if known {
            peers.add_pairing(client_key, Some("Old name")).unwrap();
        }
        let mut status = HostStatus::new("123456".into(), true, state.0.join("pin.txt"));
        let end_request = Arc::new(AtomicU8::new(NO_END_REQUEST));
        if busy {
            status.session = Some(SessionInfo {
                client: "Other Mac".into(),
                client_key: [7; 32],
                width: 1920,
                height: 1080,
                hz: 60,
                end_request: Arc::clone(&end_request),
            });
        }
        let cfg = ServerConfig {
            port: 0,
            name: "Test PC".into(),
            bitrate_override_mbps: None,
            fps: None,
            codec: Codec::Hevc,
            gop_seconds: 1,
            quality_override: None,
            video_caps: crate::nvenc_caps::fixture::rtx().video_caps(false),
            encoder_caps: crate::nvenc_caps::fixture::rtx(),
            intra_refresh: false,
            lock_physical: true,
            gpu: GpuInfo {
                adapter_index: 0,
                name: "Unused test GPU".into(),
                vendor: crate::gpu::Vendor::Other,
                dedicated_vram: 0,
                luid: crate::gpu::Luid { low: 0, high: 0 },
                kind: crate::gpu::AdapterKind::default(),
            },
            gpu_want: None,
            driver: Some(Arc::new(NoDisplay)),
            allow_input: false,
            identity: Arc::new(Identity::generate()),
            paired: Arc::new(Mutex::new(peers)),
            status: Arc::new(Mutex::new(status)),
            pair_limiter: Arc::new(Mutex::new(PairLimiter::new())),
            advertisement: Arc::new(Mutex::new(None)),
        };
        let claimed = Arc::new(AtomicBool::new(busy));
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let mut stream = TcpStream::connect(listener.local_addr().unwrap()).unwrap();
        stream.set_nodelay(true).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(15)))
            .unwrap();
        stream
            .set_write_timeout(Some(Duration::from_secs(15)))
            .unwrap();
        let (socket, peer) = listener.accept().unwrap();
        let host_cfg = cfg.clone();
        let host_claimed = Arc::clone(&claimed);
        let host = thread::spawn(move || handle_session(&host_cfg, socket, peer, &host_claimed));
        // Shutdown this clone even on a failed assertion, so the host thread
        // cannot remain waiting for its full human-entry timeout.
        let close = stream.try_clone().unwrap();
        let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            // No pinning models a Mac that forgot the PC but kept its identity.
            let hs = crypto::client_handshake(&mut stream, &client, None).unwrap();
            let mut tx = SecureWriter::new(stream.try_clone().unwrap(), &hs.keys);
            let mut rx = SecureReader::new(stream, &hs.keys, MAX_CLIENT_PAYLOAD);
            let (ty, _, hello) = rx.recv().unwrap();
            assert_eq!(ty, msg::SERVER_HELLO);
            let name_end = 3 + usize::from(hello[2]);
            assert_eq!(hello[name_end] != 0, known);
            assert_ne!(hello[name_end + 1] & protocol::CAP_PAIR_NAME, 0);
            assert_ne!(hello[name_end + 1] & protocol::CAP_VIDEO_OPTIONS, 0);

            // Exceeds the old known-client deadline, through the production
            // handler rather than a fixture that sets its own host timeout.
            thread::sleep(Duration::from_secs(6));
            crypto::client_pairing(
                &mut tx,
                &mut rx,
                &hs.keys,
                "123456",
                false,
                Some("Delayed Mac"),
            )
            .unwrap();
            let saved = PeerList::load(&peer_path).unwrap();
            assert!(saved.contains(&client_key));
            assert_eq!(saved.name_of(&client_key), Some("Delayed Mac"));
            tx.shutdown();
        }));
        let _ = close.shutdown(std::net::Shutdown::Both);
        let host_result = host.join();
        if let Err(panic) = result {
            std::panic::resume_unwind(panic);
        }
        host_result.unwrap().unwrap();
        assert_eq!(claimed.load(Ordering::Acquire), busy);
        let status = cfg.status.lock().unwrap();
        assert_eq!(status.session.is_some(), busy);
        if let Some(session) = &status.session {
            assert_eq!(session.client, "Other Mac");
            assert_eq!(session.client_key, [7; 32]);
            assert!(Arc::ptr_eq(&session.end_request, &end_request));
            assert_eq!(end_request.load(Ordering::Relaxed), NO_END_REQUEST);
        }
    }

    #[test]
    fn known_client_can_repair_after_six_seconds_without_requesting_a_display() {
        delayed_pair(true, false);
    }

    #[test]
    fn unknown_client_can_pair_after_six_seconds_without_requesting_a_display() {
        delayed_pair(false, false);
    }

    #[test]
    fn known_client_can_repair_after_six_seconds_while_another_session_owns_display() {
        delayed_pair(true, true);
    }
}

#[cfg(test)]
mod display_claim_tests {
    use super::*;
    use std::path::PathBuf;

    #[test]
    fn exactly_one_connection_owns_the_display_and_drop_releases_it() {
        let claimed = AtomicBool::new(false);
        let status = Mutex::new(HostStatus::new("123456".into(), true, PathBuf::new()));

        let first = DisplayClaim::acquire(&claimed, &status).expect("first claim");
        assert!(DisplayClaim::acquire(&claimed, &status).is_none());
        status.lock().unwrap().session = Some(SessionInfo {
            client: "test".into(),
            client_key: [0; 32],
            width: 1920,
            height: 1080,
            hz: 60,
            end_request: Arc::new(AtomicU8::new(NO_END_REQUEST)),
        });

        drop(first);
        assert!(!claimed.load(Ordering::Acquire));
        assert!(status.lock().unwrap().session.is_none());
        assert!(DisplayClaim::acquire(&claimed, &status).is_some());
    }

    #[test]
    fn connection_slots_cap_and_free_on_drop() {
        let open = Arc::new(AtomicUsize::new(0));
        let slots: Vec<_> = (0..MAX_CONNECTIONS)
            .map(|_| ConnectionSlot::acquire(&open, MAX_CONNECTIONS).expect("a free slot"))
            .collect();
        assert!(ConnectionSlot::acquire(&open, MAX_CONNECTIONS).is_none());
        assert_eq!(open.load(Ordering::Acquire), MAX_CONNECTIONS);
        drop(slots);
        assert_eq!(open.load(Ordering::Acquire), 0);
        assert!(ConnectionSlot::acquire(&open, MAX_CONNECTIONS).is_some());
    }

    #[test]
    fn client_bitrate_wins_without_an_override() {
        assert_eq!(selected_bitrate(1, None), 1);
        assert_eq!(selected_bitrate(1_000, None), 1_000);
    }

    #[test]
    fn explicit_host_bitrate_overrides_the_client() {
        assert_eq!(selected_bitrate(120, Some(500)), 500);
    }

    const ALL_CAPS: VideoCaps = VideoCaps {
        quality: true,
        hevc: true,
        full_color: true,
        ten_bit: true,
    };
    const BOTH_FLAGS: u8 = video_flags::FULL_COLOR | video_flags::TEN_BIT;

    #[test]
    fn quality_precedence_is_host_flag_then_client_then_speed() {
        let quality =
            |client, host| negotiate_video(client, None, host, Codec::Hevc, ALL_CAPS).quality;
        assert_eq!(quality(Some(3), Some(Quality::Balanced)), Quality::Balanced);
        assert_eq!(quality(None, Some(Quality::Quality)), Quality::Quality);
        assert_eq!(quality(Some(1), None), Quality::Speed);
        assert_eq!(quality(Some(2), None), Quality::Balanced);
        assert_eq!(quality(Some(3), None), Quality::Quality);
        // No extension, "host default" and values from a newer client.
        assert_eq!(quality(None, None), Quality::Speed);
        assert_eq!(quality(Some(0), None), Quality::Speed);
        assert_eq!(quality(Some(9), None), Quality::Speed);
    }

    #[test]
    fn flags_apply_to_hevc_when_the_caps_allow() {
        let video = negotiate_video(Some(2), Some(BOTH_FLAGS), None, Codec::Hevc, ALL_CAPS);
        assert!(video.full_color && video.ten_bit);
        assert_eq!(video.format().byte(), 0x0e);
        let only_444 = negotiate_video(None, Some(0x01), None, Codec::Hevc, ALL_CAPS);
        assert!(only_444.full_color && !only_444.ten_bit);
        let only_10 = negotiate_video(None, Some(0x02 | 0xf0), None, Codec::Hevc, ALL_CAPS);
        assert!(!only_10.full_color && only_10.ten_bit);
        assert_eq!(only_10.format().byte(), 0x09);
        let none = negotiate_video(None, None, None, Codec::Hevc, ALL_CAPS);
        assert_eq!(none.flags(), 0);
        assert_eq!(none.format().byte(), 0x01);
    }

    #[test]
    fn flags_are_ignored_for_h264() {
        let video = negotiate_video(Some(3), Some(BOTH_FLAGS), None, Codec::H264, ALL_CAPS);
        assert_eq!(video.flags(), 0);
        assert_eq!(video.quality, Quality::Quality);
        assert_eq!(video.format().byte(), 0x03);
    }

    #[test]
    fn flags_are_ignored_without_the_gpu_caps() {
        let video = negotiate_video(
            Some(2),
            Some(BOTH_FLAGS),
            None,
            Codec::Hevc,
            VideoCaps {
                full_color: false,
                ten_bit: false,
                ..ALL_CAPS
            },
        );
        assert_eq!(video.flags(), 0);
        assert_eq!(video.quality, Quality::Balanced);
        let no_10bit = VideoCaps {
            ten_bit: false,
            ..ALL_CAPS
        };
        let video = negotiate_video(None, Some(BOTH_FLAGS), None, Codec::Hevc, no_10bit);
        assert!(video.full_color && !video.ten_bit);
        let no_444 = VideoCaps {
            full_color: false,
            ..ALL_CAPS
        };
        let video = negotiate_video(None, Some(BOTH_FLAGS), None, Codec::Hevc, no_444);
        assert!(!video.full_color && video.ten_bit);
    }

    #[test]
    fn hevc_is_skipped_on_a_gpu_without_an_hevc_encoder() {
        let both = Codec::H264.bit() | Codec::Hevc.bit();
        let h264 = Codec::H264.bit();
        assert_eq!(choose_codec(both, Codec::Hevc, both), Some(Codec::Hevc));
        assert_eq!(choose_codec(both, Codec::H264, both), Some(Codec::H264));
        assert_eq!(choose_codec(h264, Codec::Hevc, both), Some(Codec::H264));
        assert_eq!(choose_codec(both, Codec::Hevc, h264), Some(Codec::H264));
        assert_eq!(choose_codec(Codec::Hevc.bit(), Codec::Hevc, h264), None);
        assert_eq!(choose_codec(0b100, Codec::Hevc, both), None);
        assert_eq!(choose_codec(both, Codec::Hevc, 0), None);
    }

    #[test]
    fn congestion_requires_both_underproduction_and_network_bound_send_time() {
        let elapsed = Duration::from_secs(5);
        assert!(is_congested(
            elapsed,
            500,
            Duration::from_millis(4_500),
            120
        ));
        assert!(!is_congested(
            elapsed,
            600,
            Duration::from_millis(4_500),
            120
        ));
        assert!(!is_congested(elapsed, 500, Duration::from_secs(2), 120));
    }
}

#[cfg(test)]
mod session_gpu_tests {
    use super::*;
    use crate::gpu::{AdapterKind, Vendor};
    use crate::nvenc_caps::fixture;

    fn rtx(low: u32) -> GpuInfo {
        GpuInfo {
            adapter_index: 0,
            name: "NVIDIA GeForce RTX 3080 Ti".into(),
            vendor: Vendor::Nvidia,
            dedicated_vram: 12 << 30,
            luid: Luid { low, high: 0 },
            kind: AdapterKind::default(),
        }
    }

    fn caps_for(gpu: &GpuInfo) -> EncoderCaps {
        EncoderCaps {
            luid: gpu.luid,
            ..fixture::rtx()
        }
    }

    #[test]
    fn an_unchanged_gpu_keeps_the_startup_record() {
        let startup = rtx(0x122e1);
        let (gpu, caps) = session_gpu(
            &startup,
            &caps_for(&startup),
            &[rtx(0x122e1)],
            None,
            false,
            |_| panic!("must not query NVENC again"),
        )
        .unwrap();
        assert_eq!(gpu.luid, startup.luid);
        assert_eq!(caps, caps_for(&startup));
    }

    #[test]
    fn a_driver_restart_requeries_the_gpu_under_its_new_luid() {
        let startup = rtx(0x122e1);
        let restarted = rtx(0x5a5a5);
        let (gpu, caps) = session_gpu(
            &startup,
            &caps_for(&startup),
            std::slice::from_ref(&restarted),
            None,
            false,
            |gpu| Ok(caps_for(gpu)),
        )
        .unwrap();
        assert_eq!(gpu.luid, restarted.luid);
        assert_eq!(caps.luid, restarted.luid);
    }

    #[test]
    fn a_vanished_or_unusable_gpu_refuses_the_session() {
        let startup = rtx(0x122e1);
        let startup_caps = caps_for(&startup);
        assert!(session_gpu(&startup, &startup_caps, &[], None, false, |_| {
            panic!("nothing to query")
        })
        .is_err());

        let restarted = rtx(0x5a5a5);
        let failed = session_gpu(
            &startup,
            &startup_caps,
            std::slice::from_ref(&restarted),
            None,
            false,
            |_| bail!("NvEncOpenEncodeSessionEx failed"),
        );
        assert!(format!("{:#}", failed.unwrap_err()).contains("NvEncOpenEncodeSessionEx"));

        let unusable = session_gpu(&startup, &startup_caps, &[restarted], None, false, |gpu| {
            Ok(EncoderCaps {
                luid: gpu.luid,
                ..fixture::caps(vec![])
            })
        });
        assert!(unusable.is_err());
    }
}

#[cfg(test)]
mod preflight_tests {
    use super::*;
    use crate::nvenc_caps::fixture;

    const BOTH: u8 = 0b11;

    fn hello(width: u16, height: u16, refresh: u16, codecs: u8) -> ClientHello {
        ClientHello {
            version: protocol::VERSION,
            width,
            height,
            refresh,
            bitrate_mbps: 120,
            wants_input: true,
            codecs,
            name: "MacBook".into(),
            encoder_quality: Some(protocol::encoder_quality::BALANCED),
            video_flags: Some(0),
        }
    }

    fn host(caps: &EncoderCaps) -> HostVideo<'_> {
        HostVideo {
            preferred: Codec::Hevc,
            quality_override: None,
            fps_override: None,
            intra_refresh: false,
            caps,
        }
    }

    fn error(result: Result<SessionPlan>) -> String {
        format!("{:#}", result.unwrap_err())
    }

    #[test]
    fn a_macbook_session_plans_hevc_at_its_own_mode() {
        let caps = fixture::rtx();
        let plan = plan_session(&hello(3024, 1964, 120, BOTH), &host(&caps)).unwrap();
        assert_eq!(plan.codec, Codec::Hevc);
        assert_eq!((plan.width, plan.height, plan.fps), (3024, 1964, 120));
        assert_eq!(plan.video.quality, Quality::Balanced);
        assert_eq!(plan.video.flags(), 0);
    }

    #[test]
    fn the_codec_is_what_the_mac_offers_the_gpu_runs_and_the_host_prefers() {
        let caps = fixture::rtx();
        let mut h264_host = host(&caps);
        h264_host.preferred = Codec::H264;
        let plan = plan_session(&hello(1920, 1080, 60, BOTH), &h264_host).unwrap();
        assert_eq!(plan.codec, Codec::H264);

        // A GTX 750 Ti has no HEVC encoder.
        let h264_gpu = fixture::caps(vec![fixture::h264()]);
        let plan = plan_session(&hello(1920, 1080, 60, BOTH), &host(&h264_gpu)).unwrap();
        assert_eq!(plan.codec, Codec::H264);
        let refused = error(plan_session(
            &hello(1920, 1080, 60, Codec::Hevc.bit()),
            &host(&h264_gpu),
        ));
        assert!(
            refused.contains("offers HEVC") && refused.contains("encodes H.264"),
            "{refused}"
        );
        let refused = error(plan_session(&hello(1920, 1080, 60, 0b100), &host(&caps)));
        assert!(refused.contains("offers nothing"), "{refused}");
    }

    #[test]
    fn intra_refresh_rules_out_a_codec_that_lacks_it() {
        let mut hevc = fixture::hevc();
        hevc.intra_refresh = false;
        let caps = fixture::caps(vec![hevc, fixture::h264()]);
        let mut wants_refresh = host(&caps);
        wants_refresh.intra_refresh = true;
        let plan = plan_session(&hello(1920, 1080, 60, BOTH), &wants_refresh).unwrap();
        assert_eq!(plan.codec, Codec::H264);
    }

    #[test]
    fn an_unsupported_mode_is_refused_before_the_display_is_touched() {
        let caps = fixture::rtx();
        let refused = error(plan_session(
            &hello(5120, 2880, 60, Codec::H264.bit()),
            &host(&caps),
        ));
        assert!(refused.contains("5120x2880"), "{refused}");
        assert!(plan_session(&hello(0, 0, 60, BOTH), &host(&caps)).is_err());
    }

    #[test]
    fn the_frame_rate_follows_the_request_unless_the_host_sets_it() {
        let caps = fixture::rtx();
        let fps = |refresh, fps_override| {
            let mut h = host(&caps);
            h.fps_override = fps_override;
            plan_session(&hello(1920, 1080, refresh, BOTH), &h)
                .unwrap()
                .fps
        };
        assert_eq!(fps(0, None), 60);
        assert_eq!(fps(120, None), 120);
        assert_eq!(fps(24, None), 30);
        assert_eq!(fps(500, None), 240);
        assert_eq!(fps(120, Some(90)), 90);
    }

    #[test]
    fn picture_flags_follow_the_gpu() {
        let caps = fixture::rtx();
        let mut flagged = hello(1920, 1080, 60, BOTH);
        flagged.video_flags = Some(video_flags::FULL_COLOR | video_flags::TEN_BIT);
        let plan = plan_session(&flagged, &host(&caps)).unwrap();
        assert!(plan.video.full_color && plan.video.ten_bit);

        let mut no_444 = fixture::hevc();
        no_444.yuv444 = false;
        let caps = fixture::caps(vec![no_444]);
        let plan = plan_session(&flagged, &host(&caps)).unwrap();
        assert!(!plan.video.full_color && plan.video.ten_bit);
    }

    #[test]
    fn a_preset_without_its_low_latency_config_is_refused() {
        let mut hevc = fixture::hevc();
        hevc.ull_presets = vec![Quality::Speed, Quality::Balanced];
        let caps = fixture::caps(vec![hevc]);
        let mut best = hello(1920, 1080, 60, BOTH);
        best.encoder_quality = Some(protocol::encoder_quality::BEST);
        let refused = error(plan_session(&best, &host(&caps)));
        assert!(refused.contains("P6"), "{refused}");
    }

    #[test]
    fn revalidation_requires_the_display_on_the_selected_gpu() {
        let caps = fixture::rtx();
        let host = host(&caps);
        let plan = plan_session(&hello(3024, 1964, 120, BOTH), &host).unwrap();
        let mode = Mode {
            width: 3024,
            height: 1964,
            hz: 120,
        };
        assert_eq!(revalidate_plan(plan, mode, caps.luid, &host).unwrap(), plan);
        let elsewhere = Luid {
            low: 0x9999,
            high: 0,
        };
        let refused = error(revalidate_plan(plan, mode, elsewhere, &host));
        assert!(refused.contains("NVIDIA GeForce RTX 3080 Ti"), "{refused}");
    }

    #[test]
    fn revalidation_rechecks_a_mode_that_differs_from_the_request() {
        let caps = fixture::rtx();
        let host = host(&caps);
        // Dev mode streams the primary display at whatever it runs at.
        let plan = plan_session(&hello(1920, 1080, 60, BOTH), &host).unwrap();
        let primary = Mode {
            width: 2560,
            height: 1440,
            hz: 144,
        };
        let replanned = revalidate_plan(plan, primary, caps.luid, &host).unwrap();
        assert_eq!(
            (replanned.width, replanned.height, replanned.fps),
            (2560, 1440, 144)
        );
        assert_eq!(replanned.codec, plan.codec);

        let h264 = plan_session(&hello(1920, 1080, 60, Codec::H264.bit()), &host).unwrap();
        let too_wide = Mode {
            width: 5120,
            height: 1440,
            hz: 60,
        };
        assert!(revalidate_plan(h264, too_wide, caps.luid, &host).is_err());
    }
}

#[cfg(test)]
mod display_keepalive_tests {
    use super::*;

    #[test]
    fn nudges_only_after_the_idle_threshold() {
        let just_under = DISPLAY_NUDGE_AFTER - Duration::from_millis(1);
        assert!(!display_nudge_due(Duration::ZERO, None));
        assert!(!display_nudge_due(just_under, None));
        assert!(display_nudge_due(DISPLAY_NUDGE_AFTER, None));
        assert!(display_nudge_due(Duration::from_secs(600), None));
    }

    #[test]
    fn never_nudges_more_often_than_the_threshold() {
        let long_idle = Duration::from_secs(600);
        // Even if Windows did not count the last nudge as input.
        assert!(!display_nudge_due(long_idle, Some(Duration::ZERO)));
        assert!(!display_nudge_due(
            long_idle,
            Some(DISPLAY_NUDGE_AFTER - Duration::from_millis(1))
        ));
        assert!(display_nudge_due(long_idle, Some(DISPLAY_NUDGE_AFTER)));
    }

    #[test]
    fn stays_under_the_shortest_display_off_timeout() {
        assert!(DISPLAY_NUDGE_AFTER + DISPLAY_IDLE_POLL < Duration::from_secs(60));
    }
}
