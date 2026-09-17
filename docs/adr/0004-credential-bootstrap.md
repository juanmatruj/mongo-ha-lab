# ADR 0004 · Credential bootstrap during container initialisation

**Status:** Accepted
**Date:** 2026-09-06

---

## Context

Stage 2 created users manually while the cluster was still running without authentication, then enabled the keyfile. That sequence is not reproducible: a provisioning run starting from empty volumes brings up nodes with `--keyFile` already set, so authentication is active from the first moment.

This creates a bootstrap problem. `replSetInitiate` and `createUser` both require authentication, and no user exists yet.

MongoDB provides the *localhost exception* for this: while no users exist, a connection from the loopback interface may create the first one. In practice this proved unusable here — `docker exec` connections arrive over the container's network interface, not loopback, and both `replSetInitiate` and `createUser` were rejected with `requires authentication`.

## Options considered

**A · Two-pass provisioning.** Start containers without `--keyFile`, initialise the replica set, create users, then re-run the container role with authentication enabled, letting `docker_container` recreate them.

Rejected. It opens a window during which the database runs with no authentication at all. In a lab that window is harmless; as a documented procedure it is not. Worse, if the run is interrupted between passes, the cluster is left running unauthenticated indefinitely with no signal that anything is wrong. **A procedure whose partial failure leaves the system in an insecure state is a bad procedure**, regardless of how briefly the window is intended to exist.

**B · Localhost exception via `docker exec`.** Attempted first. Fails because the connection does not originate from loopback. Adding `--host 127.0.0.1` did not help, and even if it had, the exception is a single-use escape hatch — it closes permanently once the first user exists and cannot be reopened without emptying the data directory. Building an automated procedure on top of it means a failure during user creation leaves the cluster permanently inaccessible.

**C · Bootstrap during container initialisation.** Chosen.

## Decision

Credentials are injected at container startup rather than applied afterwards.

The official MongoDB image, when starting against an empty data volume, runs an initialisation phase: it starts a temporary `mongod` bound to `127.0.0.1` inside the container, creates the root user from `MONGO_INITDB_ROOT_USERNAME` and `MONGO_INITDB_ROOT_PASSWORD`, executes any scripts found in `/docker-entrypoint-initdb.d`, shuts that process down, and only then starts the real server with the configured options.

- **Root user:** created by the image from environment variables.
- **Remaining users** (`monitoring`, `backup_user`, `app_user`): created by a templated script mounted into `/docker-entrypoint-initdb.d`.
- **Replica set initialisation:** performed afterwards by the `replicaset` role, authenticating as `admin`.

Secrets come from `ansible-vault` (`group_vars/all/vault.yml`), rendered into the script through Jinja's `to_json` filter.

## Consequences

**Positive**

- No window during which the database accepts unauthenticated connections. The temporary process is loopback-only and the real process starts with authentication already in place.
- No dependence on the localhost exception, and therefore no single-use failure mode.
- Single provisioning pass; no container recreation cycle.
- This is the mechanism used by Kubernetes operators and official Helm charts, so it is recognisable to any reviewer.

**Negative**

- **`docker-entrypoint-initdb.d` runs only on first initialisation.** Once a volume holds data, the script is ignored. Adding a user later requires a separate procedure, or destroying the volumes. This is a real operational constraint, not a detail.
- The rendered script contains passwords in cleartext and must be readable by UID 999, so it cannot be restricted to the owner. It is deleted after provisioning, but exists on disk during it.
- Users are created independently on each node during its own initialisation phase, before the replica set exists. State converges once the primary replicates, but the intermediate state is briefly divergent.

## Verification

Task completion does not prove the desired state. The provisioning run that first used this mechanism reported `failed=0` while the bootstrap script had silently not executed — the entrypoint logged `ignoring /docker-entrypoint-initdb.d/*` in a single line among hundreds and continued.

The role therefore ends with an explicit check of the resulting state:

```yaml
- name: Verify all expected users exist
  # counts documents in admin.system.users

- name: Fail if the bootstrap script did not run
  when: user_count.stdout | trim | int != 4
```

The failure message names the two known causes — non-empty volumes, or permissions preventing UID 999 from reading the script — and gives the commands to rebuild.

**Verify the effect, not the execution.** A task finishing without error means the command ran, not that the system reached the intended state. This was the recurring failure mode throughout the stage.

## Evidence

Provisioning from empty volumes, followed immediately by a second run:

```
PLAY RECAP
localhost : ok=23  changed=3  unreachable=0  failed=0  skipped=2

PLAY RECAP
localhost : ok=22  changed=0  unreachable=0  failed=0  skipped=3
```
