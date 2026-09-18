//! Start at login: a Task Scheduler logon task for the current user, created
//! by the host itself without elevation (users may register logon tasks that
//! run as themselves). The task runs a copy of the exe under
//! `%LOCALAPPDATA%\Relay\bin`, so `cargo build` never collides with the
//! auto-started instance and the repo can move. The task runs `supervise`,
//! which restarts the host after a crash; a clean Quit (exit 0) stays quit.

use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, Instant};

use anyhow::{anyhow, Context, Result};

const TASK_NAME: &str = "Relay host";
/// `CREATE_NO_WINDOW`: no console flashes when the windowless host runs schtasks.
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

/// Where the login copy of the exe lives.
pub fn bin_path() -> Result<PathBuf> {
    Ok(crate::state_dir()?.join("bin").join("relay-host.exe"))
}

pub fn is_enabled() -> bool {
    schtasks(&["/Query", "/TN", TASK_NAME]).is_ok()
}

/// Copy the running exe into place and register the logon task.
pub fn enable() -> Result<()> {
    copy_exe()?;
    let exe = bin_path()?;
    let user = current_user();
    let xml = task_xml(&exe, &user);
    // schtasks reads the XML as UTF-16 with a BOM; anything else is a gamble.
    let mut bytes = vec![0xff, 0xfe];
    for unit in xml.encode_utf16() {
        bytes.extend_from_slice(&unit.to_le_bytes());
    }
    let tmp = crate::state_dir()?.join("relay-host-task.xml");
    std::fs::write(&tmp, bytes).with_context(|| format!("writing {}", tmp.display()))?;
    let result = schtasks(&[
        "/Create",
        "/TN",
        TASK_NAME,
        "/XML",
        &tmp.to_string_lossy(),
        "/F",
    ]);
    let _ = std::fs::remove_file(&tmp);
    result.map(|_| ())
}

pub fn disable() -> Result<()> {
    schtasks(&["/Delete", "/TN", TASK_NAME, "/F"]).map(|_| ())
}

/// The build that was last run is the one that starts at login: when the
/// task exists and this exe is not the login copy, refresh the copy. Never
/// fatal — the host works fine either way.
pub fn refresh_copy() {
    if !is_enabled() {
        return;
    }
    match copy_exe() {
        Ok(true) => log::info!("login copy updated"),
        Ok(false) => {}
        Err(e) => log::warn!("could not update the login copy: {e:#}"),
    }
}

/// Between restarts of a host that died.
const RESTART_DELAY: Duration = Duration::from_secs(5);
/// A host that keeps dying this quickly is backed off to `RESTART_BACKOFF`
/// (a port taken by something else, say) rather than hammered every 5 s.
const SHORT_LIFE: Duration = Duration::from_secs(30);
const RESTART_BACKOFF: Duration = Duration::from_secs(60);

/// What the logon task runs. Task Scheduler's own RestartOnFailure only
/// covers a task that could not be *launched*; a host that crashes or is
/// killed counts as completed and stays down. So the task runs this instead:
/// serve in a child, and start it again whenever it exits non-zero. A clean
/// Quit (exit 0) ends the supervisor too.
pub fn supervise() -> Result<()> {
    let me = std::env::current_exe().context("locating the running exe")?;
    loop {
        let started = Instant::now();
        let status = Command::new(&me)
            .status()
            .with_context(|| format!("starting {}", me.display()))?;
        if status.success() {
            log::info!("host exited cleanly; supervisor done");
            return Ok(());
        }
        let delay = if started.elapsed() < SHORT_LIFE {
            RESTART_BACKOFF
        } else {
            RESTART_DELAY
        };
        log::warn!(
            "host exited with {}; restarting in {} s",
            status
                .code()
                .map(|c| format!("code {c:#x}"))
                .unwrap_or_else(|| "no exit code".into()),
            delay.as_secs()
        );
        std::thread::sleep(delay);
    }
}

/// Copy the running exe to `bin_path()`. Returns whether anything was copied
/// (false when this already is the login copy).
fn copy_exe() -> Result<bool> {
    let me = std::env::current_exe().context("locating the running exe")?;
    let target = bin_path()?;
    if same_file(&me, &target) {
        return Ok(false);
    }
    if let Some(dir) = target.parent() {
        std::fs::create_dir_all(dir).with_context(|| format!("creating {}", dir.display()))?;
    }
    std::fs::copy(&me, &target)
        .with_context(|| format!("copying {} to {}", me.display(), target.display()))?;
    Ok(true)
}

