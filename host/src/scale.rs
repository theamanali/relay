//! Windows display scale ("Scale" in Settings â†’ Display) for the virtual
//! monitor, at the value the Mac asks for in CLIENT_HELLO's `display_scale`.
//!
//! Windows keeps a per-monitor scale per user (`HKCU\Control Panel\Desktop\
//! PerMonitorSettings\<EDID id>\DpiValue`) as a number of steps away from the
//! scale it recommends for that monitor, so it survives the device node being
//! disabled between sessions. The undocumented DisplayConfigGetDeviceInfo /
//! DisplayConfigSetDeviceInfo packets -3 / -4 read and write that same
//! relative value for an active source and apply it live, without a sign-out.
//!
//! The previous value is written to `%ProgramData%\Relay` before the change
//! and put back before the virtual monitor leaves the desktop. Only the
//! session's virtual monitor is ever changed, never a physical one.

use std::fs;
use std::mem::size_of;
use std::path::PathBuf;

use anyhow::{anyhow, bail, Context, Result};
use windows::Win32::Devices::Display::{
    DisplayConfigGetDeviceInfo, DisplayConfigSetDeviceInfo, DISPLAYCONFIG_DEVICE_INFO_HEADER,
    DISPLAYCONFIG_DEVICE_INFO_TYPE,
};
use windows::Win32::Foundation::LUID;

use crate::topology;

/// The scales Windows offers, in percent. The relative values the packets use
/// are offsets in this list from the recommended scale.
pub const STEPS: [u16; 12] = [100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500];

const GET_DPI_SCALE: i32 = -3;
const SET_DPI_SCALE: i32 = -4;

/// What Windows reports for one source, in steps relative to its
/// recommended scale: `min` is always the step of 100%.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct ScaleRange {
    pub min: i32,
    pub current: i32,
    pub max: i32,
}

impl ScaleRange {
    fn recommended_index(&self) -> Option<usize> {
        usize::try_from(-self.min).ok().filter(|&i| i < STEPS.len())
    }

    /// The scale in percent for a relative value, if it is one Windows knows.
    pub fn percent(&self, relative: i32) -> Option<u16> {
        let index = self.recommended_index()? as i64 + i64::from(relative);
        usize::try_from(index)
            .ok()
            .and_then(|i| STEPS.get(i).copied())
    }

    pub fn recommended_percent(&self) -> Option<u16> {
        self.percent(0)
    }

    /// The relative value closest to `percent` that this monitor allows (a
    /// tie goes to the smaller scale).
    pub fn relative_for(&self, percent: u16) -> Result<i32> {
        let recommended = self
            .recommended_index()
            .ok_or_else(|| anyhow!("Windows reported an unknown scale range {self:?}"))?;
        let nearest = STEPS
            .iter()
            .enumerate()
            .min_by_key(|(_, &step)| step.abs_diff(percent))
            .map(|(i, _)| i)
            .unwrap_or(0);
        Ok((nearest as i32 - recommended as i32).clamp(self.min, self.max))
    }

    pub fn describe(&self) -> String {
        let show = |p: Option<u16>| p.map_or("?".to_string(), |p| format!("{p}%"));
        format!(
            "{} (recommended {}, allowed {} to {})",
            show(self.percent(self.current)),
            show(self.recommended_percent()),
            show(self.percent(self.min)),
            show(self.percent(self.max)),
        )
    }
}

/// CLIENT_HELLO's `display_scale`, checked: `None` leaves Windows' own scale.
pub fn requested(value: Option<u16>) -> Option<u16> {
    match value {
        None | Some(0) => None,
        Some(p) if (STEPS[0]..=STEPS[STEPS.len() - 1]).contains(&p) => Some(p),
        Some(p) => {
            log::warn!("ignoring display scale {p}% from the client (not 100â€“500)");
            None
        }
    }
}

#[repr(C)]
#[derive(Default)]
struct GetPacket {
    header: DISPLAYCONFIG_DEVICE_INFO_HEADER,
    min: i32,
    current: i32,
    max: i32,
}

