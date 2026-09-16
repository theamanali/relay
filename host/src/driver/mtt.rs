//! MikeTheTech Virtual Display Driver (MTT VDD) backend.
//! <https://github.com/VirtualDrivers/Virtual-Display-Driver>
//!
//! The driver reads `vdd_settings.xml` (folder named by the registry value
//! `HKLM\SOFTWARE\MikeTheTech\VirtualDisplayDriver\VDDPATH`) when its device
//! starts, and always keeps exactly one monitor while it runs (a count of 0 is
//! treated as 1). Its control pipe is deliberately not used: the reload commands
//! crash the driver's user-mode host (release 25.7.23) and Windows stops
//! restarting it after five crashes. So the device node itself is the switch:
//!
//! * between sessions the device is **disabled** — no monitor exists at all;
//! * a session **enables** it (which also loads any settings change: the
//!   template already lists every Apple laptop panel, so the file rarely
//!   changes) and the session then activates the monitor exclusively through
//!   `topology::exclusive`.
//!
//! Enabling/disabling needs elevation, which the host never has. The installer
//! registers a scheduled task that runs `vdd-device.ps1` with highest
//! privileges; the host writes its order to `action.txt` and starts the task.
//! The `enable` order also leaves that script watching the host process: if the
//! host dies mid-session it disables the device, and Windows brings the
//! physical monitors back on its own.

use std::cell::Cell;
use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::thread;
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Context, Result};
use regex::Regex;
use winreg::enums::HKEY_LOCAL_MACHINE;
use winreg::RegKey;

use crate::display::{self, Mode, Monitor};
use crate::driver::{Attachment, VirtualDisplay};
use crate::gpu::GpuInfo;

const REG_KEY: &str = r"SOFTWARE\MikeTheTech\VirtualDisplayDriver";
const SETTINGS_FILE: &str = "vdd_settings.xml";
const ACTION_FILE: &str = "action.txt";
/// PnP id the driver's monitors carry (`MONITOR\MTT1337\...`).
pub const MONITOR_PNP_ID: &str = "MTT1337";
/// Scheduled task (registered by tools/install-host.ps1, "run with highest
/// privileges") that runs vdd-device.ps1 with the order in action.txt.
pub const HELPER_TASK: &str = "Relay display driver";

const APPEAR_TIMEOUT: Duration = Duration::from_secs(30);
const GONE_TIMEOUT: Duration = Duration::from_secs(15);
const PHYSICAL_TIMEOUT: Duration = Duration::from_secs(15);

pub struct MttVdd {
    settings: PathBuf,
    /// True once this process enabled the device (and so has a watcher on it).
    enabled_by_us: Cell<bool>,
    physical_locked_by_us: Cell<bool>,
}

// `Cell` is fine: the host drives the driver from one thread at a time.
unsafe impl Sync for MttVdd {}

impl MttVdd {
    /// Succeeds if the driver is installed (registry key + settings file). The
    /// device is normally disabled at this point; `attach` enables it.
    pub fn detect() -> Result<Self> {
        let key = RegKey::predef(HKEY_LOCAL_MACHINE)
            .open_subkey(REG_KEY)
            .context("MTT VDD registry key not found — driver not installed?")?;
        let dir: String = key
            .get_value("VDDPATH")
            .context("VDDPATH missing under the MTT VDD registry key")?;
        let settings = Path::new(&dir).join(SETTINGS_FILE);
        if !settings.exists() {
            bail!(
                "{} does not exist (tools/install-host.ps1 creates it)",
                settings.display()
            );
        }
        log::info!(
            "MTT Virtual Display Driver installed ({})",
            settings.display()
        );
        Ok(MttVdd {
            settings,
            enabled_by_us: Cell::new(false),
            physical_locked_by_us: Cell::new(false),
        })
    }

    pub fn settings_path(&self) -> &Path {
        &self.settings
    }

    fn dir(&self) -> &Path {
        self.settings
            .parent()
            .expect("settings file has a parent directory")
    }

