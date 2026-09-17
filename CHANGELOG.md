# Changelog

Format based on [Keep a Changelog](https://keepachangelog.com/).

---

## [0.4.0] — 2026-09-15

### Added

- Test suite (`pytest` + `pymongo`) asserting the cluster's actual state: topology, majority writes, mandatory authentication and TLS, expected users, and least-privilege denials verified by error code
- GitHub Actions workflow provisioning the lab from nothing on a clean runner and running the suite on every push
- Branch protection on `main`: pull request required, status check must pass, force pushes blocked
- `make keyfile` target encapsulating the one step that requires root

### Changed

- `Makefile` rewritten for Ansible-based provisioning; `down` and `destroy` now differ in scope
- Dependencies split into `requirements.txt` (runtime) and `requirements-dev.txt` (tooling), declaring direct dependencies rather than a `pip freeze` dump
- `ansible` replaced by `ansible-core`; collections are declared and pinned in `ansible/requirements.yml` alone
- Node addition runbook rewritten: adding a member is now an inventory entry, not a Compose service definition

### Notes

The suite was validated by breaking things rather than by passing on the first
run: stopping two nodes, loosening keyfile permissions, and running the
privilege-escalation test as `admin` to confirm it fails when it should. A test
that has never been seen to fail is an assumption.

---

## [0.3.0] — 2026-09-06

### Added

- Ansible provisioning: four roles reproducing the full lab from nothing
- Cluster topology declared as inventory data
- Credential bootstrap via `docker-entrypoint-initdb.d`, removing any unauthenticated window during provisioning
- Secrets stored encrypted with `ansible-vault`
- State verification: the playbook fails if users are missing or keyfile permissions are wrong
- ADR 0004 (credential bootstrap) and ADR 0005 (unprivileged provisioning)
- Reference guide: Ansible and idempotent provisioning

### Changed

- Infrastructure definition moved from Docker Compose to Ansible
- Passwords for provisioning now come from the vault; `.env` is retained for interactive use only and is no longer authoritative

### Removed

- `compose/docker-compose.yml`, superseded by the Ansible roles

### Known limitations

- The keyfile ownership step requires root and is not automated; the playbook verifies it and fails with instructions
- Node private keys and the bootstrap script are world-readable during provisioning
- `docker-entrypoint-initdb.d` runs only on first initialisation; adding users later requires a separate procedure

---

## [0.2.0] — 2026-09-02

### Added

- Internal cluster authentication with a shared keyfile (`--keyFile`)
- Four purpose-scoped users with least-privilege roles
- TLS encryption in `requireTLS` mode with a project-local certificate authority
- Per-node X.509 certificates with SAN entries
- `.env` / `.env.example` pattern for credential handling
- ADR 0002 (keyfile vs. X.509) and ADR 0003 (user and role design)
- Runbooks: credential rotation, adding a replica set node
- Reference guide: MongoDB security

### Changed

- Client connections now require TLS and credentials

### Known limitations

- `root` role used instead of separating `userAdminAnyDatabase` from `clusterAdmin`
- Keyfile cannot be rotated per node
- CA private key stored alongside the certificates it signs
- Node certificates share `localhost` and `127.0.0.1` SAN entries
- No certificate renewal automation

---

## [0.1.0] — 2026-08-17

### Added

- Three-node MongoDB replica set defined in Docker Compose
- Named volumes for data persistence
- Dedicated Docker network with DNS resolution between nodes
- ADR 0001 (symmetric port publishing)
- Reference guides: Git/GitHub, Docker and replication

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
