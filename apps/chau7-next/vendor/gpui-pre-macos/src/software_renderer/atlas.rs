//! Pixel-retaining CPU atlas. Each tile has its own texture and never borrows
//! another tile's storage when identifiers are retired or scene caches survive.

use anyhow::{Result, anyhow, ensure};
use gpui::{
    AtlasBackend, AtlasKey, AtlasState, AtlasTextureId, AtlasTextureKind, AtlasTile, Bounds,
    DevicePixels, PlatformAtlas, Size, TileId,
};
use parking_lot::Mutex;
use std::{borrow::Cow, collections::HashMap, sync::Arc};

const MAX_ATLAS_BYTES: usize = 512 * 1024 * 1024;
const MAX_LIVE_TILES: usize = 65_536;

/// Immutable texture bytes retained until every frame borrowing them is done.
pub struct Texture {
    pub(super) size: Size<DevicePixels>,
    pub(super) bytes: Vec<u8>,
    pub(super) kind: AtlasTextureKind,
}

impl Texture {
    /// Canonical atlas formats: Alpha8 masks, BGRA8 color images and BGRA8 LCD masks.
    pub fn channels(kind: AtlasTextureKind) -> usize {
        match kind {
            AtlasTextureKind::Monochrome => 1,
            AtlasTextureKind::Polychrome | AtlasTextureKind::Subpixel => 4,
        }
    }

    /// Bilinear texel sampling with clamped edges; position is in texel space.
    pub fn sample(&self, position: [f32; 2]) -> [f32; 4] {
        if position.iter().any(|coordinate| !coordinate.is_finite()) {
            return [0.; 4];
        }
        let x = position[0] - 0.5;
        let y = position[1] - 0.5;
        let ix = x.floor();
        let iy = y.floor();
        let tx = x - ix;
        let ty = y - iy;
        let mut out = [0.; 4];
        for (dx, dy, weight) in [
            (0., 0., (1. - tx) * (1. - ty)),
            (1., 0., tx * (1. - ty)),
            (0., 1., (1. - tx) * ty),
            (1., 1., tx * ty),
        ] {
            let px = (ix + dx).clamp(0., self.size.width.0 as f32 - 1.) as usize;
            let py = (iy + dy).clamp(0., self.size.height.0 as f32 - 1.) as usize;
            let offset = (py * self.size.width.0 as usize + px) * Self::channels(self.kind);
            let sample = match self.kind {
                AtlasTextureKind::Monochrome => [0., 0., 0., self.bytes[offset] as f32 / 255.],
                AtlasTextureKind::Polychrome => [
                    self.bytes[offset + 2] as f32 / 255.,
                    self.bytes[offset + 1] as f32 / 255.,
                    self.bytes[offset] as f32 / 255.,
                    self.bytes[offset + 3] as f32 / 255.,
                ],
                AtlasTextureKind::Subpixel => [
                    self.bytes[offset + 2] as f32 / 255.,
                    self.bytes[offset + 1] as f32 / 255.,
                    self.bytes[offset] as f32 / 255.,
                    self.bytes[offset + 3] as f32 / 255.,
                ],
            };
            for channel in 0..4 {
                out[channel] += sample[channel] * weight;
            }
        }
        out
    }
}

#[derive(Default)]
struct Pixels {
    textures: HashMap<AtlasTextureId, Arc<Texture>>,
    next_id: u32,
    retained_bytes: usize,
}

impl AtlasBackend for Pixels {
    fn insert(
        &mut self,
        kind: AtlasTextureKind,
        size: Size<DevicePixels>,
        bytes: &[u8],
    ) -> Result<AtlasTile> {
        ensure!(
            size.width.0 > 0 && size.height.0 > 0,
            "CPU atlas dimensions must be positive"
        );
        let len = (size.width.0 as usize)
            .checked_mul(size.height.0 as usize)
            .and_then(|n| n.checked_mul(Texture::channels(kind)))
            .ok_or_else(|| anyhow!("CPU atlas byte size overflow"))?;
        ensure!(bytes.len() == len, "CPU atlas source byte length mismatch");
        ensure!(
            self.textures.len() < MAX_LIVE_TILES,
            "CPU atlas live tile limit reached"
        );
        let total = self
            .retained_bytes
            .checked_add(len)
            .ok_or_else(|| anyhow!("CPU atlas byte size overflow"))?;
        ensure!(
            total <= MAX_ATLAS_BYTES,
            "CPU atlas retained byte limit reached"
        );
        let id = self
            .next_id
            .checked_add(1)
            .ok_or_else(|| anyhow!("CPU atlas identifier exhausted"))?;
        // Reserve before copying so an allocation failure does not partially
        // publish a tile or consume its identifier.
        let mut owned = Vec::new();
        owned.try_reserve_exact(len)?;
        owned.extend_from_slice(bytes);
        self.textures.try_reserve(1)?;
        let texture_id = AtlasTextureId { index: id, kind };
        self.textures.insert(
            texture_id,
            Arc::new(Texture {
                size,
                kind,
                bytes: owned,
            }),
        );
        self.next_id = id;
        self.retained_bytes = total;
        Ok(AtlasTile {
            texture_id,
            tile_id: TileId(id),
            padding: 0,
            bounds: Bounds {
                origin: Default::default(),
                size,
            },
        })
    }

