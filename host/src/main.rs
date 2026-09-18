//! Relay host: makes a connected client a virtual monitor of this PC.
//!
//! Built without a console: serving shows only a tray icon and logs to a
//! file. Run from a terminal, it attaches to that terminal instead, so the
//! subcommands still print (after the prompt — a GUI process is not waited on).

#![windows_subsystem = "windows"]

use relay_host::{
    crypto, discovery, display, driver, encoder, gpu, protocol, server, status, topology, tray,
};

use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use anyhow::{Context, Result};
use clap::{Parser, Subcommand, ValueEnum};
use windows::Win32::System::Console::{AttachConsole, ATTACH_PARENT_PROCESS};

use display::Mode;
use driver::{DriverKind, VirtualDisplay};
use encoder::Quality;
use gpu::GpuInfo;
use protocol::Codec;

#[derive(Parser, Debug)]
#[command(name = "relay-host", version, about)]
struct Cli {
    /// Serving is the default when no subcommand is given; these are its options.
    #[command(flatten)]
    serve: ServeArgs,

    #[command(subcommand)]
    command: Option<Command>,

    /// Verbose logging (-v info is default, -vv debug, -vvv trace)
    #[arg(short, long, action = clap::ArgAction::Count, global = true)]
    verbose: u8,
}

#[derive(Subcommand, Debug)]
enum Command {
    /// List display adapters, monitors, modes and DXGI indices
    Displays,
    /// List GPUs and show which one would be used
    Gpus,
    /// Put the displays back the way they were (if a session or crash left them off)
    Restore,
    /// Show the pairing PIN (or generate a new one with --new)
    Pin {
        #[arg(long)]
        new: bool,
    },
    /// List paired clients, or forget one by fingerprint
    Paired {
        #[arg(long)]
        forget: Option<String>,
    },
    /// Show the current display layout; with --reapply, re-apply it (validates the restore path)
    Layout {
        #[arg(long)]
        reapply: bool,
    },
    /// Run a full session's display dance at a given mode — other displays go dark for a few seconds
    AttachTest {
        #[arg(long, default_value_t = 3024)]
        width: u32,
        #[arg(long, default_value_t = 1964)]
        height: u32,
        #[arg(long, default_value_t = 120)]
        hz: u32,
        /// How long to keep the display, in seconds
        #[arg(long, default_value_t = 10)]
        seconds: u64,
    },
}

#[derive(clap::Args, Debug, Clone)]
struct ServeArgs {
    /// TCP port to listen on
    #[arg(long, default_value_t = protocol::DEFAULT_PORT)]
    port: u16,

    /// Name shown to clients (defaults to the computer name)
    #[arg(long)]
    name: Option<String>,

    /// Path to ffmpeg.exe (searched on PATH by default)
    #[arg(long, default_value = "ffmpeg")]
    ffmpeg: PathBuf,

    /// Video bitrate in Mbps (CBR). A direct GbE link takes 100-300 comfortably.
    #[arg(long, default_value_t = 120)]
    bitrate: u32,

    /// Force a capture/encode frame rate instead of the display's refresh rate
    #[arg(long)]
    fps: Option<u32>,

    /// Preferred codec (the client must support it too)
    #[arg(long, value_enum, default_value_t = CodecArg::Hevc)]
    codec: CodecArg,

    /// Keyframe interval in seconds
    #[arg(long, default_value_t = 2)]
    gop: u32,

    /// Encoder speed/quality trade-off, mapped to each vendor's presets
    #[arg(long, value_enum, default_value_t = Quality::Speed)]
    quality: Quality,

    /// NVIDIA only: spread intra refresh over the GOP instead of sending full IDR frames
    #[arg(long)]
    intra_refresh: bool,

    /// GPU to render and encode on (case-insensitive substring of its name).
    /// Default: the adapter with the most dedicated VRAM, i.e. the discrete card.
    #[arg(long)]
    gpu: Option<String>,

