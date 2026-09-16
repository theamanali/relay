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
use windows::Win32::System::Power::{
    SetThreadExecutionState, ES_CONTINUOUS, ES_DISPLAY_REQUIRED, ES_SYSTEM_REQUIRED,
};

use crate::crypto::{self, Identity, PairLimiter, PeerList, SecureReader, SecureWriter};
use crate::display::{self, Mode, Monitor, OutputLocation, Placement};
use crate::driver::{Attachment, VirtualDisplay};
use crate::encoder::{Encoder, EncoderConfig, Quality};
use crate::gpu::GpuInfo;
use crate::input::Injector;
use crate::protocol::{self, msg, stop_reason, ClientHello, Codec, FLAG_KEYFRAME};
use crate::topology;

const HELLO_TIMEOUT: Duration = Duration::from_secs(5);
/// A human may be reading the PIN off the PC and typing it on the Mac.
const PAIR_TIMEOUT: Duration = Duration::from_secs(120);
const PING_INTERVAL: Duration = Duration::from_secs(1);
const PONG_TIMEOUT: Duration = Duration::from_secs(5);

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
    /// GPU that renders the virtual display and encodes the stream.
    pub gpu: GpuInfo,
    /// Dev mode (`None`): stream the primary monitor instead of adding a virtual one.
    pub driver: Option<Arc<dyn VirtualDisplay>>,
    pub allow_input: bool,
    /// This host's long-lived identity key.
    pub identity: Arc<Identity>,
    /// Clients that have paired (persisted).
    pub paired: Arc<Mutex<PeerList>>,
    /// PIN a new client must present.
    pub pin: String,
    pub pair_limiter: Arc<Mutex<PairLimiter>>,
}

pub fn run(cfg: ServerConfig) -> Result<()> {
    let listener = bind_dual_stack(cfg.port)?;
    let _ad = crate::discovery::advertise(&cfg.name, cfg.port)?;
    log::info!("listening on [::]:{} (dual-stack)", cfg.port);

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
    }
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

/// Keeps Windows from blanking displays or sleeping while a client is connected.
/// Desktop Duplication stops delivering frames the moment DWM stops presenting
/// (display-off timer, sleep), which would freeze the stream on an idle desktop.
/// Per-thread state, so this must live on the session thread.
struct KeepAwake;

