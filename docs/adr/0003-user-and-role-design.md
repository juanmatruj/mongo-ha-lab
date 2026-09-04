# ADR 0003 · User and role design

**Status:** Accepted
**Date:** 2026-09-02

---

## Context

Enabling `--keyFile` also enables client authorization: once internal authentication is on, every client needs credentials. Users therefore had to be designed before the security layer was activated, not after.

MongoDB resolves the resulting bootstrap problem — no users exist, so no one can authenticate to create the first one — with the *localhost exception*, which permits creating exactly one user from a local connection. This lab avoids relying on it by creating all users while the cluster is still open, then enabling authentication.

## Decision

Four users, each scoped to a single purpose:

| User | Role | Auth database | Purpose |
|---|---|---|---|
| `admin` | `root` | `admin` | Cluster administration |
| `app_user` | `readWrite` | `admin` | Application access, limited to `labdb` |
| `monitoring` | `clusterMonitor` | `admin` | Metrics collection |
| `backup_user` | `backup` | `admin` | Backup operations |

All four are created in `admin`, which is their authentication database. This is separate from the databases they hold privileges over — the reason connection strings specify `authSource=admin`.

Passwords are generated with `openssl rand -base64 24`, stored in a `.env` file with mode `600`, and excluded from version control. A `.env.example` with placeholder values is versioned so the required variables are discoverable.

## Rationale

`clusterMonitor` and `backup` are read-only for their purposes. A compromised Prometheus exporter can read metrics but cannot write to the database — which is precisely the point of giving monitoring its own identity rather than reusing an administrative one.

`app_user` is confined to `labdb`. A compromised application credential cannot read other databases, cannot read `admin.system.users`, and cannot create new users.

## Consequences

**Positive**

- A compromised credential yields only the access that credential needs.
- Each consumer has a distinct identity, so access is attributable in the logs.
- Credential rotation can be performed per user without affecting others.

**Negative — acknowledged trade-off**

`root` is broad. In a production environment, administrative capability should be split: `userAdminAnyDatabase` for managing users, `clusterAdmin` for managing the cluster, so that no single identity accumulates both. A single `root` user is used here for lab simplicity, and it is a genuine weakening of the model rather than an equivalent choice.

**Negative — operational gaps**

- No password rotation policy or expiry.
- Users were created by typing passwords into `mongosh`, which records them in `~/.mongodb/mongosh/`. The correct approach uses `passwordPrompt()` or a script reading environment variables. Recorded here rather than quietly fixed, because it is the kind of detail that surfaces in an audit.
- `.env` on a workstation is adequate for a lab. Production requires a secrets manager (Vault, AWS Secrets Manager, SOPS) with audit logging and rotation.

## Verification

Least privilege was verified by connecting as each user and attempting operations outside its scope. As `app_user`:

- Writing to `labdb` — permitted
- Reading `admin.system.users` — denied
- Writing to another database — denied
- Creating a user with the `root` role — denied

The last denial is the one that matters: a compromised application credential cannot escalate by creating a new privileged user.

## Note on password storage

MongoDB never stores passwords. It stores a SCRAM verifier: a per-user random salt and a key derived through thousands of hash iterations. The operation is one-way — the password cannot be recovered from what is stored, by anyone, including the administrator.

An administrator can reset a password (`db.changeUserPassword()`) but cannot read it. That asymmetry between "can change" and "can read" is a deliberate property, and the reason no serious service can email a forgotten password back to a user.
