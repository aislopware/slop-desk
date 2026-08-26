//! The resident models — one screen per live pane, keyed by pane id.
//!
//! [`Verb::Feed`](crate::protocol::Verb::Feed) is stateful because the alternative is quadratic:
//! the detection scanner sees a pane's bytes as they arrive, and re-parsing the whole ring on every
//! chunk is what the Swift original did. A resident model turns that into one pass per chunk.
//!
//! Bounded by construction: at most [`MAX_PANES`] models, the least-recently-touched evicted when a
//! new pane arrives at the cap. Eviction is not a failure — the next `feed` for an evicted pane
//! rebuilds from a blank grid, which is exactly what a full-screen app's next repaint fixes (the
//! same "starting mid-stream is expected" property the model documents).

use std::collections::HashMap;

use crate::detect::PaneDetect;
use crate::model::ScreenModel;

/// The most resident models screend keeps. A pane costs `rows × cols` cells; 256 panes at 80×24 is
/// a few MiB, and no host has ever had that many live at once.
pub const MAX_PANES: usize = 256;

/// A resident model, its detection trackers, and the tick it was last touched on (the eviction
/// order).
#[derive(Debug)]
struct Resident {
    model: ScreenModel,
    detect: PaneDetect,
    touched: u64,
}

/// The pane→model map. Not thread-safe by itself — the server wraps it in one mutex, which is
/// enough: a `feed` is microseconds and panes are independent, so the lock is never the bottleneck.
#[derive(Debug, Default)]
pub struct Registry {
    panes: HashMap<String, Resident>,
    tick: u64,
}

impl Registry {
    /// An empty registry.
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    /// How many models are resident.
    #[must_use]
    pub fn len(&self) -> usize {
        self.panes.len()
    }

    /// Whether nothing is resident.
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.panes.is_empty()
    }

    /// The model for `pane`, rebuilt first when `reset` is asked for or when the requested geometry
    /// differs from the resident one (a VT model cannot be reflowed — a resize IS a new model).
    pub fn model_mut(&mut self, pane: &str, rows: usize, cols: usize, reset: bool) -> &mut ScreenModel {
        &mut self.resident_mut(pane, rows, cols, reset).model
    }

    /// The model AND the detection trackers together, which is what one `Detect` needs.
    ///
    /// ⚠️ A grid reset deliberately does NOT reset the trackers. The OSC title survives a resize
    /// because the agent that emitted it is still running, and the sync-frame parser survives
    /// because the stream it is reading did not restart — only a REBUILD replay restarts that, and
    /// only the caller knows which it is sending.
    pub fn detect_mut(
        &mut self,
        pane: &str,
        rows: usize,
        cols: usize,
        reset: bool,
    ) -> (&mut ScreenModel, &mut PaneDetect) {
        let resident = self.resident_mut(pane, rows, cols, reset);
        (&mut resident.model, &mut resident.detect)
    }

    fn resident_mut(&mut self, pane: &str, rows: usize, cols: usize, reset: bool) -> &mut Resident {
        self.tick += 1;
        let tick = self.tick;
        if !self.panes.contains_key(pane) {
            self.evict_if_full();
        }
        let resident = self.panes.entry(pane.to_owned()).or_insert_with(|| {
            Resident {
                model: ScreenModel::new(rows, cols),
                detect: PaneDetect::default(),
                touched: tick,
            }
        });
        resident.touched = tick;
        if reset || resident.model.rows() != rows || resident.model.cols() != cols {
            resident.model = ScreenModel::new(rows, cols);
        }
        resident
    }

    /// Drops `pane`'s model. Returns whether one was resident.
    pub fn forget(&mut self, pane: &str) -> bool {
        self.panes.remove(pane).is_some()
    }

    fn evict_if_full(&mut self) {
        while self.panes.len() >= MAX_PANES {
            let Some(oldest) = self
                .panes
                .iter()
                .min_by_key(|(_, resident)| resident.touched)
                .map(|(key, _)| key.clone())
            else {
                return;
            };
            self.panes.remove(&oldest);
        }
    }
}

#[cfg(test)]
mod tests {
    #![expect(
        clippy::indexing_slicing,
        reason = "a panic in a test is the failure report, not a fault"
    )]

    use super::{MAX_PANES, Registry};

    #[test]
    fn a_pane_keeps_its_screen_across_feeds() {
        let mut registry = Registry::new();
        registry.model_mut("a", 4, 10, false).feed(b"hi");
        registry.model_mut("a", 4, 10, false).feed(b" there");
        assert_eq!(
            registry.model_mut("a", 4, 10, false).snapshot().lines[0],
            "hi there"
        );
    }

    #[test]
    fn a_resize_and_a_reset_both_rebuild() {
        let mut registry = Registry::new();
        registry.model_mut("a", 4, 10, false).feed(b"hi");
        assert_eq!(
            registry.model_mut("a", 6, 20, false).snapshot().lines[0],
            "",
            "resize rebuilds"
        );
        registry.model_mut("a", 6, 20, false).feed(b"hi");
        assert_eq!(
            registry.model_mut("a", 6, 20, true).snapshot().lines[0],
            "",
            "reset rebuilds"
        );
    }

    #[test]
    fn the_registry_is_bounded_and_evicts_the_coldest() {
        let mut registry = Registry::new();
        for i in 0..MAX_PANES {
            registry.model_mut(&format!("pane-{i}"), 4, 10, false).feed(b"x");
        }
        // Touch pane-0 so pane-1 becomes the coldest, then overflow by one.
        registry.model_mut("pane-0", 4, 10, false).feed(b"");
        registry.model_mut("overflow", 4, 10, false).feed(b"x");
        assert_eq!(registry.len(), MAX_PANES);
        assert!(registry.forget("pane-0"), "the touched pane survived");
        assert!(!registry.forget("pane-1"), "the coldest pane was evicted");
    }
}
