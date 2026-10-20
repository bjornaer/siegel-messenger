//! Clocks and timers that work on phones (tokio) and in the browser (M8), where std's clocks
//! panic and tokio has no timer.

use std::future::Future;
use std::time::Duration;

pub(crate) use web_time::{Instant, SystemTime, UNIX_EPOCH};

#[cfg(not(target_family = "wasm"))]
pub(crate) async fn sleep(d: Duration) {
    tokio::time::sleep(d).await
}

#[cfg(target_family = "wasm")]
pub(crate) async fn sleep(d: Duration) {
    gloo_timers::future::sleep(d).await
}

/// `f`'s output, or None when `d` passed first.
pub(crate) async fn timeout<F: Future>(d: Duration, f: F) -> Option<F::Output> {
    #[cfg(not(target_family = "wasm"))]
    return tokio::time::timeout(d, f).await.ok();
    #[cfg(target_family = "wasm")]
    {
        use futures_util::future::{Either, select};
        match select(std::pin::pin!(f), std::pin::pin!(sleep(d))).await {
            Either::Left((v, _)) => Some(v),
            Either::Right(_) => None,
        }
    }
}
