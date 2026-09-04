# Changelog

---

## [0.2.0] — 2026-09-02

### Added

- Internal cluster authentication with a shared keyfile (`--keyFile`)
- Four purpose-scoped users with least-privilege roles: `admin`, `app_user`, `monitoring`, `backup_user`
- TLS encryption in `requireTLS` mode with a project-local certificate authority
- Per-node X.509 certificates with SAN entries
- `.env` / `.env.example` pattern for credential handling
- `Makefile` as the single entry point for lab operations
- ADR 0002 (keyfile vs. X.509) and ADR 0003 (user and role design)
- Runbooks: credential rotation, adding a replica set node
- Reference guide: MongoDB security

### Changed

- Client connections now require TLS and credentials
- All `mongosh` invocations in the documentation updated accordingly

### Known limitations

- `root` role used instead of separating `userAdminAnyDatabase` from `clusterAdmin`
- Keyfile cannot be rotated per node; requires a coordinated restart
- CA private key stored alongside the certificates it signs
- Node certificates share `localhost` and `127.0.0.1` SAN entries, weakening per-node identity
- No certificate renewal automation; certificates expire in 825 days

---

## [0.1.0] — 2026-08-17

### Added

- Three-node MongoDB replica set defined in Docker Compose
- Named volumes for data persistence
- Dedicated Docker network with DNS resolution between nodes
- ADR 0001 (symmetric port publishing)
- Reference guides: Git/GitHub, Docker and replication, daily routines

### Fixed

- Asymmetric port mapping caused all advertised member addresses to resolve to a single node from the host, breaking client-side failover

### Documented

- Failover under graceful shutdown: 11 ms, via `stepUpRequestSkipDryRun`
- Quorum loss behaviour: survivor demotes to secondary and refuses writes

---

## [0.0.1] — 2026-08

### Added

- Repository initialised with secret-leak protection
- `.gitignore` covering credentials, keys, certificates and local state
- `pre-commit` hooks: gitleaks, detect-private-key, YAML validation
- GitHub secret scanning and push protection enabled
- MIT license