fn same_file(a: &Path, b: &Path) -> bool {
    match (std::fs::canonicalize(a), std::fs::canonicalize(b)) {
        (Ok(a), Ok(b)) => a == b,
        _ => false,
    }
}

fn current_user() -> String {
    let name = std::env::var("USERNAME").unwrap_or_default();
    match std::env::var("USERDOMAIN") {
        Ok(domain) if !domain.is_empty() => format!("{domain}\\{name}"),
        _ => name,
    }
}

/// Task Scheduler XML (schema 1.2). Priority 4 is "normal": the scheduler's
/// default of 7 runs tasks below normal, which would quietly make the
/// auto-started host a lower-priority process than one launched by hand.
/// No RestartOnFailure: it never fires for a process that dies (see
/// `supervise`).
pub fn task_xml(exe: &Path, user: &str) -> String {
    let exe_str = xml_escape(&exe.to_string_lossy());
    let dir = exe
        .parent()
        .map(|p| xml_escape(&p.to_string_lossy()))
        .unwrap_or_default();
    let user = xml_escape(user);
    format!(
        r#"<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo>
    <Description>Starts the Relay host at logon (tray icon). Registered by relay-host.exe.</Description>
  </RegistrationInfo>
  <Triggers>
    <LogonTrigger>
      <Enabled>true</Enabled>
      <UserId>{user}</UserId>
      <Delay>PT5S</Delay>
    </LogonTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>{user}</UserId>
      <LogonType>InteractiveToken</LogonType>
      <RunLevel>LeastPrivilege</RunLevel>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <RunOnlyIfNetworkAvailable>false</RunOnlyIfNetworkAvailable>
    <AllowStartOnDemand>true</AllowStartOnDemand>
    <Enabled>true</Enabled>
    <Hidden>false</Hidden>
    <RunOnlyIfIdle>false</RunOnlyIfIdle>
    <WakeToRun>false</WakeToRun>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <Priority>4</Priority>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>{exe_str}</Command>
      <Arguments>supervise</Arguments>
      <WorkingDirectory>{dir}</WorkingDirectory>
    </Exec>
  </Actions>
</Task>
"#
    )
}

fn xml_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

fn schtasks(args: &[&str]) -> Result<String> {
    let out = Command::new("schtasks.exe")
        .args(args)
        .creation_flags(CREATE_NO_WINDOW)
        .output()
        .context("running schtasks.exe")?;
    if out.status.success() {
        Ok(String::from_utf8_lossy(&out.stdout).into_owned())
    } else {
        let err = String::from_utf8_lossy(&out.stderr);
        let err = err.trim();
        Err(anyhow!(
            "schtasks {} failed{}",
            args.first().copied().unwrap_or(""),
            if err.is_empty() {
                String::new()
            } else {
                format!(": {err}")
            }
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn task_xml_points_at_the_exe_with_normal_priority_and_restart() {
        let xml = task_xml(
            Path::new(r"C:\Users\A&B\AppData\Local\Relay\bin\relay-host.exe"),
            r"PC\A&B",
        );
        assert!(xml.contains(
            r"<Command>C:\Users\A&amp;B\AppData\Local\Relay\bin\relay-host.exe</Command>"
        ));
        assert!(xml.contains(
            r"<WorkingDirectory>C:\Users\A&amp;B\AppData\Local\Relay\bin</WorkingDirectory>"
        ));
        assert_eq!(xml.matches(r"<UserId>PC\A&amp;B</UserId>").count(), 2);
        assert!(xml.contains("<Priority>4</Priority>"));
        assert!(xml.contains("<Arguments>supervise</Arguments>"));
        assert!(!xml.contains("RestartOnFailure"));
        assert!(xml.contains("<LogonType>InteractiveToken</LogonType>"));
        assert!(xml.contains("<ExecutionTimeLimit>PT0S</ExecutionTimeLimit>"));
        assert!(xml.contains("<StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>"));
    }
}
