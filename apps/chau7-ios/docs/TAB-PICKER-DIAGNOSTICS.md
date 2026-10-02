# iPhone tab picker diagnostics — 2026-10-02

Read the connected iPhone 16 Pro's persisted diagnostics via `devicectl device copy from`, before changing the app. The retained 8,000-entry buffer spans September 2 through October 2, 2026; counts describe that retained sample, not all activity. Raw diagnostics remain local because the buffer can contain typed input.

## Findings and changes

- 442 inventory receipt events include 253 unchanged inventories. The client already canonicalizes and suppresses exact/reorder-only duplicates. Its system Menu still offered no selected-row scroll positioning, and descriptor changes could recreate menu content. Replace it with an identity-stable scrolling sheet whose presentation excludes Mac focus and input-pane fields.
- The newest 1,000 entries include 43 connection restarts and 26 background expirations. Both teardown paths emptied the observable inventory before the replacement arrived. Preserve the last-known inventory during automatic teardown; keep switching disabled while unsynchronized, and clear it on explicit disconnect, pairing change, or a real empty inventory.
- Keep the existing iPhone-selected tab independent of Mac focus. Focus it when opening the picker or when selection changes; ordinary metadata and membership refreshes must preserve browsing position.

## Follow-up improvements

The last three memory samples are 30.2, 29.3, and 36.9 MB with nominal thermal state. The last three streaming windows have zero decode/decrypt failures and zero output recoveries. Their maximum capture-to-receive times are approximately 566, 254, and 271 ms, with sender batching maxima of 523, 233, and 165 ms. This suggests examining Mac output batching before optimizing picker rendering for latency; these samples do not establish a general latency distribution.

The latest 1,000 entries contain one warning about a previous foreground exit without a background transition. That marker alone cannot identify a crash. Correlate it with a matching device crash or termination report before changing lifecycle behavior.

## Validation

Pure regression tests cover unchanged presentation, real metadata/membership changes, grouping, search, selected-tab focus, refresh scroll policy, and reconnect/pairing retention. An iOS hosting test exercises the actual SwiftUI scroll view when opening far down the list, browsing away from the selection, refreshing metadata, reconnecting, and changing selection.