    /// Which virtual display driver to use
    #[arg(long, value_enum, default_value_t = DriverKind::Auto)]
    driver: DriverKind,

    /// Dev mode: stream the primary monitor, don't touch the virtual display driver
    #[arg(long)]
    no_vdd: bool,

    /// NVIDIA only: skip the in-process D3D11/NVENC capture path and use the
    /// ffmpeg child instead. The in-process path is the default (lower latency);
    /// this is the fallback if it misbehaves.
    #[arg(long)]
    no_native: bool,

    /// Don't disable the physical monitor device nodes during a session, only
    /// remove them from the desktop (diagnostic / workaround for GPU hangs)
    #[arg(long)]
    no_lock_physical: bool,

    /// Refuse to inject mouse/keyboard input from the client
    #[arg(long)]
    no_input: bool,

    /// Pairing PIN (4-8 digits). Default: the one stored under %LOCALAPPDATA%Relay
    #[arg(long)]
    pin: Option<String>,
}

#[derive(ValueEnum, Debug, Clone, Copy)]
enum CodecArg {
    H264,
    Hevc,
}

impl From<CodecArg> for Codec {
    fn from(c: CodecArg) -> Self {
        match c {
            CodecArg::H264 => Codec::H264,
            CodecArg::Hevc => Codec::Hevc,
        }
    }
}

/// Rotate the log once it passes this; one previous file is kept.
const LOG_ROTATE_BYTES: u64 = 5 * 1024 * 1024;

fn main() -> Result<()> {
    // Launched from a terminal: use it. Launched by the logon task or a
    // double-click: there is none, and the log goes to a file.
    let has_console = attach_parent_console();
    let cli = Cli::parse();
    let level = match cli.verbose {
        0 => "info",
        1 => "debug",
        _ => "trace",
    };
    let mut logger =
        env_logger::Builder::from_env(env_logger::Env::default().default_filter_or(level));
    logger.format_timestamp_millis();
    // mdns-sd logs its routine goodbye retransmission at ERROR; everything
    // that matters from it comes back as a Result and is logged by `discovery`.
    logger.filter_module("mdns_sd", log::LevelFilter::Off);
    if !has_console {
        // No console and no file either: nothing to say it to. Keep going anyway.
        if let Ok(file) = open_log_file() {
            logger.target(env_logger::Target::Pipe(Box::new(file)));
        }
    }
    logger.init();
    let result = run(cli);
    if let Err(error) = &result {
        // The `?` from main prints to stderr, which does not exist here.
        log::error!("{error:#}");
    }
    result
}

/// Join the parent's console, if it has one, without losing a redirect:
/// `AttachConsole` points every standard handle at the console, including
/// ones the shell had already pointed at a file or pipe.
fn attach_parent_console() -> bool {
    use windows::Win32::Foundation::{HANDLE, INVALID_HANDLE_VALUE};
    use windows::Win32::System::Console::{
        GetStdHandle, SetStdHandle, STD_ERROR_HANDLE, STD_INPUT_HANDLE, STD_OUTPUT_HANDLE,
    };
    unsafe {
        let ids = [STD_INPUT_HANDLE, STD_OUTPUT_HANDLE, STD_ERROR_HANDLE];
        let inherited: Vec<Option<HANDLE>> = ids
            .iter()
            .map(|&id| match GetStdHandle(id) {
                Ok(h) if !h.is_invalid() && h != INVALID_HANDLE_VALUE => Some(h),
                _ => None,
            })
            .collect();
        if AttachConsole(ATTACH_PARENT_PROCESS).is_err() {
            return false;
        }
        for (id, handle) in ids.iter().zip(inherited) {
            if let Some(h) = handle {
                let _ = SetStdHandle(*id, h);
            }
        }
        true
    }
}