    /// Merge `mode` (and the render GPU) into vdd_settings.xml. Returns true if
    /// the file changed, meaning the device must be (re)started to notice.
    pub fn write_settings(&self, mode: Mode, gpu_name: &str) -> Result<bool> {
        let original = fs::read_to_string(&self.settings)
            .with_context(|| format!("reading {}", self.settings.display()))?;
        let backup = self.settings.with_extension("xml.bak");
        if !backup.exists() {
            let _ = fs::write(&backup, &original);
        }
        let updated = render_settings(&original, mode, gpu_name)?;
        if updated == original {
            return Ok(false);
        }
        let tmp = self.settings.with_extension("xml.tmp");
        fs::write(&tmp, &updated).with_context(|| format!("writing {}", tmp.display()))?;
        fs::rename(&tmp, &self.settings)
            .with_context(|| format!("replacing {}", self.settings.display()))?;
        Ok(true)
    }

    /// Hand an order to the elevated helper and start it.
    fn run_helper(&self, action: &str) -> Result<()> {
        write_action(self.dir(), action)?;
        let output = Command::new("schtasks")
            .args(["/run", "/tn", HELPER_TASK])
            .output()
            .context("running schtasks")?;
        if !output.status.success() {
            bail!(
                "could not start the '{HELPER_TASK}' task ({}). Run tools/install-host.ps1 \
                 again (elevated) to register it.",
                String::from_utf8_lossy(&output.stderr).trim()
            );
        }
        log::debug!("MTT VDD helper: {action}");
        Ok(())
    }

    fn guard_file(&self) -> PathBuf {
        self.dir().join(format!("guard-{}.txt", std::process::id()))
    }

    fn physical_state_file(&self) -> PathBuf {
        self.dir()
            .join(format!("physical-{}.txt", std::process::id()))
    }

    fn physical_ready_file(&self) -> PathBuf {
        self.dir()
            .join(format!("physical-{}.ready", std::process::id()))
    }

    fn physical_heartbeat_file(&self) -> PathBuf {
        self.dir()
            .join(format!("physical-{}.heartbeat", std::process::id()))
    }

    fn wait_for_physical_helper(&self, locked: bool) -> Result<()> {
        let deadline = Instant::now() + PHYSICAL_TIMEOUT;
        loop {
            let ready = self.physical_ready_file().exists();
            let state = self.physical_state_file().exists();
            if (locked && ready) || (!locked && !ready && !state) {
                return Ok(());
            }
            if Instant::now() >= deadline {
                bail!(
                    "elevated helper did not {} physical monitors within {PHYSICAL_TIMEOUT:?}",
                    if locked { "lock" } else { "restore" }
                );
            }
            thread::sleep(Duration::from_millis(100));
        }
    }

    /// Enable the device (the monitor appears) and leave the helper watching
    /// this process so a crash still ends with the device disabled.
    fn enable(&self) -> Result<()> {
        let is_virtual = |m: &Monitor| self.is_virtual(m);
        let started = Instant::now();
        fs::write(self.guard_file(), b"")?;
        self.run_helper(&format!("enable {}", std::process::id()))?;
        let deadline = started + APPEAR_TIMEOUT;
        while display::present_matching(&is_virtual).is_empty() {
            if Instant::now() >= deadline {
                bail!("MTT VDD monitor did not appear within {APPEAR_TIMEOUT:?} of enabling the device");
            }
            thread::sleep(Duration::from_millis(100));
        }
        // Let Windows finish applying whatever it remembers for this monitor.
        thread::sleep(Duration::from_millis(750));
        self.enabled_by_us.set(true);
        log::info!(
            "MTT VDD: device enabled, monitor present after {:.1}s",
            started.elapsed().as_secs_f64()
        );
        Ok(())
    }

