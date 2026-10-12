# Chau7 Next: genuine non-Metal window backend

Status: design and acceptance plan. Implementation is in progress; this document is not validation evidence.
Application reviewed: 66753ed1c99a879881fbf7c9f65d2ec0ede59197.
Locked engine: gpui-kit 0.7.1; gpui-pre family 0.3.8, Zed snapshot 279fe070bb389b79652e52065b2f001edcc0b11b.
Local primary sources: ~/.cargo/registry/src/index.crates.io-1949cf8c6b5b557f/.

## Exact boundary

CPU-rasterize the entire GPUI window scene and present an immutable CGImage through an ordinary AppKit CALayer. In this branch do not create MTLDevice, CAMetalLayer, Metal textures/atlas, queues or commands. Retain GPUI layout/state and AppKit application, menus, window/input/IME/accessibility. This does not promise macOS WindowServer itself avoids GPU composition.

The terminal CPU bitmap already exists. It alone cannot provide startup without Metal: gpui-pre-macos creates MetalRenderer in window.rs1101; metal_renderer.rs237 exits the process without a device, while library/pipeline construction uses expect. headless is also Metal on macOS. The effective terminal renderer becomes CPU under a software window backend without changing the saved user preference. Hot GPU loss/recovery after startup is a separate scope.

## Vendoring, provenance and licenses

Copy exact locked packages into apps/chau7-next/vendor; use workspace [patch.crates-io] so every dependent resolves to the same patched types. No version refresh.

| Package 0.3.8 | Current extracted files | Current raw bytes | License |
| --- | ---: | ---: | --- |
| gpui-pre | 161 | 8327520 | Apache-2.0 |
| gpui-pre-macos | 18 | 554987 | Apache-2.0 |
| gpui-pre-apple | 16 | 966266 | Apache-2.0 |
| Total | 195 | 9848773 | |

Keep LICENSE-APACHE/copyright files. Record package version, original lock checksum, upstream revision and per-file SHA256 before changes; maintain modification manifest and distribute notices with app artifacts. Apple build.rs reads five vendor/gpui/src files through cbindgen, so retain those 680KiB of shader-binding inputs. Preserve build features and existing Metal path. Runtime fallback does not remove the existing Xcode Metal shader build requirement.

A third fork is needed: Background fields (tag, colors, interpolation, angle/pattern) are pub(crate), and only as_solid is public (gpui-pre/src/color.rs779/910). Add readonly typed BackgroundDescription accessor without changing repr(C) layout. Do not transmute private layouts or serialize colors per primitive in the hot path.

Direct Rust implementation of the current shader contract is the proposed rasterizer. Existing CoreGraphics/CoreText/CoreVideo/objc2/QuartzCore dependencies suffice for text, pixel buffers and presentation, with narrow binding features if needed. tiny-skia 0.11.4 is already locked, BSD-3-Clause, but optional: it cannot directly replace implicit curves/Oklab gradients. No new raster library/version change is required initially.

## Proposed changed paths

- apps/chau7-next/Cargo.toml and Cargo.lock: three exact patch edges only.
- vendor/gpui-pre/src/color.rs: BackgroundDescription accessor plus tests.
- vendor/gpui-pre-apple/src/metal_renderer.rs: fallible try_new/device/library/entry/pipeline/resource construction. Preserve old API for unaffected callers; macOS uses Result. No catch_unwind recovery.
- vendor/gpui-pre-macos/src/gpui_macos.rs: renderer adapter replaces Metal alias.
- vendor/gpui-pre-macos/src/platform.rs: immutable policy/context decision.
- vendor/gpui-pre-macos/src/window.rs: generic layer and existing draw/atlas/destroy/transparency/size/DPI/transaction hooks; existing AppKit input/menu/window events stay.
- New vendor/gpui-pre-macos/src/renderer/{mod,software,atlas,pixels,background,primitives,paths,surfaces,diagnostics}.rs and focused tests.
- App main.rs: platform policy before first window, preserving startup/quit/isolation order.
- App terminal/paint.rs, workspace/debug.rs, performance.rs: effective renderer plus measured window-backend diagnostics, unsupported values null.
- Existing optional native-parity-fixture dispatcher and new owned backend case; default feature unchanged.

No settings page is required for Auto fallback. Initial forced-software/injected failure controls belong only to isolated fixture code, not normal config/environment startup. No OS/provider/profile policy changes.

## Immutable selection API