#[repr(C)]
#[derive(Default)]
struct SetPacket {
    header: DISPLAYCONFIG_DEVICE_INFO_HEADER,
    relative: i32,
}

/// An active source, found by its GDI name or its monitor's device path.
#[derive(Clone, Debug)]
struct ActiveSource {
    adapter: LUID,
    id: u32,
    gdi_name: String,
    target_path: String,
}

fn active_sources() -> Result<Vec<ActiveSource>> {
    Ok(topology::active_sources()?
        .into_iter()
        .map(|(adapter, id, gdi_name, target_path)| ActiveSource {
            adapter,
            id,
            gdi_name,
            target_path,
        })
        .collect())
}

fn read(source: &ActiveSource) -> Result<ScaleRange> {
    let mut packet = GetPacket {
        header: DISPLAYCONFIG_DEVICE_INFO_HEADER {
            r#type: DISPLAYCONFIG_DEVICE_INFO_TYPE(GET_DPI_SCALE),
            size: size_of::<GetPacket>() as u32,
            adapterId: source.adapter,
            id: source.id,
        },
        ..Default::default()
    };
    let r = unsafe { DisplayConfigGetDeviceInfo(&mut packet.header) };
    if r != 0 {
        bail!(
            "reading the scale of {} failed with error {r}",
            source.gdi_name
        );
    }
    Ok(ScaleRange {
        min: packet.min,
        current: packet.current,
        max: packet.max,
    })
}

fn write(source: &ActiveSource, relative: i32) -> Result<()> {
    let packet = SetPacket {
        header: DISPLAYCONFIG_DEVICE_INFO_HEADER {
            r#type: DISPLAYCONFIG_DEVICE_INFO_TYPE(SET_DPI_SCALE),
            size: size_of::<SetPacket>() as u32,
            adapterId: source.adapter,
            id: source.id,
        },
        relative,
    };
    let r = unsafe { DisplayConfigSetDeviceInfo(&packet.header) };
    if r != 0 {
        bail!(
            "setting the scale of {} failed with error {r}; {}",
            source.gdi_name,
            crate::desktop::context_description()
        );
    }
    Ok(())
}

/// Set `source` to `relative` and check that Windows took it.
fn set_checked(source: &ActiveSource, relative: i32) -> Result<ScaleRange> {
    write(source, relative)?;
    let after = read(source)?;
    if after.current != relative {
        bail!(
            "{} is at {} after asking for {:?}",
            source.gdi_name,
            after.describe(),
            after.percent(relative)
        );
    }
    Ok(after)
}

fn snapshot_file() -> Result<PathBuf> {
    Ok(crate::state_dir()?.join("display-scale.txt"))
}

/// The scale a session changed, and what to put back.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Applied {
    /// The relative value before the session.
    pub previous: i32,
    /// The monitor's device path (`\\?\DISPLAY#MTT1337#...`).
    pub target_path: String,
    /// What the session asked for, for reapplying after a topology change.
    pub percent: u16,
}

impl Applied {
    fn to_text(&self) -> String {
        format!(
            "{}\n{}\n{}\n",
            self.previous, self.percent, self.target_path
        )
    }

    fn from_text(text: &str) -> Result<Self> {
        let mut lines = text.lines();
        let mut next = |what: &str| lines.next().ok_or_else(|| anyhow!("no {what}"));
        let previous = next("previous scale")?.trim().parse()?;
        let percent = next("requested scale")?.trim().parse()?;
        let target_path = next("monitor path")?.trim().to_string();
        if target_path.is_empty() {
            bail!("empty monitor path");
        }
        Ok(Applied {
            previous,
            target_path,
            percent,
        })
    }

    fn save(&self) -> Result<()> {
        let file = snapshot_file()?;
        if let Some(dir) = file.parent() {
            fs::create_dir_all(dir)?;
        }
        fs::write(&file, self.to_text()).with_context(|| format!("writing {}", file.display()))
    }

