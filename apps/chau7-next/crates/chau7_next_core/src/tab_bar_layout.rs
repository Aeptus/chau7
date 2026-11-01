//! Tab bar layout, tab drag reorder geometry, and overlay window drop
//! resolution.
//!
//! Port of `TabBarLayout.swift`, `TabDragLayout.swift` and
//! `OverlayWindowDropResolver.swift` from
//! `apps/chau7-macos/Sources/Chau7Core`.
//!
//! Tab ids are a generic `T: Copy + Eq + Hash` (the Swift code uses `UUID`).
//! Geometry uses `f32` in place of `CGFloat`.

use std::collections::HashSet;
use std::hash::Hash;
use std::ops::Range;

// MARK: - Geometry

/// A point in the same coordinate space as [`Rect`].
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Point {
    pub x: f32,
    pub y: f32,
}

impl Point {
    pub const fn new(x: f32, y: f32) -> Self {
        Self { x, y }
    }
}

/// Minimal stand-in for `CGRect`.
#[derive(Debug, Clone, Copy, PartialEq, Default)]
pub struct Rect {
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
}

impl Rect {
    /// Equivalent of `CGRect.zero`.
    pub const ZERO: Rect = Rect {
        x: 0.0,
        y: 0.0,
        width: 0.0,
        height: 0.0,
    };

    pub const fn new(x: f32, y: f32, width: f32, height: f32) -> Self {
        Self {
            x,
            y,
            width,
            height,
        }
    }

    pub fn min_x(&self) -> f32 {
        self.x.min(self.x + self.width)
    }

    pub fn max_x(&self) -> f32 {
        self.x.max(self.x + self.width)
    }

    pub fn min_y(&self) -> f32 {
        self.y.min(self.y + self.height)
    }

    pub fn max_y(&self) -> f32 {
        self.y.max(self.y + self.height)
    }

    /// Matches `CGRect.isEmpty`: true when width or height is zero (or the
    /// rect has NaN components, the closest analogue of `CGRect.null`).
    pub fn is_empty(&self) -> bool {
        self.width == 0.0
            || self.height == 0.0
            || self.x.is_nan()
            || self.y.is_nan()
            || self.width.is_nan()
            || self.height.is_nan()
    }

    /// Matches `CGRect.contains(_: CGPoint)`: the rect is standardized, the
    /// min edges are inclusive and the max edges are exclusive.
    pub fn contains(&self, point: Point) -> bool {
        point.x >= self.min_x()
            && point.x < self.max_x()
            && point.y >= self.min_y()
            && point.y < self.max_y()
    }
}

// MARK: - TabBarLayout

/// Leave enough trailing room to align the last tab at the leading edge.
/// Retain at least 24 pixels of the trailing control at maximum manual scroll.
pub fn tab_bar_trailing_space(viewport_width: f32) -> f32 {
    (viewport_width - 24.0).max(8.0)
}

/// Align the selected tab's leading edge with the fixed viewport's leading edge.
/// Both ranges must come from the same layout and use window coordinates.
/// Scroll offsets are non-positive, as in GPUI.
pub fn scroll_offset_to_reveal_tab(
    current_offset: f32,
    max_offset: f32,
    tab: Range<f32>,
    viewport: Range<f32>,
) -> f32 {
    let max_offset = max_offset.max(0.0);
    let current_offset = current_offset.clamp(-max_offset, 0.0);
    if tab.is_empty() || viewport.is_empty() {
        return current_offset;
    }
    (current_offset - (tab.start - viewport.start)).clamp(-max_offset, 0.0)
}

/// A tab as seen by the tab bar layout.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TabBarLayoutTab<T> {
    pub id: T,
    pub repo_group_id: Option<String>,
    pub group_identity: Option<String>,
}

impl<T> TabBarLayoutTab<T> {
    /// `group_identity` defaults to `repo_group_id` when `None`, as in Swift.
    pub fn new(id: T, repo_group_id: Option<String>, group_identity: Option<String>) -> Self {
        let group_identity = group_identity.or_else(|| repo_group_id.clone());
        Self {
            id,
            repo_group_id,
            group_identity,
        }
    }
}

