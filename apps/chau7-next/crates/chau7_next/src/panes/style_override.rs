//! Per-pane colors for the gpui-kit code editor.
//!
//! The styled `Editor` component projects the global gpui-kit theme onto its
//! state every frame. The panes need their own colors (the editor theme
//! setting, the terminal background), so this wrapper element lays the
//! editor out, then replaces the projected style before anything is painted.

use gpui::{
    AnyElement, App, Bounds, Element, ElementId, Entity, GlobalElementId, InspectorElementId,
    IntoElement, LayoutId, Pixels, Window,
};
use gpui_kit::base::input::{EditorState, InputEditorStyle};

pub struct StyleOverride {
    child: AnyElement,
    state: Entity<EditorState>,
    style: InputEditorStyle,
}

/// Paint `child` (an editor built on `state`) with `style`.
pub fn with_style(
    child: impl IntoElement,
    state: &Entity<EditorState>,
    style: InputEditorStyle,
) -> StyleOverride {
    StyleOverride {
        child: child.into_any_element(),
        state: state.clone(),
        style,
    }
}

impl IntoElement for StyleOverride {
    type Element = Self;

    fn into_element(self) -> Self::Element {
        self
    }
}

impl Element for StyleOverride {
    type RequestLayoutState = ();
    type PrepaintState = ();

    fn id(&self) -> Option<ElementId> {
        None
    }

    fn source_location(&self) -> Option<&'static std::panic::Location<'static>> {
        None
    }

    fn request_layout(
        &mut self,
        _: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        window: &mut Window,
        cx: &mut App,
    ) -> (LayoutId, ()) {
        // Laying the child out renders the editor, which projects the theme.
        let layout = self.child.request_layout(window, cx);
        let style = self.style.clone();
        self.state
            .update(cx, |state, _| state.set_editor_style(style));
        (layout, ())
    }

    fn prepaint(
        &mut self,
        _: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        _: Bounds<Pixels>,
        _: &mut (),
        window: &mut Window,
        cx: &mut App,
    ) {
        self.child.prepaint(window, cx);
    }

    fn paint(
        &mut self,
        _: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        _: Bounds<Pixels>,
        _: &mut (),
        _: &mut (),
        window: &mut Window,
        cx: &mut App,
    ) {
        self.child.paint(window, cx);
    }
}