    /// Disable the device: the monitor disappears completely.
    fn disable(&self) -> Result<()> {
        let is_virtual = |m: &Monitor| self.is_virtual(m);
        // Release the watcher first so it does not race us.
        let _ = fs::remove_file(self.guard_file());
        self.enabled_by_us.set(false);
        let started = Instant::now();
        self.run_helper("disable")?;
        let deadline = started + GONE_TIMEOUT;
        while !display::present_matching(&is_virtual).is_empty() {
            if Instant::now() >= deadline {
                log::warn!(
                    "MTT VDD monitor still present {GONE_TIMEOUT:?} after disabling the device"
                );
                return Ok(());
            }
            thread::sleep(Duration::from_millis(100));
        }
        log::info!(
            "MTT VDD: device disabled after {:.1}s",
            started.elapsed().as_secs_f64()
        );
        Ok(())
    }
}

/// Write the helper's order file (separate so it can be unit-tested).
fn write_action(dir: &Path, action: &str) -> Result<()> {
    let path = dir.join(ACTION_FILE);
    fs::write(&path, action).with_context(|| format!("writing {}", path.display()))
}

impl VirtualDisplay for MttVdd {
    fn name(&self) -> &'static str {
        "MTT Virtual Display Driver"
    }

    fn pnp_id(&self) -> &'static str {
        MONITOR_PNP_ID
    }

    fn dynamic_modes(&self) -> bool {
        true
    }

    /// Make sure the driver's monitor exists, offers the wanted mode and is
    /// rendered on the wanted GPU. Whether it is on the desktop is up to the
    /// session (`topology::exclusive`).
    fn attach(&self, mode: Mode, gpu: &GpuInfo) -> Result<(Attachment, Monitor)> {
        let is_virtual = |m: &Monitor| self.is_virtual(m);
        let changed = self.write_settings(mode, &gpu.name)?;
        let present = display::present_matching(&is_virtual);
        let stale = present
            .iter()
            .find(|m| m.attached)
            .is_some_and(|m| !display::list_modes(&m.device_name).contains(&mode));
        if !present.is_empty() && (changed || stale || !self.enabled_by_us.get()) {
            // Cycle it: the driver re-reads settings on start, and we want the
            // helper watching this process for the rest of the session.
            let why = if changed {
                "settings changed"
            } else if stale {
                "mode list is stale"
            } else {
                "not started by this host"
            };
            log::info!("MTT VDD: restarting the device ({why})");
            self.disable()?;
        }
        if display::present_matching(&is_virtual).is_empty() {
            log::info!(
                "MTT VDD: enabling the device for {}x{}@{} on {}",
                mode.width,
                mode.height,
                mode.hz,
                gpu.name
            );
            self.enable()?;
        }
        let monitor = display::present_matching(&is_virtual)
            .into_iter()
            .max_by_key(|m| m.attached)
            .ok_or_else(|| anyhow!("MTT VDD monitor device not found"))?;
        Ok((
            Attachment::Mtt {
                device_name: monitor.device_name.clone(),
            },
            monitor,
        ))
    }

    fn lock_physical_outputs(&self) -> Result<()> {
        if self.physical_locked_by_us.get() {
            return Ok(());
        }
        self.run_helper(&format!("lock-physical {}", std::process::id()))?;
        self.wait_for_physical_helper(true)?;
        self.physical_locked_by_us.set(true);
        log::info!("MTT VDD: physical monitor devices disabled for the session");
        Ok(())
    }

    fn heartbeat_physical_outputs(&self) -> Result<()> {
        if self.physical_locked_by_us.get() {
            fs::write(self.physical_heartbeat_file(), b"alive").with_context(|| {
                format!(
                    "updating physical-monitor heartbeat {}",
                    self.physical_heartbeat_file().display()
                )
            })?;
        }
        Ok(())
    }

    fn unlock_physical_outputs(&self) -> Result<()> {
        if !self.physical_locked_by_us.get()
            && !self.physical_state_file().exists()
            && !self.physical_ready_file().exists()
        {
            return Ok(());
        }
        self.run_helper(&format!("unlock-physical {}", std::process::id()))?;
        self.wait_for_physical_helper(false)?;
        self.physical_locked_by_us.set(false);
        log::info!("MTT VDD: physical monitor devices restored");
        Ok(())
    }

    fn detach(&self, attachment: Attachment) -> Result<()> {
        self.unlock_physical_outputs()?;
        match attachment {
            Attachment::Mtt { device_name } => {
                log::debug!("MTT VDD: releasing {device_name}");
                self.disable()
            }
            other => bail!("MTT VDD cannot detach {other:?}"),
        }
    }

    fn cleanup(&self) -> Result<()> {
        // Recover monitor devices left disabled if a previous helper watcher
        // was interrupted before it could observe the host exit.
        self.run_helper("unlock-stale")?;
        let deadline = Instant::now() + PHYSICAL_TIMEOUT;
        loop {
            let pending = fs::read_dir(self.dir())?
                .filter_map(Result::ok)
                .filter_map(|entry| entry.file_name().into_string().ok())
                .any(|name| {
                    name.starts_with("physical-")
                        && (name.ends_with(".txt") || name.ends_with(".ready"))
                });
            if !pending {
                break;
            }
            if Instant::now() >= deadline {
                bail!("elevated helper did not restore stale physical monitors within {PHYSICAL_TIMEOUT:?}");
            }
            thread::sleep(Duration::from_millis(100));
        }
        self.physical_locked_by_us.set(false);
        let is_virtual = |m: &Monitor| self.is_virtual(m);
        if display::present_matching(&is_virtual).is_empty() {
            return Ok(());
        }
        log::info!("MTT VDD: disabling a device left enabled by an earlier session");
        self.disable()
    }
}

