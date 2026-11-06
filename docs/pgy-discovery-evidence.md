# Pgy local member discovery

RouteBar uses a private local interface observed in an arm64 Pgy Visitor client. This is not a vendor-supported public API; compatibility may change with client updates.

## Protocol

- Connect to loopback port `16604` and send HTTP POST requests to `/rpccall`.
- The envelope contains `type`, `channel`, and `body`, with percent-encoded JSON. Responses are percent-decoded.
- Request the service catalog with type `0` and channel `-1`.
- Resolve `VPNClientRpcService` and `GetGrpMbrs` by name from the catalog, rather than hardcoding service or action IDs.
- Invoke `GetGrpMbrs` with an empty dictionary. Relevant member fields are `id`, `name`, `ip_address`, `is_online`, and `hide`.
- Infer local identity only when exactly one member IP matches a current point-to-point `utun` address. Exclude the local member from selectable peers.

## Scope and failure behavior

The implementation opens a separate bounded read connection. It does not subscribe to events or send setters, credentials, login, disconnect, restart, or route commands. No cloud API or credential files are used. Raw responses are not persisted.

Queries are limited to 3 seconds and 2 MiB. Invalid responses show an error and preserve saved nodes. Newly discovered members start unchecked; member address changes clear selection. Route previews suspend automatic merging of saved drafts.

Source: [`PgyDiscovery.swift`](../Sources/RouteBarCore/PgyDiscovery.swift). Protocol parsing and node merging are covered by synthetic fixtures in [`PgyDiscoveryTests.swift`](../Tests/RouteBarCoreTests/PgyDiscoveryTests.swift).
