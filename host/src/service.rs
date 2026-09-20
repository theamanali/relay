//! The `Relay` Windows service: the privileged, always-on half of the host.
//!
//! It runs as SYSTEM in session 0, where nothing can be captured or shown,
//! so its only job is to keep a **worker** — `relay-host worker`, the normal
//! serving host — alive inside the interactive (console) session, running as
//! SYSTEM too. That is what lets the worker open the secure desktop and
//! stream the lock and login screens, change display topology while locked,
//! and flip device nodes without any elevated helper.
//!
//! Worker exit codes decide what happens next: **0** (quit event, logoff)
//! keeps it down until the next logon; anything else is a crash, so the
//! service runs `relay-host restore` in the session (physical monitors and
//! layout back) and starts a fresh worker with a backoff. A console session
//! change (logoff, fast user switch) moves the worker to the new session.
//! `Stop-Service` sets a named event the worker's tray loop waits on, so it
//! quits the way the tray's Exit does (which itself asks the SCM to stop the
//! service, so Exit takes everything down).

use std::ffi::OsString;
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::time::{Duration, Instant};

use anyhow::{bail, Context, Result};
use windows::core::{PCWSTR, PWSTR};
use windows::Win32::Foundation::{CloseHandle, HANDLE, WAIT_OBJECT_0, WAIT_TIMEOUT};
use windows::Win32::Security::{
    DuplicateTokenEx, SecurityIdentification, SetTokenInformation, TokenPrimary, TokenSessionId,
    TOKEN_ADJUST_SESSIONID, TOKEN_ASSIGN_PRIMARY, TOKEN_DUPLICATE, TOKEN_QUERY,
};
use windows::Win32::System::Environment::{CreateEnvironmentBlock, DestroyEnvironmentBlock};
use windows::Win32::System::RemoteDesktop::WTSGetActiveConsoleSessionId;
use windows::Win32::System::Services as services;
use windows::Win32::System::Threading::{
    CreateEventW, CreateProcessAsUserW, GetCurrentProcess, GetExitCodeProcess, OpenProcessToken,
    SetEvent, TerminateProcess, WaitForSingleObject, CREATE_UNICODE_ENVIRONMENT,
    PROCESS_INFORMATION, STARTUPINFOW,
};
use windows_service::service::{
    ServiceAccess, ServiceAction, ServiceActionType, ServiceControl, ServiceControlAccept,
    ServiceErrorControl, ServiceExitCode, ServiceFailureActions, ServiceFailureResetPeriod,
    ServiceInfo, ServiceStartType, ServiceState, ServiceStatus, ServiceType, SessionChangeReason,
};
use windows_service::service_control_handler::{self, ServiceControlHandlerResult};
use windows_service::service_manager::{ServiceManager, ServiceManagerAccess};
use windows_service::{define_windows_service, service_dispatcher};

pub const SERVICE_NAME: &str = "Relay";
const DISPLAY_NAME: &str = "Relay host";
const DESCRIPTION: &str =
    "Streams this PC's display to a paired Mac (tray icon). Runs the host inside the signed-in session.";
/// Named event the service sets to ask the worker to quit (Stop-Service,
/// shutdown). Suffixed with the session id because `Global\` is one namespace
/// for the whole machine.
pub const QUIT_EVENT_PREFIX: &str = "Global\\Relay.quit.";

const NO_SESSION: u32 = 0xFFFF_FFFF;
const POLL: Duration = Duration::from_secs(1);
const RESTART_DELAY: Duration = Duration::from_secs(5);
const SHORT_LIFE: Duration = Duration::from_secs(30);
const RESTART_BACKOFF: Duration = Duration::from_secs(60);
/// How long a worker gets to quit on its own after the quit event before it is killed.
const QUIT_GRACE: Duration = Duration::from_secs(15);
const RESTORE_TIMEOUT: Duration = Duration::from_secs(45);

// --- install / uninstall ---------------------------------------------------