/// One slot in the rendered tab bar.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TabBarLayoutItem<T> {
    IdleTabs,
    RepoGroupTag {
        repo_group_id: String,
        first_tab_id: T,
    },
    Tab(T),
    NewTabButton,
}

/// Returns the tabs that are not idle, preserving order.
pub fn visible_tabs<T: Copy + Eq + Hash>(
    tabs: &[TabBarLayoutTab<T>],
    idle_tab_ids: &HashSet<T>,
) -> Vec<TabBarLayoutTab<T>> {
    if idle_tab_ids.is_empty() {
        return tabs.to_vec();
    }
    tabs.iter()
        .filter(|tab| !idle_tab_ids.contains(&tab.id))
        .cloned()
        .collect()
}

/// Builds the ordered list of tab bar items: an idle dropdown when any tab is
/// hidden, a group tag at the start of each contiguous run of the same group
/// identity, each visible tab, and the trailing new tab button.
pub fn display_items<T: Copy + Eq + Hash>(
    tabs: &[TabBarLayoutTab<T>],
    idle_tab_ids: &HashSet<T>,
) -> Vec<TabBarLayoutItem<T>> {
    let visible = visible_tabs(tabs, idle_tab_ids);
    if visible.is_empty() {
        return Vec::new();
    }

    let mut items = Vec::new();
    if visible.len() != tabs.len() {
        items.push(TabBarLayoutItem::IdleTabs);
    }

    let mut current_group_identity: Option<&str> = None;
    for tab in &visible {
        if let Some(repo_group_id) = tab.repo_group_id.as_deref() {
            let group_identity = tab.group_identity.as_deref().unwrap_or(repo_group_id);
            if Some(group_identity) != current_group_identity {
                items.push(TabBarLayoutItem::RepoGroupTag {
                    repo_group_id: repo_group_id.to_string(),
                    first_tab_id: tab.id,
                });
                current_group_identity = Some(group_identity);
            }
        } else {
            current_group_identity = None;
        }
        items.push(TabBarLayoutItem::Tab(tab.id));
    }

    items.push(TabBarLayoutItem::NewTabButton);
    items
}

/// Hit tests assuming every display item has the same width. Group tags
/// resolve to their first tab; the idle dropdown and new tab button resolve to
/// `None`.
pub fn fallback_hit_test_tab_id<T: Copy + Eq + Hash>(
    point_x: f32,
    total_width: f32,
    tabs: &[TabBarLayoutTab<T>],
    idle_tab_ids: &HashSet<T>,
) -> Option<T> {
    let items = display_items(tabs, idle_tab_ids);
    if items.is_empty() || total_width <= 0.0 {
        return None;
    }

    let item_width = total_width / items.len() as f32;
    if item_width <= 0.0 {
        return None;
    }

    // `.leastNonzeroMagnitude` is the smallest positive subnormal.
    let least_nonzero = f32::from_bits(1);
    let max_x = (total_width - least_nonzero).max(0.0);
    let clamped_x = point_x.max(0.0).min(max_x);
    let raw_index = (items.len() - 1).min((clamped_x / item_width) as usize);

    match &items[raw_index] {
        TabBarLayoutItem::IdleTabs | TabBarLayoutItem::NewTabButton => None,
        TabBarLayoutItem::Tab(id) => Some(*id),
        TabBarLayoutItem::RepoGroupTag { first_tab_id, .. } => Some(*first_tab_id),
    }
}

/// Returns a permutation of `0..group_ids.len()` that moves every entry whose
/// group equals `target_group_id` right after the first such entry (the
/// anchor), keeping everything else in place.
pub fn coalesced_order(group_ids: &[Option<&str>], target_group_id: &str) -> Vec<usize> {
    let original: Vec<usize> = (0..group_ids.len()).collect();
    let Some(anchor) = group_ids.iter().position(|id| *id == Some(target_group_id)) else {
        return original;
    };

    let moved: Vec<usize> = original
        .iter()
        .copied()
        .filter(|&i| group_ids[i] == Some(target_group_id) && i != anchor)
        .collect();
    if moved.is_empty() {
        return original;
    }

    let mut remaining: Vec<usize> = original
        .iter()
        .copied()
        .filter(|i| !moved.contains(i))
        .collect();
    let Some(insertion) = remaining.iter().position(|&i| i == anchor) else {
        return original;
    };

    remaining.splice(insertion + 1..insertion + 1, moved);
    remaining
}