/// `%LOCALAPPDATA%\Relay\host.log`, rotated to `host.log.1` when it is large.
fn open_log_file() -> Result<std::fs::File> {
    let path = state_dir()?.join("host.log");
    if let Ok(meta) = std::fs::metadata(&path) {
        if meta.len() > LOG_ROTATE_BYTES {
            let _ = std::fs::rename(&path, path.with_extension("log.1"));
        }
    }
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(&path)
        .with_context(|| format!("opening {}", path.display()))
}

fn run(cli: Cli) -> Result<()> {
    if let Err(error) = relay_host::input::enable_physical_pixel_coordinates() {
        log::warn!("could not enable physical-pixel input coordinates: {error}");
    }

    match cli.command {
        None => serve(cli.serve),
        Some(Command::Displays) => {
            print!("{}", display::describe_all());
            Ok(())
        }
        Some(Command::Gpus) => {
            let gpus = gpu::enumerate()?;
            let chosen = match gpu::choose(&gpus, cli.serve.gpu.as_deref()) {
                Ok(g) => Some(g),
                Err(e) => {
                    eprintln!("{e:#}");
                    None
                }
            };
            print!("{}", gpu::describe(&gpus, chosen.as_ref()));
            Ok(())
        }
        Some(Command::Restore) => restore_displays(cli.serve.driver),
        Some(Command::Pin { new }) => show_pin(new),
        Some(Command::Paired { forget }) => paired_clients(forget),
        Some(Command::Layout { reapply }) => {
            let snap = topology::Snapshot::take()?;
            println!("active displays: {}", snap.describe());
            if reapply {
                snap.restore()?;
                println!("re-applied without changes");
            }
            Ok(())
        }
        Some(Command::AttachTest {
            width,
            height,
            hz,
            seconds,
        }) => attach_test(&cli.serve, Mode { width, height, hz }, seconds),
    }
}

fn select_gpu(want: Option<&str>) -> Result<GpuInfo> {
    let gpus = gpu::enumerate()?;
    let chosen = gpu::choose(&gpus, want)?;
    log::info!(
        "GPU: {} ({}, {:.1} GB) — {}",
        chosen.name,
        chosen.vendor.label(),
        chosen.vram_gb(),
        if want.is_some() {
            "requested with --gpu"
        } else {
            "most dedicated VRAM"
        }
    );
    for g in gpus.iter().filter(|g| g.luid != chosen.luid) {
        log::debug!(
            "not using {} ({}, {:.1} GB)",
            g.name,
            g.vendor.label(),
            g.vram_gb()
        );
    }
    Ok(chosen)
}

/// Open the driver and undo whatever an earlier session left behind (physical
/// displays off, virtual device enabled).
fn open_driver(kind: DriverKind) -> Result<Arc<dyn VirtualDisplay>> {
    let drv = driver::open(kind)?;
    log::info!("virtual display driver: {}", drv.name());
    put_displays_back(&drv);
    Ok(drv)
}

/// The one way out for Ctrl-C, tray Quit and logoff: displays back, Bonjour
/// goodbye sent (so the Mac's list drops us now, not at the record's TTL),
/// then exit. `process::exit` runs no destructors, hence the explicit steps.
fn shut_down(
    why: &str,
    driver: Option<&Arc<dyn VirtualDisplay>>,
    advertisement: &discovery::AdSlot,
) -> ! {
    log::info!("{why}");
    if let Some(drv) = driver {
        put_displays_back(drv);
    }
    discovery::withdraw(advertisement);
    std::process::exit(0);
}

/// Restore the saved display layout (if a session left one) and remove the
/// virtual monitor. Safe to call when there is nothing to do.
fn put_displays_back(drv: &Arc<dyn VirtualDisplay>) {
    // Physical monitor device nodes must exist before their saved topology can
    // be restored. MTT cleanup also recovers locks left by a crashed host.
    if let Err(e) = drv.cleanup() {
        log::warn!("virtual display cleanup failed: {e:#}");
    }
    match topology::recover_saved() {
        Ok(true) => {}
        Ok(false) => {}
        Err(e) => log::warn!("restoring the display layout failed: {e:#}"),
    }
}

