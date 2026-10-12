# Locked GPUI sources

These three packages are copied byte for byte from the locked 0.3.8 registry
packages (Zed snapshot `279fe070bb389b79652e52065b2f001edcc0b11b`).
`gpui-provenance.json` records the registry checksums and SHA256 of every original
file. Each package retains its Apache-2.0 license and copyright notice.

The copies are not activated until the explicit Cargo patch checkpoint. Changes
remain separately reviewable; `gpui-modifications.json` records modified paths,
reasons and original/current SHA256, including upstream whitespace normalization.

The Apple package's five `vendor/gpui/src` files are shader binding inputs used
by its build script. They are required source, not a duplicate engine dependency.

Original sources and modifications retain their upstream license. Preserve the
license and upstream attribution in distributions containing these packages.
