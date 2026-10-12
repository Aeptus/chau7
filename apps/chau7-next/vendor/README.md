# Locked GPUI sources

These three packages are copied byte for byte from the verified 0.3.9 registry
packages (Zed snapshot `93d745668805029476e6d7fbb19652116fed51de`).
`gpui-provenance.json` records the registry checksums and SHA256 of every original
file. Each package retains its Apache-2.0 license and copyright notice.

The workspace activates these exact versions through three Cargo path patches.
Changes remain separately reviewable; `gpui-modifications.json` records modified paths,
reasons and original/current SHA256, including upstream whitespace normalization.

The Apple package's five `vendor/gpui/src` files are shader binding inputs used
by its build script. They are required source, not a duplicate engine dependency.

Original sources and modifications retain their upstream license. Preserve the
license and upstream attribution in distributions containing these packages.


The Software window backend lives under `gpui-pre-macos/src/software_renderer`.
It renders the complete GPUI scene into an ordinary AppKit layer and preserves
native window input, menus and resize handling. Backend selection is immutable
before the first native window; Auto falls back on checked Metal startup failure.
The renderer translates all eight public Scene families; the locked macOS Metal path draws seven families
with eight pipeline states (paths use two; its LCD branch is unreachable).
The Software LCD atlas byte contract was originally checked against the prior
0.3.8 snapshot's
[wgpu atlas](https://github.com/zed-industries/zed/blob/279fe070bb389b79652e52065b2f001edcc0b11b/crates/gpui_wgpu/src/wgpu_atlas.rs)
and [LCD shader](https://github.com/zed-industries/zed/blob/279fe070bb389b79652e52065b2f001edcc0b11b/crates/gpui_wgpu/src/shaders_subpixel.wgsl).
No fourth engine fork or source dependency was added. macOS LCD reference scenes
use RGB coverage with neutral gamma/contrast; ordinary macOS text remains grayscale.

The byte-identical historical 0.3.8 original inventory and complete modification
ledger are preserved under `history/0.3.8/`. `gpui-rebase-0.3.8-to-0.3.9.json`
records verified input archives, old patch bytes and genuine new original hashes.
Current hash chains begin at the verified 0.3.9 originals; they never rewrite
historical chain endpoints. The Software surface adapter follows upstream
`CFRetained<CVPixelBuffer>` ownership and preserves scoped read-only plane locks.

Library/pixel tests and ordinary application acceptance are separate gates. The
pre-upgrade 2a95 native matrix remains six passes and two failures; this rebase
does not promote those failures or assert complete native acceptance.