impl KeepAwake {
    fn new() -> Self {
        unsafe {
            SetThreadExecutionState(ES_CONTINUOUS | ES_DISPLAY_REQUIRED | ES_SYSTEM_REQUIRED);
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
        if let Some(snapshot) = self.snapshot.take() {
            if let Err(e) = snapshot.restore() {
                log::warn!("could not restore the display layout: {e:#}");
            }
        }
        if let Some((driver, attachment)) = self.driver.take() {
            if let Err(e) = driver.detach(attachment) {
                log::warn!("failed to remove virtual display {}: {e:#}", self.monitor.device_name);
            }
        }
        if self.snapshot.is_none() {
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
}

/// Create the virtual display for a session and make it the only active one,
/// or (dev mode, `driver == None`) pick the primary monitor as-is.
pub fn acquire_display(
    driver: Option<&Arc<dyn VirtualDisplay>>,
    gpu: &GpuInfo,
    want: Mode,
) -> Result<Source> {
    let Some(driver) = driver else {
        let monitor = display::primary().ok_or_else(|| anyhow!("no primary display"))?;
        let placement = display::current_placement(&monitor.device_name)?;
        let location = display::dxgi_output_for(&monitor.device_name)?;
        log::info!(
            "dev mode: streaming primary display {} ({}x{}@{}) on {}",
            monitor.device_name, placement.width, placement.height, placement.hz, location.adapter_name
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
        log::info!("removing leftover virtual display {} before snapshotting", m.device_name);
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
    let name = lease.monitor.device_name.clone();
    let placement = display::current_placement(&name)?;
    if (placement.width, placement.height, placement.hz) != (want.width, want.height, want.hz) {
        if driver.dynamic_modes() {
            log::warn!(
                "asked {} for {}x{}@{} but got {}x{}@{} — check the driver's settings file",
                driver.name(), want.width, want.height, want.hz, placement.width, placement.height, placement.hz
            );
        } else {
            log::warn!(
                "client asked for {}x{}@{}, closest registered mode is {}x{}@{} \
                 ({} cannot create modes on demand)",
                want.width, want.height, want.hz, placement.width, placement.height, placement.hz, driver.name()
            );
        }
    }
    let location = display::dxgi_output_for(&name)?;
    if location.adapter_luid != gpu.luid {
        log::warn!(
            "virtual display {} is rendered by '{}' instead of the selected '{}'; \
             capture will be copied to the encoder through system memory",
            name, location.adapter_name, gpu.name
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
        if !crypto::verify_pin_proof(&hs.keys.pair, &cfg.pin, &proof) {
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
        (ty, flags, payload) = rx.recv().context("waiting for CLIENT_HELLO")?;
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
        hello.name, hello.version, hello.width, hello.height, hello.refresh, hello.codecs, hello.wants_input
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
        bail!("client supports no codec we can produce (mask 0b{:03b})", hello.codecs)
    };

    let _awake = KeepAwake::new();
    let want = Mode {
        width: hello.width as u32,
        height: hello.height as u32,
        hz: if hello.refresh == 0 { 60 } else { hello.refresh as u32 },
    };
    let source = acquire_display(cfg.driver.as_ref(), &cfg.gpu, want)?;
    let placement = source.placement;
    let fps = cfg.fps.unwrap_or(placement.hz.clamp(30, 240));
    log::info!(
        "capturing {} at {fps} fps, {} {} Mbps via {}",
        source.monitor().device_name,
        if codec == Codec::Hevc { "HEVC" } else { "H.264" },
        cfg.bitrate_mbps,
        crate::encoder::encoder_name(cfg.gpu.vendor, codec)
    );

    tx.send(
        msg::STREAM_START,
        0,
        &protocol::stream_start(placement.width as u16, placement.height as u16, fps as u16, codec),
    )?;

    let mut encoder = Encoder::spawn(&EncoderConfig {
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
    })?;

    // Reader thread: client -> host messages (input, pongs).
    let stop = Arc::new(AtomicBool::new(false));
    let last_pong = Arc::new(Mutex::new(Instant::now()));
    rx.set_read_timeout(None)?;
    let reader = {
        let stop = Arc::clone(&stop);
        let last_pong = Arc::clone(&last_pong);
        let injector = (cfg.allow_input && hello.wants_input).then(|| Injector::new(placement));
        thread::Builder::new()
            .name(format!("client-rx-{peer}"))
            .spawn(move || {
                let r = read_loop(rx, injector, &last_pong);
                if let Err(e) = r {
                    log::debug!("client reader finished: {e:#}");
                }
                stop.store(true, Ordering::Relaxed);
            })?
    };

    let result = pump(&mut tx, &mut encoder, &stop, &last_pong);

    tx.shutdown();
    stop.store(true, Ordering::Relaxed);
    drop(encoder);
    let _ = reader.join();
    drop(source);
    result
}

/// Host -> client: encoder output plus pings, until something ends the session.
fn pump(
    tx: &mut SecureWriter,
    encoder: &mut Encoder,
    stop: &AtomicBool,
    last_pong: &Mutex<Instant>,
) -> Result<()> {
    let mut last_config: Vec<Vec<u8>> = Vec::new();
    let mut last_ping = Instant::now();
    let mut frames: u64 = 0;
    let mut bytes: u64 = 0;
    let mut stats_at = Instant::now();
    let mut encoder_wait = Duration::ZERO;
    let mut send_time = Duration::ZERO;
    let mut max_send = Duration::ZERO;

    loop {
        if stop.load(Ordering::Relaxed) {
            return Ok(());
        }
        let read_at = Instant::now();
        let Some(au) = encoder.next_access_unit()? else {
            let _ = tx.send(msg::STREAM_STOP, 0, &[stop_reason::ENCODER_FAILED]);
            bail!("encoder exited");
        };

        encoder_wait += read_at.elapsed();
        let send_at = Instant::now();
        if !au.param_sets.is_empty() && au.param_sets != last_config {
            tx.send_nals(msg::CODEC_CONFIG, 0, &au.param_sets)?;
            last_config = au.param_sets.clone();
        }
        let flags = if au.keyframe { FLAG_KEYFRAME } else { 0 };
        tx.send_nals(msg::FRAME, flags, &au.nals)?;
        let elapsed = send_at.elapsed();
        send_time += elapsed;
        max_send = max_send.max(elapsed);
        frames += 1;
        bytes += au.nals.iter().map(|n| n.len() as u64).sum::<u64>();

        let now = Instant::now();
        if now.duration_since(last_ping) >= PING_INTERVAL {
            let us = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_micros() as u64)
                .unwrap_or(0);
            tx.send(msg::PING, 0, &us.to_be_bytes())?;
            last_ping = now;
            if now.duration_since(*last_pong.lock().unwrap()) > PONG_TIMEOUT {
                bail!("client stopped answering pings");
            }
        }
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

fn read_loop(
    mut rx: SecureReader,
    mut injector: Option<Injector>,
    last_pong: &Mutex<Instant>,
) -> Result<()> {
    loop {
        let (ty, _flags, p) = rx.recv()?;
        match ty {
            msg::PONG => *last_pong.lock().unwrap() = Instant::now(),
            msg::MOUSE_MOVE if p.len() >= 4 => {
                if let Some(inj) = &injector {
                    inj.mouse_move(u16::from_be_bytes([p[0], p[1]]), u16::from_be_bytes([p[2], p[3]]));
                }
            }
            msg::MOUSE_BUTTON if p.len() >= 2 => {
                if let Some(inj) = &injector {
                    inj.mouse_button(p[0], p[1] != 0);
                }
            }
            msg::MOUSE_WHEEL if p.len() >= 4 => {
                if let Some(inj) = &injector {
                    inj.mouse_wheel(i16::from_be_bytes([p[0], p[1]]), i16::from_be_bytes([p[2], p[3]]));
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