/// Register the service to run `<exe> service run` as LocalSystem, auto-start,
/// restarting itself if it ever crashes (a service *can* rely on SCM recovery;
/// a killed process is a crash from SCM's point of view — unlike a task).
pub fn install(exe: &std::path::Path) -> Result<()> {
    let manager = ServiceManager::local_computer(
        None::<&str>,
        ServiceManagerAccess::CONNECT | ServiceManagerAccess::CREATE_SERVICE,
    )
    .context("opening the service manager (elevated prompt needed)")?;
    let info = ServiceInfo {
        name: OsString::from(SERVICE_NAME),
        display_name: OsString::from(DISPLAY_NAME),
        service_type: ServiceType::OWN_PROCESS,
        start_type: ServiceStartType::AutoStart,
        error_control: ServiceErrorControl::Normal,
        executable_path: exe.to_path_buf(),
        launch_arguments: vec![OsString::from("service"), OsString::from("run")],
        dependencies: vec![],
        account_name: None, // LocalSystem
        account_password: None,
    };
    let access = ServiceAccess::CHANGE_CONFIG | ServiceAccess::START | ServiceAccess::QUERY_STATUS;
    let service = match manager.create_service(&info, access) {
        Ok(s) => s,
        Err(windows_service::Error::Winapi(e)) if e.raw_os_error() == Some(1073) => {
            // ERROR_SERVICE_EXISTS: keep it, but point it at this exe.
            let s = manager
                .open_service(SERVICE_NAME, access | ServiceAccess::STOP)
                .context("opening the existing Relay service")?;
            s.change_config(&info)
                .context("updating the Relay service")?;
            s
        }
        Err(e) => return Err(e).context("creating the Relay service"),
    };
    service
        .set_description(DESCRIPTION)
        .context("setting the service description")?;
    service
        .update_failure_actions(ServiceFailureActions {
            reset_period: ServiceFailureResetPeriod::After(Duration::from_secs(24 * 3600)),
            reboot_msg: None,
            command: None,
            actions: Some(vec![
                ServiceAction {
                    action_type: ServiceActionType::Restart,
                    delay: Duration::from_secs(5),
                },
                ServiceAction {
                    action_type: ServiceActionType::Restart,
                    delay: Duration::from_secs(5),
                },
                ServiceAction {
                    action_type: ServiceActionType::Restart,
                    delay: Duration::from_secs(60),
                },
            ]),
        })
        .context("setting the service recovery actions")?;
    let _ = service.set_failure_actions_on_non_crash_failures(true);
    match service.query_status() {
        Ok(s) if s.current_state == ServiceState::Running => {}
        _ => service
            .start::<&str>(&[])
            .context("starting the Relay service")?,
    }
    Ok(())
}

pub fn uninstall() -> Result<()> {
    let manager = ServiceManager::local_computer(None::<&str>, ServiceManagerAccess::CONNECT)
        .context("opening the service manager (elevated prompt needed)")?;
    let service = manager
        .open_service(
            SERVICE_NAME,
            ServiceAccess::STOP | ServiceAccess::QUERY_STATUS | ServiceAccess::DELETE,
        )
        .context("the Relay service is not installed")?;
    if service.query_status()?.current_state != ServiceState::Stopped {
        let _ = service.stop();
        let deadline = Instant::now() + Duration::from_secs(30);
        while service.query_status()?.current_state != ServiceState::Stopped {
            if Instant::now() > deadline {
                bail!("the Relay service did not stop within 30 s");
            }
            std::thread::sleep(Duration::from_millis(250));
        }
    }
    service.delete().context("deleting the Relay service")?;
    Ok(())
}

pub fn is_installed() -> bool {
    ServiceManager::local_computer(None::<&str>, ServiceManagerAccess::CONNECT)
        .and_then(|m| m.open_service(SERVICE_NAME, ServiceAccess::QUERY_STATUS))
        .is_ok()
}

/// Installed and not stopped (starting/running/stopping all count: the SCM
/// is in charge of it). `None` when it is not installed.
pub fn is_active() -> Option<bool> {
    ServiceManager::local_computer(None::<&str>, ServiceManagerAccess::CONNECT)
        .and_then(|m| m.open_service(SERVICE_NAME, ServiceAccess::QUERY_STATUS))
        .and_then(|s| s.query_status())
        .ok()
        .map(|s| s.current_state != ServiceState::Stopped)
}