    fn load_saved() -> Result<Option<Self>> {
        let file = snapshot_file()?;
        if !file.exists() {
            return Ok(None);
        }
        let text =
            fs::read_to_string(&file).with_context(|| format!("reading {}", file.display()))?;
        Self::from_text(&text)
            .map(Some)
            .with_context(|| format!("parsing {}", file.display()))
    }

    fn clear_saved() {
        if let Ok(file) = snapshot_file() {
            let _ = fs::remove_file(file);
        }
    }

    /// Ask for the session's scale again (after the virtual-only topology was
    /// reasserted). Never touches the saved previous value.
    pub fn reapply(&self) -> Result<()> {
        crate::desktop::with_input_desktop("reapply display scale", || {
            let source = active_sources()?
                .into_iter()
                .find(|s| s.target_path == self.target_path)
                .ok_or_else(|| anyhow!("the scaled monitor is not active"))?;
            let range = read(&source)?;
            let relative = range.relative_for(self.percent)?;
            if range.current != relative {
                let after = set_checked(&source, relative)?;
                log::info!(
                    "display scale of {} reapplied: {}",
                    source.gdi_name,
                    after.describe()
                );
            }
            Ok(())
        })
    }

    /// Put the previous scale back while the monitor is still on the desktop.
    /// A monitor that is gone (a crash already removed it) cannot be set; its
    /// stale value only affects that monitor, and the next session sets it again.
    pub fn restore(self) -> Result<()> {
        crate::desktop::with_input_desktop("restore display scale", || {
            let Some(source) = active_sources()?
                .into_iter()
                .find(|s| s.target_path == self.target_path)
            else {
                log::warn!(
                    "display scale not restored: {} is no longer active",
                    self.target_path
                );
                Applied::clear_saved();
                return Ok(());
            };
            let range = read(&source)?;
            if range.current != self.previous {
                let after = set_checked(&source, self.previous)?;
                log::info!(
                    "display scale of {} restored: {}",
                    source.gdi_name,
                    after.describe()
                );
            } else {
                log::info!(
                    "display scale of {} already at its previous {}",
                    source.gdi_name,
                    range.describe()
                );
            }
            Applied::clear_saved();
            Ok(())
        })
    }
}

/// Set the monitor showing as `device_name` (`\\.\DISPLAYn`) to the step
/// nearest `percent`, after saving its current value.
pub fn apply(device_name: &str, percent: u16) -> Result<Applied> {
    crate::desktop::with_input_desktop("set display scale", || {
        let source = active_sources()?
            .into_iter()
            .find(|s| s.gdi_name.eq_ignore_ascii_case(device_name))
            .ok_or_else(|| anyhow!("{device_name} is not an active display"))?;
        let range = read(&source)?;
        let relative = range.relative_for(percent)?;
        let applied = Applied {
            previous: range.current,
            target_path: source.target_path.clone(),
            percent,
        };
        if range.current == relative {
            log::info!(
                "display scale of {device_name} already {} as asked ({percent}%)",
                range.describe()
            );
            return Ok(applied);
        }
        applied.save()?;
        match set_checked(&source, relative) {
            Ok(after) => {
                log::info!(
                    "display scale of {device_name} set to {} for {percent}%; was {}",
                    after.describe(),
                    range.describe()
                );
                Ok(applied)
            }
            Err(e) => {
                // Windows may still have taken it: try to put it back now.
                if let Err(undo) = write(&source, range.current) {
                    log::warn!("could not undo a failed scale change: {undo:#}");
                } else {
                    Applied::clear_saved();
                }
                Err(e)
            }
        }
    })
}

/// At host start, in `restore` and before a session: a scale a crashed session
/// left changed goes back if its monitor is still on the desktop.
pub fn recover_saved() {
    match Applied::load_saved() {
        Ok(Some(applied)) => {
            log::info!("restoring the display scale changed by an earlier session");
            if let Err(e) = applied.restore() {
                log::warn!("could not restore the display scale: {e:#}");
            }
        }
        Ok(None) => {}
        Err(e) => {
            log::warn!("ignoring unreadable display scale snapshot: {e:#}");
            Applied::clear_saved();
        }
    }
}