Keep MacPlatform::new(headless) compatible and default Auto. Add with_renderer_policy(headless, RendererPolicy::{Auto,Software}). Shared context resolves one backend before any window atlas is exposed; all windows of that application keep that backend. Auto uses typed fallible Metal initialization and chooses Software on failure. No mid-frame atlas migration or hot switching.

Reason enum: unavailable_device, shader_library, shader_entry_or_pipeline, initial_resource. Diagnostics report requested policy, actual backend, bounded reason, CPU retained bytes and measured work. Metal remains Auto's first choice. Software GPU resources/completion are absent, not fake zero completion measurements.

## All eight primitive contracts

Follow Scene::batches order, content masks, pixel scale, premultiplied-alpha/channel conventions; checked dimensions and bounded storage. Source contract: gpui-pre/src/scene.rs and gpui-pre-apple/src/shaders.metal.

| Family | Required behavior, without skipping |
| --- | --- |
| Quads | Rounded corners, asymmetric/solid/dashed borders; solid, sRGB/Oklab gradient stops/orientation, slash/checkerboard patterns; clips and alpha. |
| Shadows | Inset/drop shadows, rounded shape, Gaussian/erf coverage, alpha and clips. |
| Paths | Triangles plus implicit quadratic coverage using st coordinates/derivatives (shader772), intermediate accumulation and single-copy transparent overlaps; holes/winding behavior. |
| Underlines | Straight/wavy coverage, thickness and current period. |
| Monochrome sprites | Actual retained glyph/SVG coverage, tint, linear sampling, transformation and transformed clipping. |
| Subpixel sprites | RGB coverage compositing/transformation/clipping. Mac Metal currently treats these unreachable, but complete software scene must handle them. |
| Polychrome sprites | Stored format/filtering, alpha/opacity, grayscale, rounded corners; terminal CPU image, emoji and all UI images. |
| Surfaces | CVPixelBuffer plane-lock RAII, current supported bi-planar Y/CbCr conversion matching surface_fragment884, strides/filtering/clips; synthetic pixel buffers in tests. |

CPU atlas stores Monochrome/Polychrome/Subpixel bytes, live unique tiles/padding and correct insert/remove via AtlasState. HeadlessAtlas is forbidden here: it discards bytes. Memory bounds return allocation errors rather than evicting still-live tiles silently. Failed frames remain observable. CGImage backing must outlive layer contents; zero size, DPI, transparency and live resize retain actual native frame callbacks and teardown.

## Actual validation without macOS/TCC changes

1. Pure synthetic pixel fixtures for all families, order/clipping, color/alpha, curves/holes/translucent overlaps, transforms, patterns/gradients, waves, shadow/border differences, YUV stride, finite/dimension guards and atlas lifetime/bounds.
2. Feature-only typed device failure BEFORE Metal calls proves Auto, not just forced Software. Separate library/pipeline/resource failure injections. Assert zero Metal-resource creation on Software branch.
3. Owned fresh profile/CWD, startup isolation guards, separate target, unique signed transient bundle using existing common runner. No existing app/profile/window/OS input-source/clipboard/provider changes or permission requests.
4. Actual AppKit/GPUI window draws chrome + terminal and routes constructed key/marked-text/menu actions to owned state; tests resize/DPI geometry, pane transfer, original-window close and clean teardown. Use existing native editor/restore patterns, no TCC automation or user input.
5. Capture software's own bitmap. Compare synthetic scenes against existing owned Metal render_to_image without desktop capture. Define per-feature pixel tolerances and record exact SHA/backend/failure reason/primitive coverage.
6. Measured CPU work/frame time/retained bytes exclude executor/timer wait. No gain claimed before measurements.
7. Default macOS/full tests/strict/fmt and existing native restore/settings/editor stay green; Linux/Windows CI validate unchanged shared-core behavior. Optional fixture never ships in normal build.

## Implementation checkpoints

The coordinator accepted the three exact forks and complete software scene implementation for the explicitly requested full parity. Scope is startup without a compatible Metal device or after initial renderer creation failure, with ordinary AppKit presentation. Whole-OS GPU independence and hot device-loss recovery are separate.

Checkpoints: pristine vendoring and provenance; typed accessor and fallible construction; complete pure rasterizer and atlas; native adapter and automatic selection; isolated failure and interaction evidence. Every intermediate checkpoint remains incomplete. No omitted primitive, terminal-only replacement, discarded atlas bytes, error-screen substitute or forced-software-only proof can close PRF-002.