/// `Start-Service Relay`: the way back after "Start on system boot" was
/// turned off and the PC rebooted. Needs an administrator.
pub fn start() -> Result<()> {
    let manager = ServiceManager::local_computer(None::<&str>, ServiceManagerAccess::CONNECT)
        .context("opening the service manager")?;
    let service = manager
        .open_service(
            SERVICE_NAME,
            ServiceAccess::START | ServiceAccess::QUERY_STATUS,
        )
        .context("opening the Relay service (elevated prompt needed)")?;
    if service.query_status()?.current_state != ServiceState::Stopped {
        return Ok(());
    }
    service
        .start::<&str>(&[])
        .context("starting the Relay service")
}

// --- the tray's view of the service ------------------------------------------
//
// These go through the raw SCM API rather than `windows_service` because that
// crate's `change_config` rewrites the whole configuration (binary path
// included); `SERVICE_NO_CHANGE` lets us touch the start type alone.

/// The `Relay` service handle with `access`, closed on drop.
struct ScmService(services::SC_HANDLE, services::SC_HANDLE);

impl ScmService {
    fn open(access: u32) -> Result<Self> {
        unsafe {
            let manager = services::OpenSCManagerW(None, None, services::SC_MANAGER_CONNECT)
                .context("opening the service manager")?;
            let name: Vec<u16> = SERVICE_NAME.encode_utf16().chain(Some(0)).collect();
            match services::OpenServiceW(manager, PCWSTR(name.as_ptr()), access) {
                Ok(service) => Ok(ScmService(manager, service)),
                Err(e) => {
                    let _ = services::CloseServiceHandle(manager);
                    Err(e).context("opening the Relay service")
                }
            }
        }
    }
}

impl Drop for ScmService {
    fn drop(&mut self) {
        unsafe {
            let _ = services::CloseServiceHandle(self.1);
            let _ = services::CloseServiceHandle(self.0);
        }
    }
}

/// Whether the service starts with Windows (`Automatic`). `None` when it is
/// not installed or cannot be queried.
pub fn start_on_boot() -> Option<bool> {
    let service = ScmService::open(services::SERVICE_QUERY_CONFIG).ok()?;
    unsafe {
        let mut needed = 0u32;
        // Size probe first; the config carries variable-length strings.
        let _ = services::QueryServiceConfigW(service.1, None, 0, &mut needed);
        let mut buf = vec![0u64; needed.div_ceil(8) as usize + 1];
        let config = buf.as_mut_ptr() as *mut services::QUERY_SERVICE_CONFIGW;
        services::QueryServiceConfigW(service.1, Some(config), needed, &mut needed).ok()?;
        Some((*config).dwStartType == services::SERVICE_AUTO_START)
    }
}

/// Switch the service between `Automatic` (start with Windows) and `Manual`.
/// Needs SYSTEM or an administrator; the tray runs as the former.
pub fn set_start_on_boot(on: bool) -> Result<()> {
    let service = ScmService::open(services::SERVICE_CHANGE_CONFIG)?;
    let start = if on {
        services::SERVICE_AUTO_START
    } else {
        services::SERVICE_DEMAND_START
    };
    unsafe {
        services::ChangeServiceConfigW(
            service.1,
            services::ENUM_SERVICE_TYPE(services::SERVICE_NO_CHANGE),
            start,
            services::SERVICE_ERROR(services::SERVICE_NO_CHANGE),
            None,
            None,
            None,
            None,
            None,
            None,
            None,
        )
        .context("changing the Relay service start type")
    }
}

/// Ask the SCM to stop the service, exactly as `Stop-Service Relay` does.
/// The service then sets the quit event, so a worker calling this quits
/// through its own tray loop a moment later.
pub fn stop_service() -> Result<()> {
    let service = ScmService::open(services::SERVICE_STOP)?;
    let mut status = services::SERVICE_STATUS::default();
    unsafe {
        services::ControlService(service.1, services::SERVICE_CONTROL_STOP, &mut status)
            .context("stopping the Relay service")
    }
}

