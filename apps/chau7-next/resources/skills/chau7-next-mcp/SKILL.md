---
name: chau7-next-mcp
description: Inspect and control explicitly authorized Chau7 Next sessions through its MCP server.
---

# Chau7 Next MCP

Use the MCP server registered as chau7-next. Discover the advertised tools
and their schemas; do not substitute the Swift application's chau7 server.

Start with tab_list and inspect the stable tab ID, working directory and
agent state. Read bounded terminal output and performance information when
diagnosing a session. Request control with tab_request_control before a
mutation, use tab_wait_ready for agent readiness, and release control with
tab_release_control when finished. A denied lease or pending approval is
not permission to send input through another route.

Never send commands, close tabs or launch agents into an existing session
without authorization. Use a new, explicitly identified test session when
verification requires input. Preserve live user tabs and session state.
Report unknown or unavailable performance readings as unavailable rather
than zero. Follow event replay and snapshot requirements supplied by the
server, and retain raw event provenance when investigating hook behavior.
