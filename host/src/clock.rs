//! The host clock for TIME_REPLY and FRAME_TIMING_EXT: QueryPerformanceCounter
//! in microseconds, the same base as DXGI's `LastPresentTime` and WGC's
//! `SystemRelativeTime` (after conversion from 100 ns units). QPC never steps, unlike
//! `SystemTime`; its zero is arbitrary, so only differences mean anything.

use std::sync::OnceLock;

use windows::Win32::System::Performance::{QueryPerformanceCounter, QueryPerformanceFrequency};

/// QPC ticks per second (fixed at boot).
pub fn qpc_frequency() -> i64 {
    static FREQUENCY: OnceLock<i64> = OnceLock::new();
    *FREQUENCY.get_or_init(|| {
        let mut frequency = 0i64;
        unsafe {
            let _ = QueryPerformanceFrequency(&mut frequency);
        }
        frequency.max(1)
    })
}

pub fn qpc_now() -> i64 {
    let mut now = 0i64;
    unsafe {
        let _ = QueryPerformanceCounter(&mut now);
    }
    now
}

/// QPC ticks to microseconds. In u128: at 10 MHz, `ticks * 1_000_000`
/// overflows an i64 after about 10.7 days of uptime.
pub fn ticks_to_us(ticks: i64, frequency: i64) -> u64 {
    (ticks.max(0) as u128 * 1_000_000 / frequency.max(1) as u128) as u64
}

/// A QPC timestamp (e.g. `DXGI_OUTDUPL_FRAME_INFO::LastPresentTime`) on the
/// host clock.
pub fn qpc_to_us(ticks: i64) -> u64 {
    ticks_to_us(ticks, qpc_frequency())
}

/// Now, on the host clock.
pub fn now_us() -> u64 {
    qpc_to_us(qpc_now())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ticks_convert_without_overflow() {
        assert_eq!(ticks_to_us(0, 10_000_000), 0);
        assert_eq!(ticks_to_us(10_000_000, 10_000_000), 1_000_000);
        assert_eq!(ticks_to_us(15, 10_000_000), 1);
        assert_eq!(ticks_to_us(3_579_545, 3_579_545), 1_000_000);
        // A year of uptime at 10 MHz, past where i64 math would wrap.
        let year = 365 * 24 * 3600 * 10_000_000i64;
        assert_eq!(ticks_to_us(year, 10_000_000), 365 * 24 * 3600 * 1_000_000);
        assert_eq!(ticks_to_us(i64::MAX, 10_000_000), i64::MAX as u64 / 10);
        assert_eq!(ticks_to_us(-5, 10_000_000), 0);
    }

    #[test]
    fn now_follows_qpc_and_never_goes_back() {
        let ticks = qpc_now();
        let a = now_us();
        let b = now_us();
        assert!(a <= b);
        assert!(a >= qpc_to_us(ticks));
        std::thread::sleep(std::time::Duration::from_millis(20));
        let elapsed = now_us() - b;
        assert!((15_000..1_000_000).contains(&elapsed), "{elapsed} µs");
    }
}