// MARK: - TabDragLayout

/// Returns the destination slot a dragged tab should visually occupy.
///
/// The drag translation moves the tab's center by the same amount, so the
/// reorder threshold is the distance between tab centers, not half of only
/// the neighbor width.
///
/// Swift takes a signed `homeIndex` and returns it unchanged when out of
/// range; here the index is `usize`, so only the upper bound check remains.
pub fn destination_index(
    translation: f32,
    home_index: usize,
    tab_widths: &[f32],
    spacing: f32,
) -> usize {
    if home_index >= tab_widths.len() {
        return home_index;
    }

    let dragged_width = tab_widths[home_index];
    let mut new_index = home_index;
    let mut previous_width = dragged_width;
    let mut center_distance = 0.0_f32;

    if translation > 0.0 {
        for (index, &neighbor_width) in tab_widths.iter().enumerate().skip(home_index + 1) {
            center_distance += previous_width * 0.5 + spacing + neighbor_width * 0.5;
            if translation > center_distance {
                new_index = index;
                previous_width = neighbor_width;
            } else {
                break;
            }
        }
    } else if translation < 0.0 {
        for index in (0..home_index).rev() {
            let neighbor_width = tab_widths[index];
            center_distance += previous_width * 0.5 + spacing + neighbor_width * 0.5;
            if -translation > center_distance {
                new_index = index;
                previous_width = neighbor_width;
            } else {
                break;
            }
        }
    }

    new_index
}

// MARK: - OverlayWindowDropResolver

/// A window that a dragged tab could be dropped onto.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct OverlayWindowDropCandidate {
    pub index: usize,
    pub primary_frame: Rect,
    pub fallback_frame: Rect,
}

impl OverlayWindowDropCandidate {
    pub const fn new(index: usize, primary_frame: Rect, fallback_frame: Rect) -> Self {
        Self {
            index,
            primary_frame,
            fallback_frame,
        }
    }
}

fn drop_candidate_contains_point(candidate: &OverlayWindowDropCandidate, point: Point) -> bool {
    (!candidate.primary_frame.is_empty() && candidate.primary_frame.contains(point))
        || (!candidate.fallback_frame.is_empty() && candidate.fallback_frame.contains(point))
}

/// Resolves a drop using candidates ordered front-to-back.
///
/// The first window containing `point` is the only visible target at that
/// location. If it is the source, it blocks windows behind it and the caller
/// handles a local reorder instead. A tab bar on a covered window cannot take
/// precedence over the visible window's content.
pub fn drop_target_index(
    point: Point,
    candidates: &[OverlayWindowDropCandidate],
    source: Option<usize>,
) -> Option<usize> {
    let hit = candidates
        .iter()
        .find(|candidate| drop_candidate_contains_point(candidate, point))?;

    (Some(hit.index) != source).then_some(hit.index)
}

/// Resolves cached geometry when the platform cannot provide window z-order.
///
/// The source blocks any overlapping candidate. A cross-window target is
/// returned only when exactly one non-source candidate contains `point`.
pub fn fallback_drop_target_index(
    point: Point,
    candidates: &[OverlayWindowDropCandidate],
    source: Option<usize>,
) -> Option<usize> {
    if candidates.iter().any(|candidate| {
        Some(candidate.index) == source && drop_candidate_contains_point(candidate, point)
    }) {
        return None;
    }

    let mut targets = candidates.iter().filter(|candidate| {
        Some(candidate.index) != source && drop_candidate_contains_point(candidate, point)
    });
    let target = targets.next()?.index;
    targets.next().is_none().then_some(target)
}

#[cfg(test)]
mod tests {
    // Ported from TabBarLayoutTests.swift, TabDragLayoutTests.swift and
    // OverlayWindowDropResolverTests.swift. No tests skipped. UUIDs are
    // replaced with distinct u64 ids.
    use super::*;

