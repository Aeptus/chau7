import { env } from 'cloudflare:workers';
import { expect, it } from 'vitest';
import worker from '../../src/worker';
import { derivePhoneCredential, deriveRoleCredential } from '../../src/auth.js';
import { mintToken } from '../../src/token.js';

const root = () => JSON.parse(env.RELAY_AUTH_KEYS).current;
async function macToken(device: string, scope: string) {
  const { id, secret } = root();
  return mintToken({
    deviceId: device,
    role: 'mac',
    scope,
    keyId: id,
    secret: await deriveRoleCredential(secret, id, device, 'mac')
  });
}
async function sharedToken(device: string, scope: string) {
  const { id, secret } = root();
  return mintToken({
    deviceId: device,
    role: 'ios',
    scope,
    keyId: id,
    secret: await deriveRoleCredential(secret, id, device, 'ios')
  });
}
async function phoneToken(device: string, phoneId: string, scope: string) {
  const { id, secret } = root();
  const macSecret = await deriveRoleCredential(secret, id, device, 'mac');
  return mintToken({
    deviceId: device,
    role: 'ios',
    scope,
    keyId: id,
    phoneId,
    secret: await derivePhoneCredential(macSecret, phoneId)
  });
}
async function setPhones(device: string, phones: unknown, bearer?: string) {
  return worker.fetch(
    new Request(`https://relay.test/phones/${device}`, {
      method: 'PUT',
      headers: {
        Authorization: `Bearer ${bearer ?? (await macToken(device, 'phones'))}`,
        'Content-Type': 'application/json'
      },
      body: JSON.stringify({ phones })
    }),
    env
  );
}
async function readPending(device: string, bearer: string) {
  return worker.fetch(
    new Request(`https://relay.test/pending/${device}`, {
      headers: { Authorization: `Bearer ${bearer}` }
    }),
    env
  );
}
async function connect(device: string, bearer: string) {
  return worker.fetch(
    new Request(`https://relay.test/connect/${device}?role=ios`, {
      headers: { Authorization: `Bearer ${bearer}`, Upgrade: 'websocket' }
    }),
    env
  );
}

it('only the Mac may set the phone list', async () => {
  const device = crypto.randomUUID();
  expect((await setPhones(device, ['dA'], await sharedToken(device, 'phones'))).status).toBe(403);
  expect((await setPhones(device, ['dA'], await macToken(device, 'pending'))).status).toBe(403);
  expect((await setPhones(device, 'dA')).status).toBe(400);
  const ok = await setPhones(device, ['dA']);
  expect(await ok.json()).toEqual({ locked: false, phones: 1 });
});

it('a removed phone and the shared credential are refused after a removal', async () => {
  const device = crypto.randomUUID();
  await setPhones(device, ['dA', 'dB']);
  expect((await readPending(device, await sharedToken(device, 'pending'))).status).toBe(200);
  expect((await readPending(device, await phoneToken(device, 'dB', 'pending'))).status).toBe(200);
  expect((await readPending(device, await phoneToken(device, 'dC', 'pending'))).status).toBe(403);

  expect(await (await setPhones(device, ['dA'])).json()).toEqual({ locked: true, phones: 1 });
  expect((await readPending(device, await sharedToken(device, 'pending'))).status).toBe(403);
  expect((await readPending(device, await phoneToken(device, 'dB', 'pending'))).status).toBe(403);
  expect((await connect(device, await phoneToken(device, 'dB', 'connect'))).status).toBe(403);
  expect((await connect(device, await sharedToken(device, 'connect'))).status).toBe(403);
  expect((await readPending(device, await phoneToken(device, 'dA', 'pending'))).status).toBe(200);
});

it('removing a phone closes its open socket and leaves the others', async () => {
  const device = crypto.randomUUID();
  await setPhones(device, ['dA', 'dB']);
  const response = await connect(device, await phoneToken(device, 'dB', 'connect'));
  expect(response.status).toBe(101);
  const socket = response.webSocket!;
  socket.accept();
  const closed = new Promise<number>((resolve) =>
    socket.addEventListener('close', (event) => resolve(event.code))
  );
  await setPhones(device, ['dA']);
  expect(await closed).toBe(1008);
});

it('a pairing-window credential connects only while its window is open', async () => {
  const device = crypto.randomUUID();
  const now = Math.floor(Date.now() / 1000);
  const open = await connect(device, await phoneToken(device, `p${now + 300}`, 'connect'));
  expect(open.status).toBe(101);
  open.webSocket!.accept();
  const late = await connect(device, await phoneToken(device, `p${now - 5}`, 'connect'));
  expect(late.status).toBe(403);
});

it('consumes an acknowledgement instead of forwarding it to the Mac', async () => {
  const device = crypto.randomUUID();
  const macResponse = await worker.fetch(
    new Request(`https://relay.test/connect/${device}?role=mac`, {
      headers: {
        Authorization: `Bearer ${await macToken(device, 'connect')}`,
        Upgrade: 'websocket'
      }
    }),
    env
  );
  const mac = macResponse.webSocket!;
  mac.accept();
  const received: number[] = [];
  mac.addEventListener('message', (event) =>
    received.push(new Uint8Array(event.data as ArrayBuffer)[1])
  );
  const phone = (await connect(device, await sharedToken(device, 'connect'))).webSocket!;
  phone.accept();

  const ack = new Uint8Array(28);
  ack[1] = 0x65;
  phone.send(ack.buffer);
  const output = new Uint8Array(24);
  output[1] = 0x20;
  phone.send(output.buffer);
  await expect.poll(() => received).toContain(0x20);
  expect(received).not.toContain(0x65);
});