fn xml_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
}

fn xml_unescape(s: &str) -> String {
    s.replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&amp;", "&")
}

/// Everything the driver derives its target modes from.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Settings {
    gpu: String,
    /// (width, height, refresh) entries in file order.
    resolutions: Vec<(u32, u32, u32)>,
    /// Refresh rates applied to every resolution.
    global_rates: BTreeSet<u32>,
}

fn parse_settings(xml: &str) -> Settings {
    let gpu_re = Regex::new(r"(?m)^[ \t]*<gpu>\s*<friendlyname>([^<]*)</friendlyname>").unwrap();
    let res_re = Regex::new(
        r"<resolution>\s*<width>\s*(\d+)\s*</width>\s*<height>\s*(\d+)\s*</height>\s*<refresh_rate>\s*(\d+)\s*</refresh_rate>\s*</resolution>",
    )
    .unwrap();
    let global_re = Regex::new(r"(?ms)^[ \t]*<global>(.*?)</global>").unwrap();
    let rate_re = Regex::new(r"<g_refresh_rate>\s*(\d+)\s*</g_refresh_rate>").unwrap();

    let gpu = gpu_re
        .captures(xml)
        .map(|c| xml_unescape(c[1].trim()))
        .unwrap_or_default();
    let resolutions = res_re
        .captures_iter(xml)
        .map(|c| {
            (
                c[1].parse().unwrap(),
                c[2].parse().unwrap(),
                c[3].parse().unwrap(),
            )
        })
        .collect();
    let global_rates = global_re
        .captures(xml)
        .map(|c| {
            rate_re
                .captures_iter(&c[1])
                .map(|r| r[1].parse().unwrap())
                .collect()
        })
        .unwrap_or_default();
    Settings {
        gpu,
        resolutions,
        global_rates,
    }
}

/// Does the file already make the driver offer `mode`? (Used to check the merge logic.)
#[cfg(test)]
fn offers(settings: &Settings, mode: Mode) -> bool {
    settings.resolutions.iter().any(|&(w, h, hz)| {
        w == mode.width
            && h == mode.height
            && (hz == mode.hz || settings.global_rates.contains(&mode.hz))
    })
}

