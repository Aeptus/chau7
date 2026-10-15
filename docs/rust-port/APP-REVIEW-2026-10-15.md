# iOS and macOS application review, 2026-10-15

Review base: `99bb534bc5c514fdc873aecd021cfee0d66ba4a2` on `feat/chau7-next`
(migration PR #229). This follow-up covers the iOS companion, the Rust macOS
app, and the corresponding Swift macOS paths. It is not a production release.

## Confirmed issues corrected

| Area | Defect | Correction |
| --- | --- | --- |
| iOS input | The composer cleared text when a send was queued, before the asynchronous WebSocket result. | Keep the draft until transport completion; retain it on ambiguous failure and require acknowledgement before a manual retry. No automatic command retry. |
| iOS reconnect | Late send callbacks could resolve state belonging to a replacement connection. | Fence completions by transport generation and settle outstanding sends once on close. Release approval responses for retry on the replacement connection. |
| iOS pairing | A changed pairing could retain approvals, prompt decisions, drafts, and telemetry from the previous Mac. | Clear host-scoped state on pairing changes, after old socket callbacks settle. Ordinary reconnects retain queued intent for the same pairing. |
| iOS pending state | A canceled REST response could update a newer session; its cleanup could clear a newer fetch. | Match the fetch token, pairing, cancellation state, and connection generation before applying or clearing state. |
| iOS text output | UTF-8 scalars split between frames became replacement characters. | Retain valid incomplete suffix bytes per tab and decode only complete scalars. Inspect at most four trailing bytes. |
| iOS fallback rendering | Rich rendering could fail after output had already bypassed the text accumulator. | Keep a bounded fallback tail, switch to it on renderer unavailability, and avoid publishing text while rich rendering is healthy. |
| iOS folded rendering | The folded renderer omitted the cursor and miscounted wide graphemes. | Map cursor coordinates in the Rust fold, keep wide cells together, retain cursor padding, and draw the mapped cursor on iOS. |
| Swift URL actions | SSH URLs accepted option-shaped destinations and executed without confirmation; delayed input could follow a changed tab selection. | Validate and quote destinations, use `ssh --`, ask before executing, and queue input on the newly created tab immediately. |
| Both macOS apps | SSH URL destinations with an explicit port were passed as a hostname containing a colon. | Pass explicit ports using OpenSSH URI destination syntax. |
| Next restoration | Legacy recovery could attach secondary windows from a backup sharing no tab with the current primary window. | Require a shared stable tab identifier before recovering backup windows; continue searching older matching backups. |
| Next Git UI | Background status results could open a diff in a newly selected tab. | Capture the originating tab and pane-tree identity; discard results if that target disappears or is no longer selected, preventing hidden panes from stealing focus. |
| Next command changes | Late Git scans could attach changes to a newer command and reorder conflict state. | Carry command UUIDs and separate baseline receivers; order results by a monotonic finish sequence, including equal timestamps. |
| Both macOS apps | MCP approval context used the selected tab instead of the command target. | Carry the captured native target through forwarding, enrich the first payload, and never redirect a missing explicit target to the selection. |
| Both macOS apps | Capping protected inputs left approval contexts for discarded inputs. | Evict both records together so reconnects do not restore dead approval cards. |
| Both macOS CTO wrappers | An isolated subprocess home could make runtime lookup select the wrapper itself indefinitely; PATH aliases also bypassed string exclusions. | Identify the invoked script independently of HOME, skip file aliases, preserve PATH component semantics, and reject executable directories. Next also excludes aliases of Swift wrappers. |
| Swift test isolation | Tests removing a home override could fall back to the user's `.chau7` and CLI transcript directories. | Use the existing process-specific XCTest temporary root for all home-derived paths. Explicit overrides still take priority. |

## Build changes

- The iOS Rust script honors Xcode's `ARCHS`. A native Apple Silicon simulator
  build compiles its arm64 slice; standalone and generic universal builds retain
  both simulator slices.
- The Rust Xcode phase always asks Cargo to check its inputs. The previous
  directory timestamp dependency could miss a nested Rust source change.
- Seven mocked build-script cases cover device, arm64, Intel, universal,
  unsupported architecture, and an explicit Cargo home with a shadowed PATH.
  The iOS build resolves Cargo and Rustup from `CARGO_HOME` when set, preserving
  the installed toolchain when Xcode isolates HOME. No compiler is invoked by
  these fixtures.
- Validation reuses copies of existing build caches on the T7. Compiler jobs
  are bounded to fit this Mac's 16 GB of RAM.

The cursor fix appends fields to the local `DisplayRowBuffer` C/Swift mirror
(stride 88 bytes). Rebuild the Rust archive and iOS consumer together. This does
not change the Mac/iOS network protocol or stored restoration formats.

## Validation

| Check | Result |
| --- | --- |
| Initial Swift macOS full XCTest suite | 4,593 executed, 3 skipped, 0 failures; 87.1 seconds. |
| Initial Swift macOS build | Passed; 2.22 seconds using the populated cache. |
| SwiftFormat / strict SwiftLint | Passed across Sources and Tests; no formatting changes required in 1,123 checked files. |
| Swift CTO follow-up integration suite | 33 passed, 0 failures, including the bounded wrapper recursion regression. |
| Native Periphery analysis | Passed after rebuilding the copied index; no unused code detected. |
| iOS hostless simulator suite and app compilation | 112 passed, 0 failures, including the rerun with the corrected Cargo resolution. |
| Shared Rust terminal suite | 160 passed, 0 failures. |
| Next workspace suite | 3,166 passed, 2 ignored, 0 failures after the final Clippy corrections. |
| Strict Next Clippy, all targets; workspace formatting | Passed. |
| Next production feature suite | 3,166 passed, 2 ignored, 0 failures. |
| Quality tooling tests | 125 Node and 24 Python tests passed. |
| iOS Rust build script | Seven mocked build-script cases passed; shellcheck and project plist validation passed. |
| Terminal FFI | Generated C header matches the checked-in header byte for byte; Rust and Swift ABI layout tests pass. |
| Staged checks | Eight gates passed, including secret scanning, shared dependency pins, shellcheck and tooling tests. |

The initial full Swift suite and warm build timing precede the CTO follow-up;
that change passes its 33 focused integration tests. The publication hook also
runs the full local CI against the committed tree. The new Cargo-home fixture
fails against the earlier iOS script and passes after the fix.

Copying the native Swift ModuleCache and index store from another worktree
caused absolute-path failures and 560 erroneous unused-code findings. Those
owned generated caches were preserved separately and regenerated in this
checkout; the clean Periphery scan passes.

The optional pre-commit AI review that opens live Chau7 tabs was disabled for
this invocation to respect the running-app constraint. Independent parallel
source reviews were completed, including an Astra follow-up that found and
corrected the delayed diff focus issue.

An initial Swift run under concurrent compilation exceeded the existing 100 ms
encoding p99 threshold (131.45 ms). The focused rerun and the complete suite
passed without concurrent builds; the threshold was not relaxed. Several
existing test fixtures also assumed the real home directory or an unprefixed
Keychain service. They now exercise the same isolated paths as the code under
test, without dropping those checks.

The iOS compiler still reports skipped AppIntents metadata extraction for
targets without an AppIntents dependency. Vendored GPUI warnings and the
existing `block 0.1.6` future-compatibility warning remain visible in Rust logs.
These are not reported as corrected by this review.

Build and test logs, failure attempts, and final result bundles are retained
under the review worktree's `.aethyme/reviews/app-review-20261015/` directory.
Generated partial XCTest results were moved there from the worktree root.
No private profiles or test evidence are included in the PR.

## Limits

The user's running Chau7 and Chau7 Next are not stopped, relaunched, or replaced
for this review. Automated tests use isolated storage and the iOS simulator.
No real paired Mac, external AI provider, or physical iPhone is contacted.
Interactive macOS UI, device rendering, signing/notarization, and production
restoration migration still require the release procedure and manual acceptance
checks in [PRODUCTION-RELEASE.md](PRODUCTION-RELEASE.md).
