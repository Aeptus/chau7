# Locked GPUI sources

These three packages are copied byte for byte from the locked 0.3.8 registry
packages (Zed snapshot `279fe070bb389b79652e52065b2f001edcc0b11b`).
`gpui-provenance.json` records the registry checksums and SHA256 of every original
file. Each package retains its Apache-2.0 license and copyright notice.

The workspace activates these exact versions through three Cargo path patches.
Changes remain separately reviewable; `gpui-modifications.json` records modified paths,
reasons and original/current SHA256, including upstream whitespace normalization.

The Apple package's five `vendor/gpui/src` files are shader binding inputs used
by its build script. They are required source, not a duplicate engine dependency.

Original sources and modifications retain their upstream license. Preserve the
license and upstream attribution in distributions containing these packages.


The software scene renderer is a staged addition under `gpui-pre-macos/src/software_renderer`.
Its first checkpoint does not replace the selected Metal window backend. It translates
all eight public Scene families; the locked macOS Metal path draws seven families
with eight pipeline states (paths use two; its LCD branch is unreachable).
The software LCD atlas byte contract was checked against the exact snapshot's
[wgpu atlas](https://github.com/zed-industries/zed/blob/279fe070bb389b79652e52065b2f001edcc0b11b/crates/gpui_wgpu/src/wgpu_atlas.rs)
and [LCD shader](https://github.com/zed-industries/zed/blob/279fe070bb389b79652e52065b2f001edcc0b11b/crates/gpui_wgpu/src/shaders_subpixel.wgsl).
No fourth engine fork or source dependency was added. macOS LCD reference scenes
use RGB coverage with neutral gamma/contrast; ordinary macOS text remains grayscale.
