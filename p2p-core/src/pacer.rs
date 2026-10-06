//! Burst buffering + starvation guard.
//! The swarm is allowed to fill a window ahead of the playhead at full speed; once the window is full the download
//! drops to a ~1 KiB/s idle trickle (connections stay up, radio/CPU mostly idle) until playback drains it to the low mark.
//! If the player is ever waiting on data, the limit is lifted at once, so throttling can never stall playback.
use std::{
    num::NonZeroU32,
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering::Relaxed},
        Arc,
    },
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use librqbit::Session;

use crate::engine::Shared;

#[derive(Default)]
pub struct Pace {
    /// End offset of the last byte handed to the player (file-relative).
    pub served: AtomicU64,
    /// Unix ms when the oldest in-flight read started waiting for data; 0 = nobody is waiting.
    pub wait_since_ms: AtomicU64,
    /// Low Power Mode / thermal pressure: smaller window.
    pub low_power: AtomicBool,
}

pub fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

/// Marks "a read is waiting" for as long as it lives; cleared on completion AND on cancellation (client disconnect).
pub struct WaitGuard(Arc<Pace>);
impl WaitGuard {
    pub fn new(p: &Arc<Pace>) -> Self {
        p.wait_since_ms.store(now_ms(), Relaxed);
        Self(p.clone())
    }
}
impl Drop for WaitGuard {
    fn drop(&mut self) {
        self.0.wait_since_ms.store(0, Relaxed);
    }
}

const MIB: u64 = 1 << 20;

pub async fn run(session: Arc<Session>, shared: Arc<Shared>, id: usize) {
    let idle = NonZeroU32::new(1024);
    let mut throttled = false;
    loop {
        tokio::time::sleep(Duration::from_secs(2)).await;
        let handle = match shared.current.read() {
            Ok(g) => match g.as_ref() {
                Some(c) if c.id == id => c.handle.clone(),
                _ => break, // stream replaced or stopped
            },
            Err(_) => break,
        };
        let (high, low) = if shared.pace.low_power.load(Relaxed) { (16 * MIB, 6 * MIB) } else { (48 * MIB, 16 * MIB) };
        let ahead = handle.stats().progress_bytes.saturating_sub(shared.pace.served.load(Relaxed));
        let w = shared.pace.wait_since_ms.load(Relaxed);
        let starving = w != 0 && now_ms().saturating_sub(w) > 1500;
        let want = if starving || ahead < low { false } else if ahead > high { true } else { throttled };
        if want != throttled {
            session.ratelimits.set_download_bps(if want { idle } else { None });
            throttled = want;
        }
    }
    session.ratelimits.set_download_bps(None);
}
