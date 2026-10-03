import test from "node:test";
import assert from "node:assert/strict";
import { sharedSwiftLockPaths, sharedSwiftPinFailures } from "../shared-swift-pins.mjs";
test("shared pins validate revision and version while allowing platform-only dependencies", () => {
  const pin = (identity, revision, version = "1.3.1") => ({ identity, state: { revision, version } });
  let locks = [{ pins: [pin("swift-atomics", "same")] }, { pins: [pin("swift-atomics", "same"), pin("ios-only", "other")] }];
  const read = (file) => JSON.stringify(locks[sharedSwiftLockPaths.indexOf(file)]);
  assert.deepEqual(sharedSwiftPinFailures(read), []);
  locks[1].pins[0].state.revision = "drift"; assert.equal(sharedSwiftPinFailures(read).length, 1);
  locks[1].pins[0] = pin("swift-atomics", "same", "1.3.0"); assert.equal(sharedSwiftPinFailures(read).length, 1);
  assert.equal(sharedSwiftPinFailures(() => "invalid").length, 1);
});
