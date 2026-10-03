# Chau7 MCP bridge

The standalone Swift executable connects stdio to `~/.chau7/mcp.sock`. Its main
loop owns the socket; a bounded stdin queue buffers at most 64 frames / 16 MiB.
Individual frames are limited to 8 MiB, socket writes to five seconds, and a
restored handshake to ten seconds. Connection retries expire after 30 seconds.

A reconnect restores the saved initialize response and initialized notification
before dispatching buffered calls. Requests already sent on an interrupted
connection return JSON-RPC errors with their original IDs and
`data.errorClass = transport_interrupted`. They never replay automatically:
execution may already have happened, so clients must review before retrying.

`CHAU7_MCP_SOCKET_PATH` selects an isolated socket for tests or isolated runtime
profiles. Normal clients leave it unset. Tests compile only this bridge and use
fake Unix servers; they never launch, replace or restart Chau7:

```sh
node --test scripts/quality/tests/mcp-bridge.test.mjs
```

Server write deadlines include admission queue wait, and bridge connections use
nonblocking connect so a full listen backlog cannot bypass the retry deadline.
