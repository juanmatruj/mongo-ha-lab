# ADR 0005 · Unprivileged provisioning, with one verified exception

**Status:** Accepted
**Date:** 2026-09-06

---

## Context

Files mounted into the MongoDB containers must be readable by the process inside them, which runs as UID 999. The host user provisioning the lab is UID 1000.

The obvious approach is for the playbook to `chown` those files to 999. This requires root, and `become: true` proved unusable in this environment: `sudo` returned `interactive authentication is required` even after `sudo -v`, because credential caching is bound to the originating TTY and Ansible opens its own session. Several configurations were tried without success.

Rather than continue working around the tooling, the requirement itself was questioned: **does provisioning actually need root?**

## Decision

Provisioning runs without privilege escalation. File permissions are set so the container can read what it needs without owning it.

| File | Mode | Owner | Rationale |
|---|---|---|---|
| `ca.key` | `0400` | 1000 | CA private key. Never mounted into containers |
| `ca.crt` | `0444` | 1000 | Public by design; distributed to clients |
| `*.key` | `0400` | 1000 | Node keys; read only via the `.pem` bundle |
| `*.crt` | `0444` | 1000 | Public |
| `*.pem` | `0644` | 1000 | Read by the container; writable by the owner so it can be regenerated |
| `keyfile` | `0400` | **999** | **Exception — see below** |
| `.initdb/` | `0755` | 1000 | Must be traversable by UID 999 |
| `.initdb/init-users.js` | `0644` | 1000 | Must be readable by UID 999 |

**The keyfile is the one exception.** MongoDB explicitly checks its permissions and refuses to start with anything readable by group or others:

```
"Read security file failed" ... "permissions on /etc/mongo/keyfile are too open"
"Error creating service context" ... "Unable to acquire security key[s]"
```

`0444` is rejected. The file must be `0400` and owned by the process user, so ownership must change — an operation the playbook cannot perform.

## How the exception is handled

The playbook does not attempt the change. It **verifies** it and fails with actionable instructions:

```yaml
- name: Fail if keyfile permissions are not as MongoDB requires
  ansible.builtin.fail:
    msg: |
      The keyfile must be owned by UID 999 with mode 0400.
      MongoDB refuses to start otherwise ("permissions are too open").
      This step requires root and is not automated. Run:

        sudo chown 999:999 <path>
        sudo chmod 400 <path>

      Current: uid={{ ... }} mode={{ ... }}
```

Separating what automation manages from what requires privileged intervention — and verifying the latter rather than pretending it does not exist — is a legitimate IaC pattern. A playbook that declares what it cannot manage is more honest than one that appears to control everything.

## Consequences

**Positive**

- Provisioning requires no root and no sudo configuration.
- Anyone can run it after cloning, with one documented manual step.
- No root-owned files left behind that later obstruct cleanup.
- The single privileged step is isolated, documented and checked on every run.

**Negative — stated plainly**

- **Node private keys are world-readable** (`0644` on the `.pem` bundles). On a single-user workstation this is acceptable; on a shared host it would not be.
- **The bootstrap script contains cleartext passwords and is world-readable** while it exists. It is removed after provisioning, but it is on disk during it.
- The manual `chown`/`chmod` step must be performed on first setup and is easy to forget. Mitigated by the check failing loudly.

## Note on UIDs

`ls -l` on the host may show the keyfile as owned by an unrelated service, for example `dnsmasq`, despite `chown 999:999` having succeeded. This is correct.

The kernel knows only numeric IDs; names are a presentation layer resolved through each system's own `/etc/passwd`. Host and container share the kernel but have different user databases, so UID 999 displays as `dnsmasq` on the host and `mongodb` inside the container.

**Reason in UIDs, not names, when working with mounted volumes.** Use `ls -ln` to see the numbers untranslated.

## Alternatives considered

**`become: true` with `--ask-become-pass`.** The intended approach. Failed for environment-specific reasons (`tty_tickets` in the sudo configuration) after several attempts.

**Passwordless sudo (`NOPASSWD`) for the provisioning user.** Widely suggested online. Rejected: it turns a compromised account into immediate root with no barrier. Where an automation host genuinely needs it, it is granted to a dedicated user for specific commands, never `ALL`.

**Running the containers as UID 1000.** Would remove the mismatch entirely, but diverges from the official image's expectations and would need testing against every file the server writes.