/// Produce the new settings text: the render GPU, `mode` merged into the
/// resolution list (existing entries are kept), and its refresh rate in the
/// global list. Unknown elements are left alone. Idempotent.
fn render_settings(original: &str, mode: Mode, gpu_name: &str) -> Result<String> {
    if !original.contains("</vdd_settings>") {
        bail!("settings file has no <vdd_settings> root element");
    }
    let current = parse_settings(original);
    let mut xml = original.to_string();

    // monitors: exactly one (the driver treats 0 as 1 anyway).
    let count_re = Regex::new(r"(?m)(^[ \t]*<monitors>\s*<count>)\s*\d+\s*(</count>)").unwrap();
    let count_block = "<monitors>\n        <count>1</count>\n    </monitors>".to_string();
    xml = replace_or_insert(&xml, &count_re, "${1}1${2}", &count_block);

    // gpu
    if !current.gpu.eq_ignore_ascii_case(gpu_name) {
        let gpu_re =
            Regex::new(r"(?m)(^[ \t]*<gpu>\s*<friendlyname>)[^<]*(</friendlyname>)").unwrap();
        let escaped = xml_escape(gpu_name);
        let gpu_block =
            format!("<gpu>\n        <friendlyname>{escaped}</friendlyname>\n    </gpu>");
        xml = replace_or_insert(
            &xml,
            &gpu_re,
            &format!("${{1}}{}${{2}}", escaped.replace('$', "$$")),
            &gpu_block,
        );
    }

    // resolutions: append if missing
    if !current
        .resolutions
        .iter()
        .any(|&(w, h, _)| w == mode.width && h == mode.height)
    {
        let entry = format!(
            "        <resolution>\n            <width>{}</width>\n            <height>{}</height>\n            \
             <refresh_rate>{}</refresh_rate>\n        </resolution>\n    </resolutions>",
            mode.width, mode.height, mode.hz
        );
        let close_re = Regex::new(r"(?m)^[ \t]*</resolutions>").unwrap();
        if close_re.is_match(&xml) {
            xml = close_re.replacen(&xml, 1, entry.as_str()).into_owned();
        } else {
            let block = format!("<resolutions>\n{entry}");
            xml = xml.replacen(
                "</vdd_settings>",
                &format!("    {block}\n</vdd_settings>"),
                1,
            );
        }
    }

    // global refresh rates: make sure the wanted one is there
    if !current.global_rates.contains(&mode.hz) {
        let close_re = Regex::new(r"(?m)^[ \t]*</global>").unwrap();
        let rate = format!(
            "        <g_refresh_rate>{}</g_refresh_rate>\n    </global>",
            mode.hz
        );
        if close_re.is_match(&xml) {
            xml = close_re.replacen(&xml, 1, rate.as_str()).into_owned();
        } else {
            let block = format!("<global>\n{rate}");
            xml = xml.replacen(
                "</vdd_settings>",
                &format!("    {block}\n</vdd_settings>"),
                1,
            );
        }
    }
    Ok(xml)
}