    #[test]
    fn selecting_visible_tabs_aligns_the_leading_edge() {
        for (tab, expected) in [
            (100.0..180.0, -450.0),
            (310.0..490.0, -660.0),
            (520.0..600.0, -870.0),
            (100.0..600.0, -450.0),
        ] {
            assert_eq!(
                scroll_offset_to_reveal_tab(-450.0, 1200.0, tab, 100.0..600.0),
                expected
            );
        }
    }

    #[test]
    fn clipped_tabs_align_the_leading_edge() {
        for (tab, expected) in [
            (60.0..240.0, -410.0),
            (460.0..640.0, -810.0),
            (-200.0..-20.0, -150.0),
            (720.0..900.0, -1070.0),
        ] {
            assert_eq!(
                scroll_offset_to_reveal_tab(-450.0, 1200.0, tab, 100.0..600.0),
                expected
            );
        }
    }

    #[test]
    fn switching_tabs_after_a_reveal_keeps_the_selection_leftmost() {
        let viewport = 100.0..600.0;
        let mut offset = -450.0;
        // Content positions stay fixed while selection changes. Measure each
        // tab at the current scroll offset, as the rendered bar does.
        for (content, expected) in [
            (620.0..720.0, -520.0),
            (1000.0..1120.0, -900.0),
            (760.0..880.0, -660.0),
            (400.0..520.0, -300.0),
            (760.0..880.0, -660.0),
        ] {
            offset = scroll_offset_to_reveal_tab(
                offset,
                1200.0,
                content.start + offset..content.end + offset,
                viewport.clone(),
            );
            assert_eq!(offset, expected);
        }
    }

    #[test]
    fn oversized_tabs_align_left_and_do_not_oscillate() {
        for (tab, expected) in [
            (80.0..640.0, -430.0),
            (120.0..680.0, -470.0),
            (20.0..580.0, -370.0),
        ] {
            let offset = scroll_offset_to_reveal_tab(-450.0, 1200.0, tab.clone(), 100.0..600.0);
            assert_eq!(offset, expected);
            let movement = offset + 450.0;
            assert_eq!(
                scroll_offset_to_reveal_tab(
                    offset,
                    1200.0,
                    tab.start + movement..tab.end + movement,
                    100.0..600.0,
                ),
                offset
            );
        }
    }

    #[test]
    fn trailing_space_allows_the_last_tab_to_align_even_in_a_wide_viewport() {
        for width in [24.0, 180.0, 700.0] {
            for viewport_width in [80.0, 500.0, 1100.0] {
                let content_start = 1200.0;
                let current = -100.0;
                let content_end = content_start + width + 40.0; // trailing new-tab button/gap
                let max = content_end + tab_bar_trailing_space(viewport_width) - viewport_width;
                let target = scroll_offset_to_reveal_tab(
                    current,
                    max,
                    100.0 + content_start + current..100.0 + content_start + current + width,
                    100.0..100.0 + viewport_width,
                );
                assert_eq!(target, -content_start);
            }
        }
    }

    #[test]
    fn revealing_tabs_respects_scroll_limits_and_unmeasured_layout() {
        assert_eq!(
            scroll_offset_to_reveal_tab(-20.0, 600.0, 0.0..180.0, 100.0..600.0),
            0.0
        );
        assert_eq!(
            scroll_offset_to_reveal_tab(-580.0, 600.0, 500.0..680.0, 100.0..600.0),
            -600.0
        );
        assert_eq!(
            scroll_offset_to_reveal_tab(0.0, 0.0, 100.0..280.0, 100.0..600.0),
            0.0
        );
        assert_eq!(
            scroll_offset_to_reveal_tab(-450.0, 1200.0, 0.0..0.0, 100.0..600.0),
            -450.0
        );
        assert_eq!(
            scroll_offset_to_reveal_tab(-450.0, 1200.0, 100.0..280.0, 0.0..0.0),
            -450.0
        );
    }

    fn tab(id: u64, repo: Option<&str>) -> TabBarLayoutTab<u64> {
        TabBarLayoutTab::new(id, repo.map(str::to_string), None)
    }