// --- the service process ---------------------------------------------------

/// Entry point for `relay-host service run`: hands the thread to the SCM.
pub fn run() -> Result<()> {
    service_dispatcher::start(SERVICE_NAME, ffi_service_main)
        .context("connecting to the service control manager (this is meant to be started by SCM)")
}

define_windows_service!(ffi_service_main, service_main);

enum Event {
    Stop,
    Session(SessionChangeReason, u32),
}

fn service_main(_arguments: Vec<OsString>) {
    if let Err(e) = service_body() {
        log::error!("service failed: {e:#}");
    }
}

fn service_body() -> Result<()> {
    let (tx, rx): (Sender<Event>, Receiver<Event>) = mpsc::channel();
    let handle = service_control_handler::register(SERVICE_NAME, move |control| match control {
        ServiceControl::Stop | ServiceControl::Shutdown => {
            let _ = tx.send(Event::Stop);
            ServiceControlHandlerResult::NoError
        }
        ServiceControl::SessionChange(p) => {
            let _ = tx.send(Event::Session(p.reason, p.notification.session_id));
            ServiceControlHandlerResult::NoError
        }
        ServiceControl::Interrogate => ServiceControlHandlerResult::NoError,
        _ => ServiceControlHandlerResult::NotImplemented,
    })
    .context("registering the service control handler")?;
    let set_state = |state: ServiceState, accept: ServiceControlAccept| {
        let _ = handle.set_service_status(ServiceStatus {
            service_type: ServiceType::OWN_PROCESS,
            current_state: state,
            controls_accepted: accept,
            exit_code: ServiceExitCode::Win32(0),
            checkpoint: 0,
            wait_hint: Duration::from_secs(20),
            process_id: None,
        });
    };
    set_state(
        ServiceState::Running,
        ServiceControlAccept::STOP
            | ServiceControlAccept::SHUTDOWN
            | ServiceControlAccept::SESSION_CHANGE,
    );
    log::info!("Relay service running");

    let mut sup = Supervisor::default();
    loop {
        match rx.recv_timeout(POLL) {
            Ok(Event::Stop) => break,
            Ok(Event::Session(reason, id)) => sup.on_session_change(reason, id),
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => break,
        }
        sup.tick();
    }
    set_state(ServiceState::StopPending, ServiceControlAccept::empty());
    sup.shutdown();
    set_state(ServiceState::Stopped, ServiceControlAccept::empty());
    log::info!("Relay service stopped");
    Ok(())
}

/// Keeps one worker in the console session.
#[derive(Default)]
struct Supervisor {
    worker: Option<Worker>,
    /// False after a clean exit: nothing until someone signs in again.
    wanted: bool,
    started_once: bool,
    /// Earliest time to start the next worker (restart backoff).
    not_before: Option<Instant>,
}

struct Worker {
    process: Process,
    session: u32,
    quit_event: HANDLE,
    started: Instant,
}

impl Supervisor {
    fn on_session_change(&mut self, reason: SessionChangeReason, id: u32) {
        log::info!("session {id}: {reason:?}");
        match reason {
            SessionChangeReason::SessionLogon | SessionChangeReason::ConsoleConnect => {
                // Someone is (back) at the console: a quit worker is wanted
                // again — unless the tray's "Start on system boot" is off,
                // which also means "nothing at sign-in" until it is on again
                // (`Start-Service Relay` remains the manual way in).
                if start_on_boot() == Some(false) {
                    log::info!("Start on system boot is off; not starting Relay for this sign-in");
                    return;
                }
                self.wanted = true;
                self.not_before = None;
            }
            _ => {}
        }
    }

