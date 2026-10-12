//! Complete software scene rendering and ordinary CALayer presentation.
//! The platform selects this backend before its first native window when the
//! fixed startup policy requires it or initial Metal preparation fails.
pub mod atlas;
pub mod fills;

pub mod canvas;
pub mod paths;
pub mod presentation;
pub mod primitives;
pub mod scene;
pub mod sprites;
pub mod surfaces;
