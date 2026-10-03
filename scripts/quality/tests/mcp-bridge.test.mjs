import test, { before, after } from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import net from "node:net";
import { spawn, spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import { setTimeout as delay } from "node:timers/promises";

const supported = process.platform === "darwin";
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), "chau7-bridge-tests-"));
const binary = path.join(temporary, "bridge");
const source = fileURLToPath(new URL("../../../tools/chau7-mcp-bridge/main.swift", import.meta.url));
before(() => {
  if (!supported) return;
  const result = spawnSync("swiftc", [source, "-o", binary], { encoding: "utf8", timeout: 30000 });
  assert.equal(result.status, 0, result.stderr);
});
after(() => fs.rmSync(temporary, { recursive: true, force: true }));

async function until(predicate, message, timeout = 6000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    if (predicate()) return;
    await delay(10);
  }
  assert.fail(message);
}
async function fixture(t, connection) {
  const socketPath = path.join(temporary, `${Math.random().toString(16).slice(2)}.sock`);
  const sockets = [];
  const server = net.createServer((socket) => {
    sockets.push(socket);
    socket.on("error", () => {});
    connection(socket, sockets.length);
  });
  await new Promise((resolve, reject) => { server.once("error", reject); server.listen(socketPath, resolve); });
  const child = spawn(binary, [], { env: { ...process.env, CHAU7_MCP_SOCKET_PATH: socketPath } });
  const output = [];
  let remaining = "";
  let stderr = "";
  let exited = false;
  child.stdout.on("data", (chunk) => {
    remaining += chunk;
    let end;
    while ((end = remaining.indexOf("\n")) !== -1) {
      output.push(JSON.parse(remaining.slice(0, end)));
      remaining = remaining.slice(end + 1);
    }
  });
  child.stderr.on("data", (chunk) => { stderr += chunk; });
  child.once("exit", () => { exited = true; });
  child.stdin.on("error", () => {});
  t.after(async () => {
    child.kill();
    for (const socket of sockets) socket.destroy();
    await new Promise((resolve) => server.close(resolve));
  });
  return { child, output, send: (json) => child.stdin.write(JSON.stringify(json) + "\n"), exited: () => exited, stderr: () => stderr };
}
function frames(socket, callback) {
  let remaining = "";
  socket.on("data", (chunk) => {
    remaining += chunk;
    let end;
    while ((end = remaining.indexOf("\n")) !== -1) {
      const frame = remaining.slice(0, end);
      remaining = remaining.slice(end + 1);
      callback(JSON.parse(frame));
    }
  });
}
const initialize = { jsonrpc: "2.0", id: 7, method: "initialize", params: { protocolVersion: "2025-06-18" } };
const initialized = { jsonrpc: "2.0", method: "notifications/initialized" };
const response = (id, result = {}) => JSON.stringify({ jsonrpc: "2.0", id, result }) + "\n";

test("reconnect restores a fragmented handshake before queued calls and preserves coalesced notifications", { skip: !supported }, async (t) => {
  const methods = [];
  let replacement;
  const f = await fixture(t, (socket, number) => {
    frames(socket, (json) => {
      methods.push([number, json.method, json.id]);
      if (json.method === "initialize") {
        if (number === 1) socket.write(response(json.id));
        else replacement = socket;
      } else if (json.id === 20) socket.destroy();
      else if (json.id === 21) socket.write(response(json.id, { ok: true }));
    });
  });
  f.send(initialize);
  await until(() => f.output.some((json) => json.id === 7), "initial handshake response missing");
  f.send(initialized);
  f.send({ jsonrpc: "2.0", id: 20, method: "tools/call" });
  await until(() => replacement, "replacement connection missing");
  f.send({ jsonrpc: "2.0", id: 21, method: "tools/call" });
  const handshake = response(7);
  replacement.write(handshake.slice(0, 9));
  await delay(100);
  assert.deepEqual(methods.filter(([number]) => number === 2), [[2, "initialize", 7]]);
  replacement.write(handshake.slice(9) + JSON.stringify({ jsonrpc: "2.0", method: "notifications/test" }) + "\n");
  await until(() => f.output.some((json) => json.id === 21), `queued call missing: ${f.stderr()}`);
  assert.deepEqual(methods.filter(([number]) => number === 2), [[2, "initialize", 7], [2, "notifications/initialized", undefined], [2, "tools/call", 21]]);
  assert.equal(f.output.filter((json) => json.id === 7).length, 1);
  assert.equal(f.output.filter((json) => json.id === 20).length, 1);
  assert.equal(f.output.find((json) => json.id === 20).error.data.automaticReplay, false);
  assert.ok(f.output.some((json) => json.method === "notifications/test"));
  assert.equal(methods.filter(([, , id]) => id === 20).length, 1);
});

test("large request survives partial sends while the peer is temporarily backpressured", { skip: !supported }, async (t) => {
  let received;
  const f = await fixture(t, (socket) => {
    socket.pause();
    setTimeout(() => socket.resume(), 250);
    frames(socket, (json) => { received = json; socket.write(response(json.id)); });
  });
  const request = { jsonrpc: "2.0", id: "large", method: "tools/call", params: { prompt: "x".repeat(2 * 1024 * 1024) } };
  f.send(request);
  await until(() => f.output.some((json) => json.id === "large"), "large request response missing");
  assert.deepEqual(received, request);
});

test("oversized unterminated stdin is bounded and exits", { skip: !supported }, async (t) => {
  const f = await fixture(t, (socket) => socket.resume());
  f.child.stdin.write("x".repeat(9 * 1024 * 1024));
  await until(f.exited, "oversized frame did not terminate bridge");
  assert.ok(f.output.some((json) => json.error?.data?.errorClass === "transport_interrupted"));
});