/// `restore` subcommand: the manual way out if the physical displays stayed off.
fn restore_displays(kind: DriverKind) -> Result<()> {
    match driver::open(kind) {
        Ok(drv) => drv.cleanup()?,
        Err(e) => log::warn!("virtual display driver not available: {e:#}"),
    }
    let restored = topology::recover_saved()?;
    if !restored {
        log::info!("no saved layout from a session; asking Windows for its own");
        topology::restore_from_database()?;
    }
    log::info!(
        "displays: {}",
        display::enumerate()
            .iter()
            .filter(|m| m.attached)
            .map(|m| format!(
                "{}{}",
                m.device_name,
                if m.primary { " (primary)" } else { "" }
            ))
            .collect::<Vec<_>>()
            .join(", ")
    );
    Ok(())
}

/// Runs exactly what a session does — snapshot, enable, exclusive, hold,
/// restore, disable — and reports on every step.
fn attach_test(args: &ServeArgs, want: Mode, seconds: u64) -> Result<()> {
    let gpu = select_gpu(args.gpu.as_deref())?;
    let drv = open_driver(args.driver)?;

    let started = std::time::Instant::now();
    let source = server::acquire_display(Some(&drv), &gpu, want, true)?;
    let monitor = source.monitor().clone();
    log::info!(
        "virtual display active after {:.1}s: {} ({}), {}",
        started.elapsed().as_secs_f64(),
        monitor.device_name,
        monitor.monitor_id,
        if monitor.primary {
            "primary"
        } else {
            "NOT primary"
        }
    );
    let others: Vec<String> = display::enumerate()
        .into_iter()
        .filter(|m| m.attached && m.device_name != monitor.device_name)
        .map(|m| m.device_name)
        .collect();
    if others.is_empty() {
        log::info!("no other display is active");
    } else {
        log::warn!("other displays still active: {others:?}");
    }
    let modes = display::list_modes(&monitor.device_name);
    log::info!(
        "{} modes offered; exact {}x{}@{} present: {}",
        modes.len(),
        want.width,
        want.height,
        want.hz,
        modes.contains(&want)
    );
    let p = source.placement;
    log::info!(
        "Windows runs it at {}x{}@{} at ({}, {})",
        p.width,
        p.height,
        p.hz,
        p.x,
        p.y
    );
    let loc = &source.location;
    log::info!(
        "DXGI adapter {} ({}), output {} — {}",
        loc.adapter_index,
        loc.adapter_name,
        loc.output_index,
        if loc.adapter_luid == gpu.luid {
            "rendered on the selected GPU"
        } else {
            "NOT on the selected GPU"
        }
    );
    log::info!(
        "encoder would be {} on {}",
        encoder::encoder_name(gpu.vendor, Codec::Hevc, false),
        gpu.name
    );
    log::info!("holding for {seconds}s (your other displays are off until then)");
    std::thread::sleep(Duration::from_secs(seconds));
    let ended = std::time::Instant::now();
    drop(source);
    log::info!(
        "layout restored and virtual display removed in {:.1}s; active displays: {}",
        ended.elapsed().as_secs_f64(),
        display::enumerate()
            .iter()
            .filter(|m| m.attached)
            .map(|m| m.device_name.as_str())
            .collect::<Vec<_>>()
            .join(", ")
    );
    Ok(())
}

