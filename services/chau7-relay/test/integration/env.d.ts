import '@cloudflare/vitest-plugin/types';

declare global {
  namespace Cloudflare {
    interface Env {
      SESSION: DurableObjectNamespace;
      APNS_TOKEN_BROKER: DurableObjectNamespace;
      RELAY_SECRET: string;
      APNS_TEAM_ID: string;
      APNS_KEY_ID: string;
      APNS_PRIVATE_KEY: string;
      TEST_APNS_PUBLIC_KEY: string;
    }
  }
}
