//! Software scene renderer for ordinary AppKit windows. Source is assembled in
//! reviewable stages; platform selection stays Metal until all contracts and
//! native fixtures are connected.
pub mod atlas;
pub mod fills;

pub mod canvas;
pub mod paths;
pub mod presentation;
pub mod primitives;
pub mod scene;
pub mod sprites;
pub mod surfaces;
