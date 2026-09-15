export const RELAY_RUNTIME_SCHEMA_VERSION = 1;

export function relayRuntimeInfo(versionMetadata) {
  return {
    component: 'chau7-relay',
    status: 'ok',
    runtime_schema_version: RELAY_RUNTIME_SCHEMA_VERSION,
    deployment_id: versionMetadata?.id ?? 'unknown',
    deployment_tag: versionMetadata?.tag ?? 'unknown',
    deployment_timestamp: versionMetadata?.timestamp ?? 'unknown'
  };
}