    fn tab_with_identity(id: u64, repo: &str, identity: &str) -> TabBarLayoutTab<u64> {
        TabBarLayoutTab::new(id, Some(repo.to_string()), Some(identity.to_string()))
    }

    fn set(ids: &[u64]) -> HashSet<u64> {
        ids.iter().copied().collect()
    }

    fn tag(repo: &str, first: u64) -> TabBarLayoutItem<u64> {
        TabBarLayoutItem::RepoGroupTag {
            repo_group_id: repo.to_string(),
            first_tab_id: first,
        }
    }

    // TabBarLayoutTests

    #[test]
    fn display_items_include_idle_dropdown_and_per_run_group_tags() {
        let (first_group_tab, second_group_tab, split_group_tab, idle_tab) = (1, 2, 3, 4);
        let tabs = vec![
            tab(first_group_tab, Some("/tmp/repo-a")),
            tab(second_group_tab, Some("/tmp/repo-a")),
            tab(idle_tab, None),
            tab(split_group_tab, Some("/tmp/repo-a")),
        ];

        assert_eq!(
            display_items(&tabs, &set(&[idle_tab])),
            vec![
                TabBarLayoutItem::IdleTabs,
                tag("/tmp/repo-a", first_group_tab),
                TabBarLayoutItem::Tab(first_group_tab),
                TabBarLayoutItem::Tab(second_group_tab),
                TabBarLayoutItem::Tab(split_group_tab),
                TabBarLayoutItem::NewTabButton,
            ]
        );
    }

    #[test]
    fn display_items_split_same_repo_across_different_providers() {
        let (codex_tab, claude_tab) = (1, 2);
        let tabs = vec![
            tab_with_identity(codex_tab, "/tmp/repo-a", "/tmp/repo-a::codex"),
            tab_with_identity(claude_tab, "/tmp/repo-a", "/tmp/repo-a::claude"),
        ];

        assert_eq!(
            display_items(&tabs, &set(&[])),
            vec![
                tag("/tmp/repo-a", codex_tab),
                TabBarLayoutItem::Tab(codex_tab),
                tag("/tmp/repo-a", claude_tab),
                TabBarLayoutItem::Tab(claude_tab),
                TabBarLayoutItem::NewTabButton,
            ]
        );
    }

    #[test]
    fn fallback_hit_test_returns_first_tab_for_group_tag_slot() {
        let (grouped_tab, hidden_idle_tab) = (1, 2);
        let tabs = vec![
            tab(grouped_tab, Some("/tmp/repo-a")),
            tab(hidden_idle_tab, None),
        ];
        let idle = set(&[hidden_idle_tab]);

        assert_eq!(fallback_hit_test_tab_id(25.0, 400.0, &tabs, &idle), None);
        assert_eq!(
            fallback_hit_test_tab_id(125.0, 400.0, &tabs, &idle),
            Some(grouped_tab)
        );
        assert_eq!(
            fallback_hit_test_tab_id(225.0, 400.0, &tabs, &idle),
            Some(grouped_tab)
        );
        assert_eq!(fallback_hit_test_tab_id(375.0, 400.0, &tabs, &idle), None);
    }

    #[test]
    fn fallback_hit_test_separates_same_repo_when_provider_identity_differs() {
        let (codex_tab, claude_tab) = (1, 2);
        let tabs = vec![
            tab_with_identity(codex_tab, "/tmp/repo-a", "/tmp/repo-a::codex"),
            tab_with_identity(claude_tab, "/tmp/repo-a", "/tmp/repo-a::claude"),
        ];

        assert_eq!(
            fallback_hit_test_tab_id(125.0, 500.0, &tabs, &set(&[])),
            Some(codex_tab)
        );
        assert_eq!(
            fallback_hit_test_tab_id(325.0, 500.0, &tabs, &set(&[])),
            Some(claude_tab)
        );
    }

