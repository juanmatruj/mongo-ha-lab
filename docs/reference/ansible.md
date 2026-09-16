# Reference · Ansible and idempotent provisioning

> Stage 3 of the `mongo-ha-lab` project.
> Suggested location: `docs/reference/ansible.md`

---

## Contents

1. [Core concepts](#1-core-concepts)
2. [Project layout](#2-project-layout)
3. [Configuration and inventory](#3-configuration-and-inventory)
4. [Collections and version pinning](#4-collections-and-version-pinning)
5. [Roles](#5-roles)
6. [Variables and precedence](#6-variables-and-precedence)
7. [Building idempotence by hand](#7-building-idempotence-by-hand)
8. [Secrets with Ansible Vault](#8-secrets-with-ansible-vault)
9. [Templates and safe escaping](#9-templates-and-safe-escaping)
10. [Verifying the effect, not the execution](#10-verifying-the-effect-not-the-execution)
11. [Check mode and its limits](#11-check-mode-and-its-limits)
12. [Diagnosis and common errors](#12-diagnosis-and-common-errors)
13. [Command reference](#13-command-reference)
14. [Glossary](#14-glossary)

---

## 1. Core concepts

**Declarative vs. imperative.** A script says *do this, then this*. Ansible says *this should exist*. Run a script twice and it tries to create the user twice, failing the second time. Ansible checks whether the user exists and does nothing.

**Idempotence.** Applying an operation N times produces the same result as applying it once. It is not the same as "declarative" — it is the property that makes declarative work. It is also the acceptance criterion for a playbook: run it twice, and the second run reports `changed=0`.

That number is not cosmetic. If a playbook always reports changes, you lose the ability to distinguish "something actually changed here" from "this always looks like that". Once the noise is constant, nobody reads the output — the same dynamic that makes a noisy alert worthless.

**Agentless, over SSH.** Ansible installs nothing on managed machines: it connects over SSH, copies temporary Python modules, runs them and removes them. Against `localhost` it uses a local connection.

**Modules vs. `shell`.** This is where automating diverges from scripting. Modules check current state before acting. `shell` and `command` do not: they execute blindly and report `changed` every time, because they have no way of knowing whether the work was needed.

```yaml
# Bad: runs openssl every time, always reports a change
- name: Generate CA key
  shell: openssl genrsa -out certs/ca.key 4096

# Good: checks whether a valid key exists; does nothing if it does
- name: Generate CA private key
  community.crypto.openssl_privatekey:
    path: "{{ certs_dir }}/ca.key"
    size: 4096
    mode: "0400"
```

**Vocabulary**

| Term | Meaning |
|---|---|
| Inventory | Which machines you manage |
| Playbook | YAML file mapping hosts to tasks |
| Play | A block within a playbook: hosts plus their tasks |
| Task | A call to a module |
| Module | The unit that does the work and checks state |
| Role | Tasks, variables and files grouped for reuse |
| Handler | A task that runs only when notified |
| Fact | Data gathered from the managed machine |

---

## 2. Project layout

```
ansible/
├── ansible.cfg
├── requirements.yml          pinned collections
├── site.yml                  the playbook
├── inventory/hosts.yml
├── group_vars/all/vault.yml  encrypted secrets
└── roles/
    ├── certificates/         CA and per-node certificates
    ├── secrets/              keyfile
    ├── containers/           network, volumes, containers, user bootstrap
    └── replicaset/           rs.initiate() and verification
```

Role directories are loaded automatically by convention:

| Directory | Contents |
|---|---|
| `tasks/` | `main.yml`, the tasks. Required |
| `defaults/` | Default variables, lowest precedence |
| `vars/` | Variables, high precedence |
| `files/` | Files copied verbatim |
| `templates/` | Jinja2 templates |
| `handlers/` | Tasks triggered on notification |
| `meta/` | Role dependencies |

---

## 3. Configuration and inventory

```ini
[defaults]
inventory = inventory/hosts.yml
host_key_checking = False
result_format = yaml
display_skipped_hosts = False
retry_files_enabled = False
interpreter_python = auto_silent
```

`result_format = yaml` makes output far more readable than the default. Note that `stdout_callback = yaml`, which appears in older documentation, was **removed** from `community.general` in version 12 — the functionality moved into the default callback.

**Security note.** `host_key_checking = False` disables SSH host key verification. Acceptable when working locally; in production it is a genuine hole — the equivalent of `--tlsAllowInvalidCertificates`. It appears copied without thought in a great many repositories.

### Inventory as data

```yaml
all:
  hosts:
    localhost:
      ansible_connection: local
  vars:
    project_root: "{{ playbook_dir }}/.."
    replica_set_name: rs0
    mongo_image: "mongo:7.0.14"
    mongo_nodes:
      - name: mongo1
        port: 27017
      - name: mongo2
        port: 27018
      - name: mongo3
        port: 27019
```

This is one of the real gains of the stage: **cluster topology becomes data** rather than being repeated three times in a Compose file. Adding a fourth node is three lines here and nothing else.

```yaml
loop: "{{ mongo_nodes }}"
loop_control:
  label: "{{ item.name }}"
```

`loop_control: label` keeps the output readable by showing `mongo1` instead of dumping the whole dictionary.

---

## 4. Collections and version pinning

Since Ansible 2.10 most modules ship in collections installed separately.

```yaml
collections:
  - name: community.docker
    version: 3.13.0
  - name: community.crypto
    version: 2.22.3
  - name: community.mongodb
    version: 1.7.10
```

```bash
ansible-galaxy collection install -r requirements.yml
ansible-galaxy collection list
```

Versions are pinned for the same reason as in `pre-commit` and Docker image tags: **a deployment that is not reproducible is a deployment you do not control**.

Pin `ansible-core` too. Pinning collections while leaving the tool itself floating leaves you exposed to removals like the `stdout_callback = yaml` case above, where documentation and examples aged out of validity.

---

## 5. Roles

A role groups tasks, variables and templates around one responsibility. Splitting provisioning into four roles means each can be reasoned about, tested and reused separately.

```yaml
- name: Provision mongo-ha-lab
  hosts: all
  gather_facts: true

  roles:
    - certificates
    - secrets
    - containers
    - replicaset
```

Order matters: containers need certificates and the keyfile to exist before they start.

---

## 6. Variables and precedence

Variables in `defaults/` have the lowest precedence and can be overridden from the inventory, from `group_vars`, or on the command line. That is what makes a role reusable rather than a script in a different format.

**Defaults from every role in a play share one namespace.** If two roles define the same variable, the one loaded later wins — and which that is depends on playbook order, information not visible where the variable is used.

The result is a value that depends on role ordering. It works until someone reorders the playbook, and then the failure appears far from its cause. Hence the convention of prefixing variables with the role name in larger projects. With four roles, not duplicating is enough.

```bash
grep -rn "variable_name" roles/*/defaults/
```

---

## 7. Building idempotence by hand

When no module exists and `shell` or `command` is unavoidable, the state check must be supplied explicitly.

| Directive | Purpose |
|---|---|
| `creates:` | Skip if this file already exists |
| `removes:` | Skip if this file does not exist |
| `changed_when:` | Define what counts as a change |
| `failed_when:` | Define what counts as a failure |

```yaml
- name: Generate replica set keyfile
  ansible.builtin.shell: "openssl rand -base64 {{ keyfile_bytes }} > {{ keyfile_path }}"
  args:
    creates: "{{ keyfile_path }}"
```

Here `creates` is not cosmetic. Without it, every run would generate a new keyfile — **and break the cluster**, because running nodes hold the previous one and would stop authenticating to each other on restart. The difference between `changed` and `ok` is the difference between a working cluster and a broken one.

A playbook full of `shell` with none of these directives is a script in disguise.

### Non-convergent configuration

A declarative system converges towards the described state. If that description is self-contradictory — "this must exist" and "this must be absent" — it never converges and every run produces changes.

An early version of the certificates role generated CSR files and deleted them in the same run. Each pass recreated what the previous had removed, so the playbook could never reach `changed=0`. Removing the deletion task fixed it.

When caused externally this is called *configuration drift*; when caused by the code itself it is worse, because it is self-inflicted and permanent.

### Immutable output breaks regeneration

Writing a file with mode `0444` means the task that produced it cannot rewrite it on the next run — not even as the owner. Idempotence requires the ability to converge, which sometimes means the ability to overwrite.

---

## 8. Secrets with Ansible Vault

```bash
ansible-vault create group_vars/all/vault.yml
ansible-vault edit group_vars/all/vault.yml
ansible-vault view group_vars/all/vault.yml
ansible-playbook site.yml --ask-vault-pass
```

The file is encrypted at rest with AES256 and **can be committed to the repository**. Verify with:

```bash
head -2 group_vars/all/vault.yml    # $ANSIBLE_VAULT;1.1;AES256
```

This replaced an earlier approach that parsed a `.env` file with `slurp` and Jinja filters. That approach failed in a way worth recording: `split('\n')` inside YAML quotes splits on the literal two-character sequence backslash-n, **not on newlines**. The result was a dictionary with a single key — the first line of the file — and the failure surfaced much later, as a missing password on a user that had already been created with whatever survived.

A parser that fails partially and continues is worse than one that raises, because the symptom appears far from the cause.

If a `.env` file is kept for interactive use, document which source is authoritative. Two stores holding the same secrets will diverge the first time one is rotated and the other is not.

---

## 9. Templates and safe escaping

Passing a password through a shell command means it crosses several layers of quoting. Characters such as `+`, `/` and `=` — routinely produced by `openssl rand -base64` — can be altered along the way, and the resulting user is created with a password nobody knows.

The fix is to stop concatenating data into commands:

```jinja
db.createUser({
  user: {{ mongo_app_user | to_json }},
  pwd: {{ vault_app_pass | to_json }},
  roles: [{ role: "readWrite", db: {{ app_database | to_json }} }]
});
```

`to_json` handles escaping correctly for any input. The script is rendered to a file and executed with `--file` rather than `--eval`, removing the shell layer entirely.

**Separate data from code.** The underlying problem was never the specific character; it was embedding a value inside a command string.

---

## 10. Verifying the effect, not the execution

A task finishing without error means the command ran. It does not mean the system reached the intended state.

Three failures in this stage shared that shape:

- `wait_for` reported `ok` on ports held open by Docker's proxy while the containers behind them were in a restart loop.
- A `shell` task wrote empty `.pem` files and, because `creates` saw that files existed, never retried.
- The container entrypoint logged `ignoring /docker-entrypoint-initdb.d/*` and continued, leaving half the provisioning undone while the playbook reported `failed=0`.

The remedy is an explicit check of the resulting state:

```yaml
- name: Verify all expected users exist
  # counts documents in admin.system.users
  register: user_count
  changed_when: false

- name: Fail if the bootstrap script did not run
  ansible.builtin.fail:
    msg: |
      Expected 4 users, found {{ user_count.stdout | trim }}.
      ...known causes and the commands to rebuild...
  when: user_count.stdout | trim | int != 4
```

A failure message that names the likely causes and gives the commands to fix them is worth far more than a timeout on a port number.

The same pattern applies to what automation cannot do. Where a step requires privileges the playbook does not have, verify it and fail loudly rather than pretending it does not exist.

---

## 11. Check mode and its limits

```bash
ansible-playbook site.yml --check --diff
```

`--check` simulates without changing anything; `--diff` shows what would change. Together they are the standard way to review a change before applying it — the analogue of `terraform plan`.

**The limit:** Ansible simulates each task in isolation and cannot simulate the effects of one on the next. A task that creates a directory reports `changed` without creating it, and the next task, which writes inside it, fails.

Check mode is therefore useful against infrastructure that already exists, answering "what would change if I applied this?". Against an empty environment, most playbooks fail in cascade.

---

## 12. Diagnosis and common errors

| Symptom | Cause | Fix |
|---|---|---|
| `callback plugin has been removed` | Outdated `stdout_callback = yaml` | Use `result_format = yaml` |
| `sudo: interactive authentication is required` | `become` cannot supply a password; `tty_tickets` binds cached credentials to a TTY | Avoid the privilege requirement, or perform that step manually |
| `Timed out waiting for become success` | Ansible does not recognise the sudo prompt (localisation, or `-n` in `become_flags`) | Set the locale to `C.UTF-8`; remove `-n` |
| `Ansible requires the locale encoding to be UTF-8` | `LC_ALL=C` is ASCII | Use `LC_ALL=C.UTF-8` |
| `object of type 'dict' has no attribute X` | Parsing produced fewer keys than expected | Inspect with `debug: var=thing.keys() | list` |
| Second run never reaches `changed=0` | Non-convergent configuration, or a task with no state check | Look for create/delete pairs; add `creates`/`changed_when` |
| `Operation not permitted` on chmod | File owned by another UID | Check with `ls -ln` |
| Task reports success, system is broken | Verifying execution rather than effect | Add a state check |

### Localisation matters

Tools that parse the output of other tools depend on that text being predictable. A `sudo` responding `Contraseña:` breaks an Ansible expecting `password:`. This is why servers are configured with English and a neutral locale — not cultural preference, but parseability. The same problem appears with date formats, sort order and decimal separators.

In production, locale is part of declared state, not something inherited from the installation.

---

## 13. Command reference

```bash
# Environment
ansible --version
ansible-config dump --only-changed
ansible-galaxy collection list
ansible-galaxy collection install -r requirements.yml

# Connectivity and facts
ansible all -m ping
ansible all -m setup

# Running
ansible-playbook site.yml
ansible-playbook site.yml --ask-vault-pass
ansible-playbook site.yml --check --diff
ansible-playbook site.yml --tags certificates
ansible-playbook site.yml --start-at-task "Task name"
ansible-playbook site.yml -v          # -vv, -vvv for more detail

# Ad-hoc debugging
ansible localhost -m debug -a "msg={{ some_expression }}"
ansible localhost -m debug -a "var=some_variable"

# Vault
ansible-vault create group_vars/all/vault.yml
ansible-vault edit group_vars/all/vault.yml
ansible-vault view group_vars/all/vault.yml
ansible-vault rekey group_vars/all/vault.yml
```

---

## 14. Glossary

| Term | Meaning |
|---|---|
| Idempotence | Applying N times equals applying once |
| Convergence | Reaching and holding the declared state |
| Configuration drift | Divergence between declared and actual state |
| Declarative | Describing the target state, not the steps |
| Agentless | No software installed on managed hosts |
| Inventory | The set of managed machines |
| Play / playbook | A host-to-task mapping; the file containing it |
| Role | Reusable grouping of tasks and variables |
| Handler | Task triggered by notification |
| Fact | Data gathered from the target |
| Check mode | Simulation without changes |
| Vault | Encrypted storage for secrets |
| Lookup | Reading external data at template time |
| Bootstrap | Initial setup performed once, at creation |

---

## Further reading

- Ansible documentation: `docs.ansible.com`
- Collections index: `galaxy.ansible.com`
- *Ansible for DevOps*, Jeff Geerling — practical, opinionated, close to real use
- `ansible-doc <module>` — local module documentation with examples

---

*Stage 3 completed · September 2026 · `mongo-ha-lab`*
