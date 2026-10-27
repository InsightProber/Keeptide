# Schema V1 fixture

This directory contains a synthetic Core Data fixture generated from the
Keeptide V1 compiled model through the production `WriteCoordinator` and
`LocalUsageStore`. It contains no clipboard history or other personal data.

Known content uses fixed UUIDs, timestamps, UTF-8/HTML/binary payloads, and one
local usage summary. The stores were closed after writing; their empty WAL and
shared-memory files are intentionally omitted because the checkpointed SQLite
files reopen independently.

SHA-256:

- `Content.sqlite`: `cdb67255030621951e1a8af71ce83c6ef1775529aafdc3dae645fe9cf8e206d1`
- `Local.sqlite`: `cc87eb000abbc93bda688f4e13cc9d6558f6698e655f624bbf78c33ead49819d`