fn serve(args: ServeArgs) -> Result<()> {
    let name = args
        .name
        .or_else(|| std::env::var("COMPUTERNAME").ok())
        .unwrap_or_else(|| "Relay".into());

    let gpu = select_gpu(args.gpu.as_deref())?;
    let driver = if args.no_vdd {
        log::warn!("--no-vdd: streaming the primary display instead of a virtual one");
        None
    } else {
        Some(open_driver(args.driver)?)
    };
    let advertisement: discovery::AdSlot = Arc::new(Mutex::new(None));
    {
        let driver = driver.clone();
        let advertisement = Arc::clone(&advertisement);
        ctrlc::set_handler(move || shut_down("shutting down", driver.as_ref(), &advertisement))
            .context("installing Ctrl-C handler")?;
    }

    let identity = Arc::new(crypto::Identity::load_or_create(
        &state_dir()?.join("identity.key"),
    )?);
    let paired = Arc::new(Mutex::new(crypto::PeerList::load(
        &state_dir()?.join("paired-clients.txt"),
    )?));
    let pin_path = state_dir()?.join("pin.txt");
    let (pin, pin_fixed) = match args.pin {
        Some(p) if crypto::is_valid_pin(&p) => (p, true),
        Some(p) => anyhow::bail!("--pin {p:?} must be 4-8 digits"),
        None => (crypto::load_or_create_pin(&pin_path)?, false),
    };
    // The PIN itself stays out of the log: it is in the tray menu and
    // `relay-host pin`, and the log is a file now.
    log::info!(
        "identity {}; {} paired client(s)",
        crypto::fingerprint(identity.public.as_bytes()),
        paired.lock().unwrap().len()
    );
    let status = Arc::new(Mutex::new(status::HostStatus::new(
        pin, pin_fixed, pin_path,
    )));

    let cfg = server::ServerConfig {
        port: args.port,
        name,
        ffmpeg: args.ffmpeg,
        bitrate_mbps: args.bitrate,
        fps: args.fps,
        codec: args.codec.into(),
        gop_seconds: args.gop,
        quality: args.quality,
        intra_refresh: args.intra_refresh,
        prefer_ffmpeg: args.no_native,
        lock_physical: !args.no_lock_physical,
        gpu,
        driver: driver.clone(),
        allow_input: !args.no_input,
        identity,
        paired: Arc::clone(&paired),
        status: Arc::clone(&status),
        pair_limiter: Arc::new(Mutex::new(crypto::PairLimiter::new())),
        advertisement: Arc::clone(&advertisement),
    };
    // The accept loop never returns on its own; the tray's message loop owns
    // the main thread and Quit ends the process the way Ctrl-C does.
    std::thread::Builder::new()
        .name("server".into())
        .spawn(move || {
            if let Err(e) = server::run(cfg) {
                log::error!("server stopped: {e:#}");
                std::process::exit(1);
            }
        })
        .context("starting the server thread")?;
    tray::run(status, paired, move || {
        shut_down("quitting", driver.as_ref(), &advertisement)
    })
}

/// Where identity, PIN and the paired-client list live.
fn state_dir() -> Result<PathBuf> {
    relay_host::state_dir()
}

fn show_pin(new: bool) -> Result<()> {
    let path = state_dir()?.join("pin.txt");
    if new {
        let _ = std::fs::remove_file(&path);
    }
    let pin = crypto::load_or_create_pin(&path)?;
    let identity = crypto::Identity::load_or_create(&state_dir()?.join("identity.key"))?;
    println!("pairing PIN: {pin}");
    println!(
        "host fingerprint: {}",
        crypto::fingerprint(identity.public.as_bytes())
    );
    Ok(())
}

fn paired_clients(forget: Option<String>) -> Result<()> {
    let mut list = crypto::PeerList::load(&state_dir()?.join("paired-clients.txt"))?;
    if let Some(fp) = forget {
        let key = list
            .iter()
            .find(|(k, _)| crypto::fingerprint(k).eq_ignore_ascii_case(&fp))
            .map(|(k, _)| *k)
            .with_context(|| format!("no paired client with fingerprint {fp}"))?;
        list.remove(&key)?;
        println!("forgot {fp}");
    }
    if list.is_empty() {
        println!("no paired clients");
    }
    for (key, name) in list.iter() {
        println!("{}  {}", crypto::fingerprint(key), name);
    }
    Ok(())
}
