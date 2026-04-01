## Third-Party Notices

This repository contains third-party code and third-party-derived code that is shipped or maintained as part of Chau7.

### RTK / `chau7_optim`

- Derived subtree: `apps/chau7-macos/rust/chau7_optim`
- Upstream project: `rtk` by Patrick Szymkowiak
- Upstream repository: <https://github.com/rtk-ai/rtk>
- Local fork record: `apps/chau7-macos/rust/chau7_optim/UPSTREAM-SYNC.md`
- Local fork point record: RTK commit `5b59700` as recorded in the file above

Chau7 includes a modified fork of RTK in the `chau7_optim` crate. The local fork preserves the MIT license text in:

- `apps/chau7-macos/rust/chau7_optim/LICENSE-RTK`

As of 2026-04-01, RTK upstream publishes inconsistent license metadata:

- GitHub `LICENSE` file: Apache License 2.0
- `Cargo.toml` package metadata: MIT

Because Chau7 contains copied and modified RTK-derived code, this repository keeps both the preserved MIT license text from the forked subtree and a local Apache 2.0 copy as a conservative downstream notice until upstream license history is clarified.

Files kept for this purpose:

- `apps/chau7-macos/rust/chau7_optim/LICENSE-RTK`
- `apps/chau7-macos/rust/chau7_optim/LICENSE-RTK-APACHE`

No upstream `NOTICE` file was found in RTK during this review. If that changes upstream, downstream distributions of Chau7 should include any required NOTICE text alongside the license files above.

### Distribution Guidance

If you distribute Chau7 source archives, binaries, or app bundles that include `chau7_optim`, include this file and the RTK license files above in the distributed package or legal notices bundle.
