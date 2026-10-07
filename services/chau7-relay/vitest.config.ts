import { generateKeyPairSync, randomBytes } from 'node:crypto';
import { cloudflareTest } from '@cloudflare/vitest-plugin';
import { defineConfig } from 'vitest/config';

// Ephemeral fixture keys: no production credentials or external APNs requests.
const fixture = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: './wrangler.toml' },
      miniflare: {
        bindings: {
          RELAY_AUTH_KEYS: JSON.stringify({
            current: { id: 'runtime-key', secret: randomBytes(32).toString('base64url') }
          }),
          APNS_TEAM_ID: 'TEST_TEAM',
          APNS_KEY_ID: 'TEST_KEY',
          APNS_PRIVATE_KEY: fixture.privateKey.export({ type: 'pkcs8', format: 'pem' }).toString(),
          TEST_APNS_PUBLIC_KEY: fixture.publicKey.export({ type: 'spki', format: 'pem' }).toString()
        }
      }
    })
  ],
  test: { include: ['test/integration/**/*.test.ts'], fileParallelism: false, testTimeout: 15000 }
});