    fn remove(&mut self, tile: AtlasTile) {
        if let Some(texture) = self.textures.remove(&tile.texture_id) {
            self.retained_bytes -= texture.bytes.len();
        }
    }
}

/// A real CPU atlas. HeadlessAtlas cannot be used here because it drops pixels.
#[derive(Default)]
pub struct SoftwareAtlas(Mutex<AtlasState<Pixels>>);

impl SoftwareAtlas {
    /// Retains the exact texture used by a frame, even if its key is removed.
    pub fn texture(&self, id: AtlasTextureId) -> Option<Arc<Texture>> {
        self.0.lock().backend.textures.get(&id).cloned()
    }
    /// Bytes retained by live atlas keys; a renderer separately counts any
    /// borrowed retired texture until its frame completes.
    pub fn retained_bytes(&self) -> usize {
        self.0.lock().backend.retained_bytes
    }
    /// Number of live tile allocations.
    pub fn live_tiles(&self) -> usize {
        self.0.lock().backend.textures.len()
    }
}

impl PlatformAtlas for SoftwareAtlas {
    fn get_or_insert_with<'a>(
        &self,
        key: AtlasKey,
        build: &mut dyn FnMut() -> Result<Option<(Size<DevicePixels>, Cow<'a, [u8]>)>>,
    ) -> Result<Option<AtlasTile>> {
        self.0.lock().get_or_insert_with(key, build)
    }
    fn remove(&self, key: &AtlasKey) {
        self.0.lock().remove(key);
    }
    #[cfg(any(test, feature = "test-support", feature = "bench-support"))]
    fn contains(&self, key: &AtlasKey) -> bool {
        self.0.lock().contains(key)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use gpui::{RenderSvgParams, size};
    #[test]
    fn cached_pixels_and_retired_borrows_survive_without_identifier_reuse() {
        let atlas = SoftwareAtlas::default();
        let key = AtlasKey::Svg(RenderSvgParams {
            path: "owned-mask".into(),
            size: size(DevicePixels(2), DevicePixels(1)),
        });
        let calls = std::cell::Cell::new(0);
        let mut builder = || {
            calls.set(calls.get() + 1);
            Ok(Some((
                size(DevicePixels(2), DevicePixels(1)),
                Cow::Borrowed(&[32, 224][..]),
            )))
        };
        let first = atlas
            .get_or_insert_with(key.clone(), &mut builder)
            .unwrap()
            .unwrap();
        assert_eq!(
            first,
            atlas
                .get_or_insert_with(key.clone(), &mut builder)
                .unwrap()
                .unwrap()
        );
        assert_eq!(calls.get(), 1);
        let borrowed = atlas.texture(first.texture_id).unwrap();
        assert_eq!(atlas.retained_bytes(), 2);
        atlas.remove(&key);
        assert_eq!(atlas.retained_bytes(), 0);
        assert!(atlas.texture(first.texture_id).is_none());
        assert_eq!(borrowed.bytes, vec![32, 224]);
        let second = atlas
            .get_or_insert_with(key, &mut || {
                Ok(Some((
                    size(DevicePixels(2), DevicePixels(1)),
                    Cow::Borrowed(&[1, 2][..]),
                )))
            })
            .unwrap()
            .unwrap();
        assert_ne!(first.texture_id, second.texture_id);
    }
    #[test]
    fn formats_sampling_bounds_and_failure_are_explicit() {
        let mut pixels = Pixels::default();
        let dim = Size {
            width: DevicePixels(1),
            height: DevicePixels(1),
        };
        let tile = pixels
            .insert(AtlasTextureKind::Polychrome, dim, &[64, 128, 255, 192])
            .unwrap();
        assert_eq!(
            pixels.textures[&tile.texture_id].sample([0.5, 0.5]),
            [1., 128. / 255., 64. / 255., 192. / 255.]
        );
        let lcd = pixels
            .insert(AtlasTextureKind::Subpixel, dim, &[0, 128, 255, 255])
            .unwrap();
        assert_eq!(
            pixels.textures[&lcd.texture_id].sample([-100., 100.]),
            [1., 128. / 255., 0., 1.]
        );
        let before = pixels.retained_bytes;
        assert!(
            pixels
                .insert(AtlasTextureKind::Monochrome, dim, &[])
                .is_err()
        );
        assert!(
            pixels
                .insert(
                    AtlasTextureKind::Monochrome,
                    size(DevicePixels(0), DevicePixels(1)),
                    &[]
                )
                .is_err()
        );
        assert_eq!(before, pixels.retained_bytes);
    }
}