    #[test]
    fn coalesced_order_moves_matching_tabs_next_to_anchor() {
        let group_ids = [
            Some("/tmp/repo-a"),
            None,
            Some("/tmp/repo-a"),
            Some("/tmp/repo-b"),
            Some("/tmp/repo-a"),
        ];

        assert_eq!(
            coalesced_order(&group_ids, "/tmp/repo-a"),
            vec![0, 2, 4, 1, 3]
        );
    }

    #[test]
    fn coalesced_order_leaves_already_contiguous_group_untouched() {
        let group_ids = [
            None,
            Some("/tmp/repo-a"),
            Some("/tmp/repo-a"),
            Some("/tmp/repo-b"),
        ];

        assert_eq!(coalesced_order(&group_ids, "/tmp/repo-a"), vec![0, 1, 2, 3]);
    }

    // TabDragLayoutTests

    #[test]
    fn destination_index_waits_for_center_crossing_with_equal_widths() {
        let widths = [100.0, 100.0, 100.0];

        assert_eq!(destination_index(107.0, 0, &widths, 8.0), 0);
        assert_eq!(destination_index(109.0, 0, &widths, 8.0), 1);
    }

    #[test]
    fn destination_index_includes_dragged_width_when_moving_right() {
        let widths = [100.0, 200.0, 150.0];

        assert_eq!(destination_index(157.0, 0, &widths, 8.0), 0);
        assert_eq!(destination_index(159.0, 0, &widths, 8.0), 1);
    }

    #[test]
    fn destination_index_accumulates_center_distances_across_multiple_tabs() {
        let widths = [100.0, 200.0, 150.0];

        assert_eq!(destination_index(340.0, 0, &widths, 8.0), 1);
        assert_eq!(destination_index(342.0, 0, &widths, 8.0), 2);
    }

    #[test]
    fn destination_index_includes_dragged_width_when_moving_left() {
        let widths = [100.0, 140.0, 80.0];

        assert_eq!(destination_index(-117.0, 2, &widths, 8.0), 2);
        assert_eq!(destination_index(-119.0, 2, &widths, 8.0), 1);
        assert_eq!(destination_index(-247.0, 2, &widths, 8.0), 0);
    }

    // OverlayWindowDropResolverTests

    fn two_windows() -> Vec<OverlayWindowDropCandidate> {
        vec![
            OverlayWindowDropCandidate::new(
                0,
                Rect::new(0.0, 0.0, 100.0, 20.0),
                Rect::new(0.0, 0.0, 400.0, 300.0),
            ),
            OverlayWindowDropCandidate::new(
                1,
                Rect::new(500.0, 0.0, 100.0, 20.0),
                Rect::new(500.0, 0.0, 400.0, 300.0),
            ),
        ]
    }

    #[test]
    fn target_index_uses_frontmost_window_for_tab_bar_hits() {
        assert_eq!(
            drop_target_index(Point::new(550.0, 10.0), &two_windows(), None),
            Some(1)
        );
    }

    #[test]
    fn target_index_falls_back_to_frontmost_window_frame() {
        let candidates = [OverlayWindowDropCandidate::new(
            1,
            Rect::ZERO,
            Rect::new(500.0, 0.0, 400.0, 300.0),
        )];

        assert_eq!(
            drop_target_index(Point::new(650.0, 120.0), &candidates, None),
            Some(1)
        );
    }

    #[test]
    fn source_window_blocks_overlapping_windows_behind_it() {
        let candidates = [
            OverlayWindowDropCandidate::new(
                0,
                Rect::new(0.0, 0.0, 300.0, 24.0),
                Rect::new(0.0, 0.0, 400.0, 300.0),
            ),
            OverlayWindowDropCandidate::new(
                1,
                Rect::new(200.0, 0.0, 100.0, 24.0),
                Rect::new(200.0, 0.0, 400.0, 300.0),
            ),
        ];

        // The pointer is on the source tab bar and the covered destination
        // tab bar, but the source is frontmost and should reorder locally.
        assert_eq!(
            drop_target_index(Point::new(250.0, 10.0), &candidates, Some(0)),
            None
        );
    }