/// `display-scale` subcommand: one line per active display.
pub fn describe_all() -> Result<String> {
    let mut out = String::new();
    for source in active_sources()? {
        let line = match read(&source) {
            Ok(range) => range.describe(),
            Err(e) => format!("{e:#}"),
        };
        out.push_str(&format!(
            "{}: {line}\n    {}\n",
            source.gdi_name, source.target_path
        ));
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    // Windows' recommendation for this PC's physical monitors (100%, +3/+5
    // allowed) and one that recommends 150%.
    const AT_100: ScaleRange = ScaleRange {
        min: 0,
        current: 0,
        max: 5,
    };
    const AT_150: ScaleRange = ScaleRange {
        min: -2,
        current: 2,
        max: 6,
    };

    #[test]
    fn percent_counts_steps_from_the_recommended_scale() {
        assert_eq!(AT_100.recommended_percent(), Some(100));
        assert_eq!(AT_100.percent(1), Some(125));
        assert_eq!(AT_100.percent(5), Some(225));
        assert_eq!(AT_150.recommended_percent(), Some(150));
        assert_eq!(AT_150.percent(AT_150.current), Some(200));
        assert_eq!(AT_150.percent(-2), Some(100));
        assert_eq!(AT_150.percent(6), Some(350));
        assert_eq!(AT_150.percent(-3), None);
        assert_eq!(AT_150.percent(20), None);
    }

    #[test]
    fn relative_for_snaps_to_the_nearest_step_within_the_range() {
        assert_eq!(AT_150.relative_for(200).unwrap(), 2);
        assert_eq!(AT_150.relative_for(150).unwrap(), 0);
        assert_eq!(AT_150.relative_for(100).unwrap(), -2);
        assert_eq!(AT_150.relative_for(199).unwrap(), 2);
        // 112 is nearer 100, 113 nearer 125.
        assert_eq!(AT_100.relative_for(112).unwrap(), 0);
        assert_eq!(AT_100.relative_for(113).unwrap(), 1);
        // Halfway between 250 and 300 goes to the smaller one.
        assert_eq!(AT_150.relative_for(275).unwrap(), 4);
        // Clamped to what the monitor allows.
        assert_eq!(AT_100.relative_for(500).unwrap(), 5);
        assert_eq!(AT_150.relative_for(450).unwrap(), 6);
    }

    #[test]
    fn an_unknown_range_is_refused() {
        let odd = ScaleRange {
            min: 1,
            current: 0,
            max: 2,
        };
        assert!(odd.relative_for(200).is_err());
        assert_eq!(odd.recommended_percent(), None);
        let far = ScaleRange {
            min: -40,
            current: 0,
            max: 0,
        };
        assert!(far.relative_for(200).is_err());
    }

    #[test]
    fn requested_ignores_zero_and_out_of_range_values() {
        assert_eq!(requested(None), None);
        assert_eq!(requested(Some(0)), None);
        assert_eq!(requested(Some(99)), None);
        assert_eq!(requested(Some(501)), None);
        assert_eq!(requested(Some(100)), Some(100));
        assert_eq!(requested(Some(200)), Some(200));
        assert_eq!(requested(Some(500)), Some(500));
    }

    #[test]
    fn snapshot_text_round_trips() {
        let applied = Applied {
            previous: -1,
            target_path: r"\\?\DISPLAY#MTT1337#1&2&0&UID0#{e6f07b5f-ee97-4a90-b076-33f57bf4eaa7}"
                .to_string(),
            percent: 200,
        };
        assert_eq!(Applied::from_text(&applied.to_text()).unwrap(), applied);
        assert!(Applied::from_text("").is_err());
        assert!(Applied::from_text("x\n200\npath\n").is_err());
        assert!(Applied::from_text("0\n200\n\n").is_err());
    }
}
