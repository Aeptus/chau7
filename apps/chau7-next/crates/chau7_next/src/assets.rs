//! Icons bundled into the binary: the GPUI Kit component set (find bar, side
//! pane headers) plus the few extra Lucide icons Chau7 Next draws itself
//! (command palette rows). Only the listed icons are embedded, not the whole
//! Lucide catalog.

use std::borrow::Cow;

use gpui::{AssetSource, Result, SharedString};
use gpui_kit::assets::icon_assets;

icon_assets!(pub ExtraIcons, [
    AppWindow,
    ArrowDownToLine,
    ArrowLeftToLine,
    ArrowRightToLine,
    ArrowUpToLine,
    Book,
    BrushCleaning,
    ChartColumn,
    CircleArrowDown,
    CircleArrowUp,
    ClipboardCopy,
    ClipboardList,
    ClipboardPaste,
    Clock,
    ClockArrowUp,
    Columns2,
    CopyX,
    Eraser,
    FileCog,
    Import,
    Keyboard,
    Layers,
    ListChecks,
    ListEnd,
    ListPlus,
    Maximize2,
    MessageSquareWarning,
    Pencil,
    Printer,
    RadioTower,
    RefreshCcw,
    Rows2,
    ScanSearch,
    Scissors,
    ScrollText,
    Server,
    Share,
    SquareArrowLeft,
    SquareArrowRight,
    SquarePlus,
    SquareX,
    Terminal,
    TextCursorInput,
    TextSearch,
    X,
    ZoomIn,
    ZoomOut,
]);

/// The asset source of the app: GPUI Kit's default icons, then ours.
pub struct AppAssets;

impl AssetSource for AppAssets {
    fn load(&self, path: &str) -> Result<Option<Cow<'static, [u8]>>> {
        if let Ok(Some(data)) = ExtraIcons.load(path) {
            return Ok(Some(data));
        }
        gpui_kit::assets::Assets.load(path)
    }

    fn list(&self, path: &str) -> Result<Vec<SharedString>> {
        let mut all = gpui_kit::assets::Assets.list(path).unwrap_or_default();
        all.extend(ExtraIcons.list(path).unwrap_or_default());
        all.sort();
        all.dedup();
        Ok(all)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extra_and_default_icons_load() {
        let extra = gpui_kit::assets::IconName::Scissors.path();
        assert!(AppAssets.load(&extra).unwrap().is_some());
        let default = gpui_kit::assets::IconName::Search.path();
        assert!(AppAssets.load(&default).unwrap().is_some());
    }
}
