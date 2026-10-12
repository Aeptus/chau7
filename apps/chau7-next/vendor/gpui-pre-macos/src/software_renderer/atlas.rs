//! Pixel-retaining CPU atlas using the locked Metal bucket allocator and
//! texture geometry, including bilinear sampling beyond tile boundaries.
//! Immutable frame snapshots survive atlas mutation and retirement.

use anyhow::{Result, anyhow, ensure};
use etagere::BucketedAtlasAllocator;
use gpui::{
    AtlasBackend, AtlasKey, AtlasState, AtlasTextureId, AtlasTextureKind, AtlasTile, Bounds,
    DevicePixels, PlatformAtlas, Size,
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

struct PackedTexture {
    pixels: Arc<Texture>,
    allocator: BucketedAtlasAllocator,
    live_tiles: usize,
}
#[derive(Default)]
struct Pixels {
    textures: HashMap<AtlasTextureId, PackedTexture>,
    order: Vec<AtlasTextureId>,
    next_id: u32,
    retained_bytes: usize,
    live_tiles: usize,
}
impl PackedTexture {
    fn prepare_write(&mut self) -> Result<()> {
        if Arc::get_mut(&mut self.pixels).is_none() {
            // A frame still borrows the old pixels. Reserve a fallible snapshot
            // before changing the allocator or publishing the next upload.
            let mut bytes = Vec::new();
            bytes.try_reserve_exact(self.pixels.bytes.len())?;
            bytes.extend_from_slice(&self.pixels.bytes);
            self.pixels = Arc::new(Texture {
                size: self.pixels.size,
                kind: self.pixels.kind,
                bytes,
            });
        }
        Ok(())
    }
    fn insert(
        &mut self,
        id: AtlasTextureId,
        size: Size<DevicePixels>,
        bytes: &[u8],
    ) -> Result<Option<AtlasTile>> {
        let Some(allocation) = self
            .allocator
            .allocate(etagere::size2(size.width.0, size.height.0))
        else {
            return Ok(None);
        };
        if let Err(error) = self.prepare_write() {
            self.allocator.deallocate(allocation.id);
            return Err(error);
        }
        let texture = Arc::get_mut(&mut self.pixels).expect("exclusive checked software texture");
        let channels = Texture::channels(id.kind);
        let stride = texture.size.width.0 as usize * channels;
        let source_stride = size.width.0 as usize * channels;
        let x = allocation.rectangle.min.x as usize * channels;
        let y = allocation.rectangle.min.y as usize;
        for row in 0..size.height.0 as usize {
            texture.bytes[(y + row) * stride + x..(y + row) * stride + x + source_stride]
                .copy_from_slice(&bytes[row * source_stride..(row + 1) * source_stride]);
        }
        self.live_tiles += 1;
        Ok(Some(AtlasTile {
            texture_id: id,
            tile_id: allocation.id.into(),
            padding: 0,
            bounds: Bounds {
                origin: gpui::point(
                    DevicePixels(allocation.rectangle.min.x),
                    DevicePixels(allocation.rectangle.min.y),
                ),
                size,
            },
        }))
    }
}
impl AtlasBackend for Pixels {
    fn insert(
        &mut self,
        kind: AtlasTextureKind,
        size: Size<DevicePixels>,
        bytes: &[u8],
    ) -> Result<AtlasTile> {
        ensure!(
            size.width.0 > 0
                && size.height.0 > 0
                && size.width.0 <= 16384
                && size.height.0 <= 16384,
            "CPU atlas dimensions out of range"
        );
        let len = (size.width.0 as usize)
            .checked_mul(size.height.0 as usize)
            .and_then(|n| n.checked_mul(Texture::channels(kind)))
            .ok_or_else(|| anyhow!("CPU atlas byte size overflow"))?;
        ensure!(bytes.len() == len, "CPU atlas source byte length mismatch");
        ensure!(
            self.live_tiles < MAX_LIVE_TILES,
            "CPU atlas live tile limit reached"
        );
        for id in self.order.iter().rev().filter(|id| id.kind == kind) {
            if let Some(tile) = self
                .textures
                .get_mut(id)
                .expect("ordered software texture")
                .insert(*id, size, bytes)?
            {
                self.live_tiles += 1;
                return Ok(tile);
            }
        }
        let texture_size = gpui::size(
            DevicePixels(size.width.0.max(1024)),
            DevicePixels(size.height.0.max(1024)),
        );
        let texture_len = texture_size.width.0 as usize
            * texture_size.height.0 as usize
            * Texture::channels(kind);
        let total = self
            .retained_bytes
            .checked_add(texture_len)
            .ok_or_else(|| anyhow!("CPU atlas byte size overflow"))?;
        ensure!(
            total <= MAX_ATLAS_BYTES,
            "CPU atlas retained byte limit reached"
        );
        let index = self
            .next_id
            .checked_add(1)
            .ok_or_else(|| anyhow!("CPU atlas identifier exhausted"))?;
        let mut owned = Vec::new();
        owned.try_reserve_exact(texture_len)?;
        owned.resize(texture_len, 0);
        self.textures.try_reserve(1)?;
        self.order.try_reserve(1)?;
        let id = AtlasTextureId { index, kind };
        let mut texture = PackedTexture {
            pixels: Arc::new(Texture {
                size: texture_size,
                kind,
                bytes: owned,
            }),
            allocator: BucketedAtlasAllocator::new(etagere::size2(
                texture_size.width.0,
                texture_size.height.0,
            )),
            live_tiles: 0,
        };
        let tile = texture
            .insert(id, size, bytes)?
            .ok_or_else(|| anyhow!("CPU atlas initial tile allocation failed"))?;
        self.textures.insert(id, texture);
        self.order.push(id);
        self.next_id = index;
        self.retained_bytes = total;
        self.live_tiles += 1;
        Ok(tile)
    }
    fn remove(&mut self, tile: AtlasTile) {
        let Some(texture) = self.textures.get_mut(&tile.texture_id) else {
            return;
        };
        texture.allocator.deallocate(tile.tile_id.into());
        texture.live_tiles -= 1;
        self.live_tiles -= 1;
        if texture.live_tiles == 0 {
            let texture = self
                .textures
                .remove(&tile.texture_id)
                .expect("retired software texture");
            self.retained_bytes -= texture.pixels.bytes.len();
            self.order.retain(|id| *id != tile.texture_id);
        }
    }
}

/// A real CPU atlas. HeadlessAtlas cannot be used here because it drops pixels.
#[derive(Default)]
pub struct SoftwareAtlas(Mutex<AtlasState<Pixels>>);

impl SoftwareAtlas {
    /// Retains the exact texture used by a frame, even if its key is removed.
    pub fn texture(&self, id: AtlasTextureId) -> Option<Arc<Texture>> {
        self.0
            .lock()
            .backend
            .textures
            .get(&id)
            .map(|texture| texture.pixels.clone())
    }
    /// Bytes retained by live atlas keys; a renderer separately counts any
    /// borrowed retired texture until its frame completes.
    pub fn retained_bytes(&self) -> usize {
        self.0.lock().backend.retained_bytes
    }
    /// Number of live tile allocations.
    pub fn live_tiles(&self) -> usize {
        self.0.lock().backend.live_tiles
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
        assert_eq!(atlas.retained_bytes(), 1024 * 1024);
        atlas.remove(&key);
        assert_eq!(atlas.retained_bytes(), 0);
        assert!(atlas.texture(first.texture_id).is_none());
        let offset = first.bounds.origin.y.0 as usize * 1024 + first.bounds.origin.x.0 as usize;
        assert_eq!(&borrowed.bytes[offset..offset + 2], &[32, 224]);
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
            pixels.textures[&tile.texture_id].pixels.sample([
                tile.bounds.origin.x.0 as f32 + 0.5,
                tile.bounds.origin.y.0 as f32 + 0.5
            ]),
            [1., 128. / 255., 64. / 255., 192. / 255.]
        );
        let lcd = pixels
            .insert(AtlasTextureKind::Subpixel, dim, &[0, 128, 255, 255])
            .unwrap();
        assert_eq!(
            pixels.textures[&lcd.texture_id].pixels.sample([
                lcd.bounds.origin.x.0 as f32 + 0.5,
                lcd.bounds.origin.y.0 as f32 + 0.5
            ]),
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
    #[test]
    fn packed_tiles_match_metal_filter_edges_and_keep_borrowed_snapshots_immutable() {
        let mut pixels = Pixels::default();
        let dim = size(DevicePixels(1), DevicePixels(1));
        let first = pixels
            .insert(AtlasTextureKind::Monochrome, dim, &[255])
            .unwrap();
        let borrowed = pixels.textures[&first.texture_id].pixels.clone();
        let second = pixels
            .insert(AtlasTextureKind::Monochrome, dim, &[128])
            .unwrap();
        assert_eq!(first.texture_id, second.texture_id);
        assert_ne!(first.bounds.origin, second.bounds.origin);
        assert_eq!(
            borrowed.sample([
                first.bounds.origin.x.0 as f32 + 0.5,
                first.bounds.origin.y.0 as f32 + 0.5
            ])[3],
            1.
        );
        assert_eq!(
            borrowed.sample([
                second.bounds.origin.x.0 as f32 + 0.5,
                second.bounds.origin.y.0 as f32 + 0.5
            ])[3],
            0.
        );
        let current = pixels.textures[&second.texture_id].pixels.clone();
        assert!(!Arc::ptr_eq(&borrowed, &current));
        assert_eq!(
            current.sample([
                second.bounds.origin.x.0 as f32 + 0.5,
                second.bounds.origin.y.0 as f32 + 0.5
            ])[3],
            128. / 255.
        );
        // Right/bottom edges sample the surrounding packed texture, not clamp
        // to the tile's final texel as the initial standalone atlas did.
        assert!(
            (borrowed.sample([
                first.bounds.origin.x.0 as f32 + 0.5625,
                first.bounds.origin.y.0 as f32 + 0.5625
            ])[3]
                - 0.87890625)
                .abs()
                < 1e-6
        );
        pixels.remove(first);
        assert!(pixels.textures.contains_key(&second.texture_id));
        pixels.remove(second);
        assert_eq!(pixels.retained_bytes, 0);
        assert_eq!(pixels.live_tiles, 0);
        let replacement = pixels
            .insert(AtlasTextureKind::Monochrome, dim, &[0])
            .unwrap();
        assert_ne!(replacement.texture_id, first.texture_id);
        assert_eq!(
            borrowed.sample([
                first.bounds.origin.x.0 as f32 + 0.5,
                first.bounds.origin.y.0 as f32 + 0.5
            ])[3],
            1.
        );
    }
    #[test]
    fn a_borrowed_full_texture_is_not_copied_when_another_tile_cannot_fit() {
        let mut pixels = Pixels::default();
        let full = size(DevicePixels(1024), DevicePixels(1024));
        let first = pixels
            .insert(AtlasTextureKind::Monochrome, full, &vec![1; 1024 * 1024])
            .unwrap();
        let borrowed = pixels.textures[&first.texture_id].pixels.clone();
        let second = pixels
            .insert(
                AtlasTextureKind::Monochrome,
                size(DevicePixels(1), DevicePixels(1)),
                &[2],
            )
            .unwrap();
        assert_ne!(first.texture_id, second.texture_id);
        assert!(Arc::ptr_eq(
            &borrowed,
            &pixels.textures[&first.texture_id].pixels
        ));
        assert_eq!(pixels.live_tiles, 2);
    }
}