    #[test]
    fn visible_window_content_blocks_a_tab_bar_behind_it() {
        let candidates = [
            OverlayWindowDropCandidate::new(
                0,
                Rect::new(0.0, 0.0, 100.0, 24.0),
                Rect::new(0.0, 0.0, 400.0, 300.0),
            ),
            OverlayWindowDropCandidate::new(
                1,
                Rect::new(200.0, 0.0, 100.0, 24.0),
                Rect::new(200.0, 0.0, 400.0, 300.0),
            ),
        ];

        // The point is over the back window's tab bar, but inside the front
        // window's content area. The topmost window owns the drop location.
        assert_eq!(
            drop_target_index(Point::new(250.0, 10.0), &candidates, None),
            Some(0)
        );
    }

    #[test]
    fn target_index_respects_reversed_front_to_back_order() {
        let candidates = [
            OverlayWindowDropCandidate::new(
                1,
                Rect::new(200.0, 0.0, 100.0, 24.0),
                Rect::new(200.0, 0.0, 400.0, 300.0),
            ),
            OverlayWindowDropCandidate::new(
                0,
                Rect::new(0.0, 0.0, 100.0, 24.0),
                Rect::new(0.0, 0.0, 400.0, 300.0),
            ),
        ];

        // When the destination is actually frontmost, crossing into it is
        // still a valid cross-window drop.
        assert_eq!(
            drop_target_index(Point::new(250.0, 10.0), &candidates, Some(0)),
            Some(1)
        );
    }

    #[test]
    fn fallback_target_allows_one_non_source_window() {
        let candidates = [
            OverlayWindowDropCandidate::new(
                0,
                Rect::new(0.0, 0.0, 100.0, 24.0),
                Rect::new(0.0, 0.0, 400.0, 300.0),
            ),
            OverlayWindowDropCandidate::new(
                1,
                Rect::new(500.0, 0.0, 100.0, 24.0),
                Rect::new(500.0, 0.0, 400.0, 300.0),
            ),
        ];

        assert_eq!(
            fallback_drop_target_index(Point::new(550.0, 10.0), &candidates, Some(0)),
            Some(1)
        );
    }

    #[test]
    fn fallback_source_hit_blocks_overlapping_destination() {
        let candidates = [
            OverlayWindowDropCandidate::new(
                0,
                Rect::new(0.0, 0.0, 100.0, 24.0),
                Rect::new(0.0, 0.0, 400.0, 300.0),
            ),
            OverlayWindowDropCandidate::new(
                1,
                Rect::new(200.0, 0.0, 100.0, 24.0),
                Rect::new(200.0, 0.0, 400.0, 300.0),
            ),
        ];

        assert_eq!(
            fallback_drop_target_index(Point::new(250.0, 10.0), &candidates, Some(0)),
            None
        );
    }

    #[test]
    fn fallback_rejects_ambiguous_destination_windows() {
        let candidates = [
            OverlayWindowDropCandidate::new(
                0,
                Rect::new(0.0, 0.0, 100.0, 24.0),
                Rect::new(0.0, 0.0, 150.0, 150.0),
            ),
            OverlayWindowDropCandidate::new(
                1,
                Rect::new(200.0, 0.0, 100.0, 24.0),
                Rect::new(200.0, 0.0, 400.0, 300.0),
            ),
            OverlayWindowDropCandidate::new(
                2,
                Rect::new(200.0, 0.0, 100.0, 24.0),
                Rect::new(200.0, 0.0, 400.0, 300.0),
            ),
        ];

        assert_eq!(
            fallback_drop_target_index(Point::new(250.0, 10.0), &candidates, Some(0)),
            None
        );
    }

    #[test]
    fn rect_contains_matches_cgrect_edges() {
        let rect = Rect::new(10.0, 10.0, 10.0, 10.0);
        assert!(rect.contains(Point::new(10.0, 10.0)));
        assert!(!rect.contains(Point::new(20.0, 15.0)));
        assert!(!rect.contains(Point::new(15.0, 20.0)));
        assert!(Rect::new(20.0, 20.0, -10.0, -10.0).contains(Point::new(10.0, 10.0)));
        assert!(!Rect::ZERO.contains(Point::new(0.0, 0.0)));
        assert!(Rect::ZERO.is_empty());
    }
}