    fn tick(&mut self) {
        if !self.started_once {
            self.started_once = true;
            self.wanted = true;
        }
        let console = unsafe { WTSGetActiveConsoleSessionId() };

        // A worker that is running: still alive? still in the console session?
        if let Some(w) = &mut self.worker {
            match w.process.exit_code() {
                None => {
                    if console != NO_SESSION && w.session != console {
                        log::info!(
                            "console moved from session {} to {}; moving the worker",
                            w.session,
                            console
                        );
                        self.stop_worker(true);
                    }
                    return;
                }
                Some(0) => {
                    log::info!("worker quit; waiting for the next sign-in");
                    self.take_worker();
                    self.wanted = false;
                }
                Some(code) => {
                    let lived = w.started.elapsed();
                    let w = self.take_worker().expect("worker");
                    log::warn!(
                        "worker exited with {code:#x} after {:.0} s; restoring displays",
                        lived.as_secs_f64()
                    );
                    match spawn_in_session(w.session, &["restore"]) {
                        Ok(p) => {
                            if p.wait(RESTORE_TIMEOUT).is_none() {
                                log::warn!("restore did not finish within {RESTORE_TIMEOUT:?}");
                                p.kill();
                            }
                        }
                        Err(e) => log::warn!("could not run restore: {e:#}"),
                    }
                    let delay = if lived < SHORT_LIFE {
                        RESTART_BACKOFF
                    } else {
                        RESTART_DELAY
                    };
                    log::info!("next worker in {} s", delay.as_secs());
                    self.not_before = Some(Instant::now() + delay);
                }
            }
        }

        if !self.wanted || console == NO_SESSION {
            return;
        }
        if let Some(t) = self.not_before {
            if Instant::now() < t {
                return;
            }
        }
        match self.spawn_worker(console) {
            Ok(()) => {}
            Err(e) => {
                log::warn!("could not start the worker in session {console}: {e:#}");
                self.not_before = Some(Instant::now() + RESTART_DELAY);
            }
        }
    }

    fn spawn_worker(&mut self, session: u32) -> Result<()> {
        let quit_event = create_quit_event(session)?;
        let process = match spawn_in_session(session, &["worker"]) {
            Ok(p) => p,
            Err(e) => {
                unsafe {
                    let _ = CloseHandle(quit_event);
                }
                return Err(e);
            }
        };
        log::info!("worker started in session {session} (pid {})", process.pid);
        self.worker = Some(Worker {
            process,
            session,
            quit_event,
            started: Instant::now(),
        });
        self.not_before = None;
        Ok(())
    }

    /// Ask the worker to quit (it restores the displays itself); kill it if it
    /// does not. `respawn` keeps `wanted` so `tick` starts a new one.
    fn stop_worker(&mut self, respawn: bool) {
        if let Some(w) = self.take_worker() {
            unsafe {
                let _ = SetEvent(w.quit_event);
            }
            if w.process.wait(QUIT_GRACE).is_none() {
                log::warn!("worker did not quit within {QUIT_GRACE:?}; killing it");
                w.process.kill();
            }
        }
        self.wanted = respawn;
    }

    fn take_worker(&mut self) -> Option<Worker> {
        self.worker.take()
    }

    fn shutdown(&mut self) {
        self.stop_worker(false);
    }
}

impl Drop for Worker {
    fn drop(&mut self) {
        unsafe {
            let _ = CloseHandle(self.quit_event);
        }
    }
}

fn create_quit_event(session: u32) -> Result<HANDLE> {
    let name: Vec<u16> = format!("{QUIT_EVENT_PREFIX}{session}")
        .encode_utf16()
        .chain(Some(0))
        .collect();
    unsafe { CreateEventW(None, true, false, PCWSTR(name.as_ptr())) }
        .context("creating the worker quit event")
}

// --- spawning into the console session --------------------------------------

/// A child started with `spawn_in_session`.
pub struct Process {
    handle: HANDLE,
    pub pid: u32,
}

impl Process {
    /// `Some(code)` once it has exited.
    pub fn exit_code(&self) -> Option<u32> {
        let mut code = 0u32;
        unsafe {
            if GetExitCodeProcess(self.handle, &mut code).is_err() {
                return Some(u32::MAX);
            }
        }
        // STILL_ACTIVE
        if code == 259 {
            None
        } else {
            Some(code)
        }
    }

    pub fn wait(&self, timeout: Duration) -> Option<u32> {
        let r = unsafe { WaitForSingleObject(self.handle, timeout.as_millis() as u32) };
        if r == WAIT_OBJECT_0 {
            self.exit_code()
        } else if r == WAIT_TIMEOUT {
            None
        } else {
            Some(u32::MAX)
        }
    }

