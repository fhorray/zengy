# ADR-003: Capability and Provider Resolution

- **Status:** Accepted
- **Date:** 2026-11-23

## Decision
- Services are identified by semantic capability IDs with major version suffix (e.g., `engine.log/1`, `engine.graphics.device/1`).
- `ServiceRegistry` enforces explicit exclusivity policies (`exclusive: bool`).
- If multiple providers register an exclusive capability without explicit selection, resolution fails deterministically with `AmbiguousProvider`.
- Missing required capabilities fail with `ProviderNotFound`; incompatible majors fail with `VersionMismatch`.
- Cyclic dependencies fail with `DependencyCycle`.