fn replace_or_insert(xml: &str, re: &Regex, replacement: &str, block_if_missing: &str) -> String {
    if re.is_match(xml) {
        re.replace(xml, replacement).into_owned()
    } else {
        xml.replacen(
            "</vdd_settings>",
            &format!("    {block_if_missing}\n</vdd_settings>"),
            1,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SAMPLE: &str = r#"<?xml version='1.0' encoding='utf-8'?>
<!-- host rewrites <monitors>, <gpu>, <global> and <resolutions> -->
<vdd_settings>
    <monitors>
        <count>0</count>
    </monitors>
    <gpu>
        <friendlyname>default</friendlyname>
    </gpu>
    <global>
        <g_refresh_rate>60</g_refresh_rate>
        <g_refresh_rate>120</g_refresh_rate>
    </global>
    <resolutions>
        <resolution>
            <width>1920</width>
            <height>1080</height>
            <refresh_rate>60</refresh_rate>
        </resolution>
    </resolutions>
    <logging>
        <logging>false</logging>
    </logging>
</vdd_settings>
"#;

    fn mode() -> Mode {
        Mode {
            width: 3024,
            height: 1964,
            hz: 120,
        }
    }

    #[test]
    fn merges_mode_and_gpu_and_keeps_the_rest() {
        let out = render_settings(SAMPLE, mode(), "NVIDIA GeForce RTX 3080 Ti").unwrap();
        let parsed = parse_settings(&out);
        assert_eq!(parsed.gpu, "NVIDIA GeForce RTX 3080 Ti");
        assert_eq!(
            parsed.resolutions,
            vec![(1920, 1080, 60), (3024, 1964, 120)]
        );
        assert_eq!(parsed.global_rates, [60, 120].into_iter().collect());
        assert!(out.contains("<count>1</count>"));
        assert!(
            out.contains("<logging>false</logging>"),
            "unrelated settings survive"
        );
        assert!(out.starts_with("<?xml version='1.0' encoding='utf-8'?>\n<!-- host rewrites"));
        assert!(offers(&parsed, mode()));
        assert!(
            offers(
                &parsed,
                Mode {
                    width: 1920,
                    height: 1080,
                    hz: 120
                }
            ),
            "global rate applies"
        );
        assert!(!offers(
            &parsed,
            Mode {
                width: 2560,
                height: 1440,
                hz: 60
            }
        ));
    }

    #[test]
    fn rewriting_is_idempotent() {
        let once = render_settings(SAMPLE, mode(), "NVIDIA GeForce RTX 3080 Ti").unwrap();
        let twice = render_settings(&once, mode(), "NVIDIA GeForce RTX 3080 Ti").unwrap();
        assert_eq!(
            once, twice,
            "a second write with the same request must be a no-op"
        );
        let case = render_settings(&once, mode(), "nvidia geforce rtx 3080 ti").unwrap();
        assert_eq!(
            once, case,
            "GPU name comparison is case-insensitive like the driver's"
        );
    }

    #[test]
    fn adds_a_missing_refresh_rate() {
        let out = render_settings(
            SAMPLE,
            Mode {
                width: 3024,
                height: 1964,
                hz: 90,
            },
            "x",
        )
        .unwrap();
        let parsed = parse_settings(&out);
        assert_eq!(parsed.global_rates, [60, 90, 120].into_iter().collect());
        assert_eq!(parsed.resolutions.last(), Some(&(3024, 1964, 90)));
    }

    #[test]
    fn inserts_missing_sections() {
        let minimal = "<vdd_settings>\n</vdd_settings>\n";
        let out = render_settings(minimal, mode(), "AMD Radeon RX 7800 XT").unwrap();
        let parsed = parse_settings(&out);
        assert_eq!(parsed.gpu, "AMD Radeon RX 7800 XT");
        assert_eq!(parsed.resolutions, vec![(3024, 1964, 120)]);
        assert_eq!(parsed.global_rates, [120].into_iter().collect());
        assert!(out.contains("<count>1</count>"));
        assert!(out.trim_end().ends_with("</vdd_settings>"));
    }

    #[test]
    fn escapes_gpu_names() {
        let out = render_settings(SAMPLE, mode(), "Weird & <GPU>").unwrap();
        assert!(out.contains("<friendlyname>Weird &amp; &lt;GPU&gt;</friendlyname>"));
        assert_eq!(parse_settings(&out).gpu, "Weird & <GPU>");
    }
}

#[cfg(test)]
mod helper_tests {
    use super::*;

    #[test]
    fn action_file_holds_the_order() {
        let dir = std::env::temp_dir().join(format!("td-action-{}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        write_action(&dir, "enable 4242").unwrap();
        assert_eq!(
            fs::read_to_string(dir.join(ACTION_FILE)).unwrap(),
            "enable 4242"
        );
        write_action(&dir, "disable").unwrap();
        assert_eq!(
            fs::read_to_string(dir.join(ACTION_FILE)).unwrap(),
            "disable"
        );
        let _ = fs::remove_dir_all(dir);
    }
}