    pub fn kill(&self) {
        unsafe {
            let _ = TerminateProcess(self.handle, 1);
        }
    }
}

impl Drop for Process {
    fn drop(&mut self) {
        unsafe {
            let _ = CloseHandle(self.handle);
        }
    }
}

/// Start this exe with `args` inside `session`, as SYSTEM (the service's own
/// account), on the default desktop of the interactive window station. The
/// trick is a copy of our token with its session id changed: `TokenSessionId`
/// needs SE_TCB, which LocalSystem has. `CreateProcessAsUserW` then places
/// the child in that session with our privileges intact.
pub fn spawn_in_session(session: u32, args: &[&str]) -> Result<Process> {
    let exe = std::env::current_exe().context("locating the running exe")?;
    let mut cmdline = format!("\"{}\"", exe.display());
    for a in args {
        cmdline.push(' ');
        cmdline.push_str(a);
    }
    let mut cmdline: Vec<u16> = cmdline.encode_utf16().chain(Some(0)).collect();
    let desktop: Vec<u16> = "winsta0\\default".encode_utf16().chain(Some(0)).collect();
    unsafe {
        let mut own = HANDLE::default();
        OpenProcessToken(
            GetCurrentProcess(),
            TOKEN_DUPLICATE | TOKEN_QUERY | TOKEN_ASSIGN_PRIMARY | TOKEN_ADJUST_SESSIONID,
            &mut own,
        )
        .context("OpenProcessToken")?;
        let mut token = HANDLE::default();
        let dup = DuplicateTokenEx(
            own,
            windows::Win32::Security::TOKEN_ACCESS_MASK(0x0200_0000), // MAXIMUM_ALLOWED
            None,
            SecurityIdentification,
            TokenPrimary,
            &mut token,
        );
        let _ = CloseHandle(own);
        dup.context("DuplicateTokenEx")?;
        let result = (|| -> Result<Process> {
            let mut id = session;
            SetTokenInformation(
                token,
                TokenSessionId,
                &mut id as *mut u32 as *const _,
                std::mem::size_of::<u32>() as u32,
            )
            .context("SetTokenInformation(TokenSessionId) — needs SE_TCB (LocalSystem)")?;
            let mut env: *mut std::ffi::c_void = std::ptr::null_mut();
            CreateEnvironmentBlock(&mut env, token, false).context("CreateEnvironmentBlock")?;
            let si = STARTUPINFOW {
                cb: std::mem::size_of::<STARTUPINFOW>() as u32,
                lpDesktop: PWSTR(desktop.as_ptr() as *mut u16),
                ..Default::default()
            };
            let mut pi = PROCESS_INFORMATION::default();
            let created = CreateProcessAsUserW(
                token,
                PCWSTR::null(),
                PWSTR(cmdline.as_mut_ptr()),
                None,
                None,
                false,
                CREATE_UNICODE_ENVIRONMENT,
                Some(env),
                PCWSTR::null(),
                &si,
                &mut pi,
            );
            let _ = DestroyEnvironmentBlock(env);
            created.context("CreateProcessAsUserW")?;
            let _ = CloseHandle(pi.hThread);
            Ok(Process {
                handle: pi.hProcess,
                pid: pi.dwProcessId,
            })
        })();
        let _ = CloseHandle(token);
        result
    }
}

/// The worker's side of the quit event: `None` when not started by the
/// service (a dev run), so the tray loop has nothing extra to wait on.
pub fn open_quit_event() -> Option<HANDLE> {
    use windows::Win32::System::Threading::{OpenEventW, SYNCHRONIZATION_SYNCHRONIZE};
    let session = unsafe { WTSGetActiveConsoleSessionId() };
    let name: Vec<u16> = format!("{QUIT_EVENT_PREFIX}{session}")
        .encode_utf16()
        .chain(Some(0))
        .collect();
    unsafe { OpenEventW(SYNCHRONIZATION_SYNCHRONIZE, false, PCWSTR(name.as_ptr())) }.ok()
}
