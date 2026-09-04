# Runbook · Credential rotation

**Objective:** replace a MongoDB user's password without interrupting service.

**Estimated duration:** 10 minutes per user.
**Expected impact:** none, if the order below is followed.
**Requires:** `admin` credentials, access to the `.env` file.

---

## When to run this procedure

- Scheduled periodic rotation.
- Departure of someone who had access to the credential.
- **Suspected or confirmed leak** — in which case this is urgent and takes priority.
- The credential appeared in a commit, a log, a ticket or a screenshot.

> A credential that has left the controlled environment is considered compromised.
> Rotating it is what reduces the risk; deleting it from history does not.

---

## Pre-checks

```bash
cd ~/dbre/proyectos/mongo-ha-lab/compose
docker compose ps
```

All three nodes `Up`. Do not rotate credentials during an availability incident.

Identify the primary:

```bash
mongosh "mongodb://mongo1:27017,mongo2:27018,mongo3:27019/?replicaSet=rs0&authSource=admin" \
  --tls --tlsCAFile ../certs/ca.crt \
  --username admin --authenticationDatabase admin \
  --eval "db.hello().primary"
```

Changing a password is a write: it must run against the primary, and the change replicates from there.

---

## Procedure

### 1 · Generate the new password

```bash
openssl rand -base64 24
```

Do not invent it manually. Record it somewhere safe before continuing.

### 2 · Apply the change

```bash
mongosh "mongodb://mongo1:27017,mongo2:27018,mongo3:27019/?replicaSet=rs0&authSource=admin" \
  --tls --tlsCAFile ../certs/ca.crt \
  --username admin --authenticationDatabase admin
```

```javascript
use admin
db.changeUserPassword("app_user", passwordPrompt())
```

`passwordPrompt()` requests the password interactively and keeps it out of the `mongosh` history. **Do not type the password as a literal in the command.**

### 3 · Verify the change has replicated

Credentials live in `admin.system.users` and replicate like any other data. Check secondary lag before continuing:

```javascript
rs.printSecondaryReplicationInfo()
```

Lag should be a few seconds. With high lag, an application reconnecting to a secondary could authenticate against the old credential.

### 4 · Update the environment file

```bash
cd ~/dbre/proyectos/mongo-ha-lab
nano .env
ls -l .env        # confirm it is still mode 600
```

### 5 · Verify the new credential

```bash
mongosh "mongodb://mongo1:27017/?authSource=admin" \
  --tls --tlsCAFile certs/ca.crt \
  --username app_user --authenticationDatabase admin
```

And confirm the permissions are unchanged:

```javascript
use labdb
db.lab.findOne()          // should work
use admin
db.system.users.find()    // should still be denied
```

Changing a password does not alter roles, but verifying it confirms the right user was modified.

### 6 · Update the consumers

Restart or reload the configuration of everything that uses the credential: the application, the metrics exporter, backup scripts, scheduled jobs.

**This is the step that gets forgotten and the one that causes the incident** — typically hours later, when a scheduled job runs with the old credential.

Before closing, enumerate the known consumers of the credential explicitly and confirm each one.

---

## Final verification

- [ ] The new password authenticates successfully
- [ ] The user's permissions are unchanged
- [ ] `.env` updated and still mode 600
- [ ] The old password no longer works
- [ ] All consumers updated and working
- [ ] `git status` does not show `.env`
- [ ] No subsequent authentication errors in the logs

Confirm the old credential is genuinely invalidated:

```bash
mongosh "mongodb://mongo1:27017/?authSource=admin" \
  --tls --tlsCAFile certs/ca.crt \
  --username app_user --authenticationDatabase admin
```

With the previous password this must return `Authentication failed`.

---

## Rollback

There is no rollback: the previous password is unrecoverable, because MongoDB stores only a SCRAM verifier, not the password.

If something breaks after the change, the way out is **forward**, not back: identify the affected consumer and update its configuration. If access must be restored urgently, repeat the procedure setting the previous password if it is still known, or a new one, and update the consumers.

---

## Special case: keyfile rotation

The keyfile is a secret shared between nodes and **cannot be rotated with this procedure**. It requires a coordinated restart of all members, taking advantage of MongoDB's ability to accept two keys temporarily during the transition.

This is a known limitation of keyfiles compared to X.509 and is recorded in [ADR 0002](../adr/0002-keyfile-vs-x509.md).

---

## Record

Note in the project log: which credential was rotated, why, when, and whether any consumer was affected.
