# Locked GPUI sources

These three packages are copied byte for byte from the locked 0.3.8 registry
packages (Zed snapshot `279fe070bb389b79652e52065b2f001edcc0b11b`).
`gpui-provenance.json` records the registry checksums and SHA256 of every original
file. Each package retains its Apache-2.0 license and copyright notice.

This pristine checkpoint does not activate the copies or implement a software
backend. Subsequent changes must remain separately reviewable; record modified
paths and reasons in `gpui-modifications.md` when making the first source patch.

The Apple package's five `vendor/gpui/src` files are shader binding inputs used
by its build script. They are required source, not a duplicate engine dependency.

Original sources and modifications retain their upstream license. Preserve the
license and upstream attribution in distributions containing these packages.
