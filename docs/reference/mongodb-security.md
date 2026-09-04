# Reference · MongoDB Security

> Stage 2 of the `mongo-ha-lab` project.
> Suggested location: `docs/reference/mongodb-security.md`
>
> Internal authentication, role-based access control and TLS encryption.

---

## Contents

1. [The two identity problems](#1-the-two-identity-problems)
2. [SCRAM and password storage](#2-scram-and-password-storage)
3. [The keyfile](#3-the-keyfile)
4. [The localhost exception](#4-the-localhost-exception)
5. [Users, roles and `authSource`](#5-users-roles-and-authsource)
6. [Built-in roles](#6-built-in-roles)
7. [Secret handling](#7-secret-handling)
8. [TLS fundamentals](#8-tls-fundamentals)
9. [Private CA and certificates](#9-private-ca-and-certificates)
10. [TLS modes and zero-downtime migration](#10-tls-modes-and-zero-downtime-migration)
11. [Mutual TLS](#11-mutual-tls)
12. [UIDs vs. usernames](#12-uids-vs-usernames)
13. [Diagnosis and common errors](#13-diagnosis-and-common-errors)
14. [Command reference](#14-command-reference)
15. [Glossary](#15-glossary)

---

## 1. The two identity problems

MongoDB answers two distinct questions, and conflating them leads to incomplete configurations.

| | Question | Mechanism |
|---|---|---|
| **Client authentication** | Who are you, connecting? | SCRAM-SHA-256 |
| **Internal authentication** | Are you a legitimate replica set member? | Keyfile or X.509 |

**Why internal authentication is needed.** Without it, any process that reaches the network can declare itself a member of the set, receive full replication of the data, and vote in elections. Client authentication does not prevent this, because the attacker does not connect as a client — it joins as a peer.

**Key dependency:** enabling `--keyFile` also enables client authorization. They are not independently optional. Once the keyfile is in play, everyone needs credentials.

And a third layer, independent of the first two: **encryption in transit**. Authentication protects credentials; it leaves the data itself in cleartext on the wire.

---

## 2. SCRAM and password storage

SCRAM (*Salted Challenge Response Authentication Mechanism*) is a challenge-response protocol: **the password never crosses the network**. The server issues a challenge, the client replies with a proof derived from the password, and the server verifies it without ever learning the password itself.

MongoDB **does not store passwords**. It stores a verifier:

```javascript
use admin
db.system.users.find().pretty()
```

```
credentials: {
  "SCRAM-SHA-256": {
    iterationCount: 15000,
    salt: "...",
    storedKey: "...",
    serverKey: "..."
  }
}
```

| Field | Purpose |
|---|---|
| `salt` | Random value, unique per user. Prevents identical passwords from producing identical verifiers and defeats precomputed tables |
| `iterationCount` | Number of iterations of the derivation function. Deliberately makes each brute-force attempt expensive |
| `storedKey`, `serverKey` | Derived keys used for mutual verification |

**The operation is one-way.** The verifier is derived from the password; the password cannot be recovered from the verifier. Not even by an administrator.

Practical consequences:

- A database dump does not expose user passwords.
- An administrator can **reset** a password, not **read** it. That asymmetry is a design property.
- No serious service can email you a forgotten password. If it can, it stores passwords recoverably.
- **Verifying a credential means using it, not reading it.**

---

## 3. The keyfile

A shared secret, identical across all members, used by nodes to authenticate to each other.

```bash
openssl rand -base64 756 > secrets/keyfile
chmod 400 secrets/keyfile
sudo chown 999:999 secrets/keyfile
```

| Requirement | Reason |
|---|---|
| Random content | It is a secret, not a certificate. The specific value is irrelevant |
| Identical on every node | It is shared: a node with a different keyfile cannot join |
| Between 6 and 1024 characters | MongoDB limit |
| Mode `400` | **MongoDB refuses to start** with looser permissions |
| Owned by the process user | UID 999 (`mongodb`) in the official image |

The permission check is deliberate: a shared secret readable by anyone is not a secret.

**Visible effect.** Before the keyfile, the cluster time signature is empty:

```
signature: { hash: 'AAAAAAAA...', keyId: 0 }
```

Afterwards it contains a real signature. This is the mechanism that prevents a third party from forging coordination messages between nodes.

**Limitation compared to X.509.** A shared secret cannot be rotated per node: changing it requires a coordinated restart of every member. X.509 allows replacing a single node's credential independently, which is why it is the norm in larger clusters.

---

## 4. The localhost exception

A circular problem: enabling authentication means credentials are required to connect, but no user exists yet and you cannot authenticate in order to create the first one.

MongoDB resolves this with the **localhost exception**: while no users exist, a connection from the machine itself may create the first user, and only the first. Once a user exists, the exception no longer applies.

**Preferred alternative when the cluster is already running:** create all users while the cluster is still open, then enable authentication. This avoids relying on the exception and allows the full set of users to be designed at once.

Knowing the exception is still necessary: on a fresh installation with authentication enabled from the start, it is the only path in.

---

## 5. Users, roles and `authSource`

### Where a user lives

A user belongs to an **authentication database**, which need not be the database it holds privileges over. By convention, administrative users are created in `admin`.

```javascript
use admin
db.createUser({
  user: "app_user",
  pwd: passwordPrompt(),
  roles: [ { role: "readWrite", db: "labdb" } ]
})
```

This user **lives in `admin`** and **acts on `labdb`**. Hence the connection string parameter:

```
mongodb://host:port/?authSource=admin
```

`authSource` tells the server where to look up the credentials. Omitting it is a frequent cause of `Authentication failed` with otherwise correct credentials.

### `passwordPrompt()`

```javascript
db.createUser({ user: "x", pwd: passwordPrompt(), roles: [...] })
db.changeUserPassword("app_user", passwordPrompt())
```

Prompts for the password interactively. Typing it as a literal records it in the `mongosh` history (`~/.mongodb/mongosh/`).

### User replication

Credentials live in `admin.system.users` and **replicate like any other data**. Creating or modifying a user is a write: it must target the primary, and the change takes as long to propagate as replication does.

---

## 6. Built-in roles

| Role | Scope | Capabilities |
|---|---|---|
| `read` | Database | Read only |
| `readWrite` | Database | Read and write |
| `dbAdmin` | Database | Indexes, statistics, validation |
| `userAdmin` | Database | User management for that database |
| `clusterMonitor` | Cluster | **Read-only** status and metrics |
| `clusterManager` | Cluster | Cluster configuration management |
| `backup` | Cluster | Read access for backups |
| `restore` | Cluster | Write access for restores |
| `readAnyDatabase` | All | Global read |
| `userAdminAnyDatabase` | All | Global user management |
| `clusterAdmin` | Cluster | Full cluster administration |
| `root` | Everything | Everything |

### Designing for least privilege

`clusterMonitor` and `backup` are **read-only** for their purposes. A compromised Prometheus exporter can read metrics but cannot write to the database — which is precisely why monitoring gets its own identity rather than reusing an administrative one.

**On `root`:** it is convenient, and it exists because someone has to be able to fix things. In production, `userAdminAnyDatabase` and `clusterAdmin` should be separated so that no single identity accumulates both capabilities. Using `root` is a concession, not an equivalent choice.

### Verifying least privilege

Connect as each user and attempt operations outside its scope. As `app_user`:

```javascript
use labdb
db.lab.insertOne({ x: 1 })                  // allowed

use admin
db.system.users.find()                       // denied

use another_db
db.data.insertOne({ x: 1 })                  // denied

db.createUser({ user: "intruder", pwd: "x", roles: ["root"] })   // denied
```

**The last denial is the one that matters:** a compromised application credential cannot escalate by creating another user.

A role design without this verification is an assumption.

---

## 7. Secret handling

```bash
openssl rand -base64 24        # generate passwords, don't invent them
chmod 600 .env                 # read/write for the owner only
```

**The `.env` + `.env.example` pattern:** the real file is ignored and a template with the required variables and placeholder values is versioned, so anyone cloning the repository knows what to fill in.

```gitignore
.env
.env.*
!.env.example
```

### Verification before every commit

```bash
git status --ignored | grep -E "\.env$|secrets|certs"
git grep -n "MONGO_.*_PASS="
git check-ignore -v certs/ca.key
```

`git grep` searches only tracked files. `git check-ignore -v` reports **which specific rule** in `.gitignore` blocks a file, with line number — the tool for answering why something is or is not ignored.

### Exit codes

In Unix tooling, no output means no matches, not failure.

```bash
grep -rn "pattern" .
echo $?
```

| Code | Meaning in `grep` |
|---|---|
| `0` | Matches found |
| `1` | No matches |
| `2` | Execution error |

Distinguishing *found nothing* from *failed* is what separates a script that detects a problem from one that silently misses it. For the same reason, `2>/dev/null` in a diagnostic check hides exactly the information being sought.

### Production

A `.env` file on a workstation is adequate for a lab. Production calls for Vault, AWS Secrets Manager, SOPS or `ansible-vault`, with audit logging and rotation.

---

## 8. TLS fundamentals

A TLS certificate asserts that **a public key belongs to a name**, and is signed by someone the client trusts.

| Component | Purpose |
|---|---|
| Private key | Never shared. Proves possession of the identity |
| Certificate | Public key + name + CA signature |
| CA certificate | What the client uses to verify the signature |

On the public internet, a commercial authority recognised by the browser signs. Internal infrastructure is different: nobody issues certificates for `mongo1`, which is not a public name. Instead you run a **private CA** and distribute its certificate to clients.

### SAN: the detail that causes most problems

The *Subject Alternative Name* declares which names a certificate is valid for.

```bash
-extfile <(printf "subjectAltName=DNS:mongo1,DNS:localhost,IP:127.0.0.1")
```

A certificate issued for `mongo1` **will not work** when connecting via an undeclared name, even if it reaches exactly the same server at the same IP.

**TLS does not verify where you arrived, it verifies who you believe you are talking to.** The certificate attests an identity; ask to speak to a different name and verification fails. That is the protection against impersonation: whoever hijacks DNS cannot attest the requested name without the CA's key.

---

## 9. Private CA and certificates

### Certificate authority

```bash
openssl genrsa -out ca.key 4096

openssl req -new -x509 -days 3650 -key ca.key -out ca.crt \
  -subj "/C=ES/O=mongo-ha-lab/CN=mongo-ha-lab-CA"
```

`ca.key` is the most sensitive artefact in the project: **whoever holds it can issue certificates the cluster will trust.** In production it belongs in an HSM or a secrets manager, never alongside the certificates it signs.

### Per-node certificate

```bash
openssl genrsa -out node.key 2048

openssl req -new -key node.key -out node.csr \
  -subj "/C=ES/O=mongo-ha-lab/CN=node"

openssl x509 -req -in node.csr -CA ca.crt -CAkey ca.key \
  -CAcreateserial -out node.crt -days 825 \
  -extfile <(printf "subjectAltName=DNS:node,DNS:localhost,IP:127.0.0.1")

cat node.key node.crt > node.pem
```

| File | Nature | Permissions |
|---|---|---|
| `ca.key` | CA key. **Highest sensitivity** | `400`, not exposed to the container |
| `ca.crt` | Public by nature | `444` |
| `*.key` | Node private key | `400` |
| `*.crt` | Node certificate | `444` |
| `*.pem` | Key + certificate concatenated | `400`, owned by `999:999` |
| `*.csr` | Signing request. **Disposable** | Delete after issuance |
| `ca.srl` | Serial number counter | Keep |

**Order matters in the `.pem`:** key first, certificate second.

**825 days** is the maximum modern browsers accept. Not applicable here, but it is the convention.

### Verification

```bash
openssl x509 -in node.crt -noout -subject -ext subjectAltName
openssl s_client -connect mongo1:27017 -CAfile ca.crt </dev/null
```

`s_client` is the standard tool for debugging TLS below the application layer. Look for `Verify return code`: a `0 (ok)` means the cryptographic side works and the problem lies elsewhere.

---

## 10. TLS modes and zero-downtime migration

```yaml
"--tlsMode", "requireTLS",
"--tlsCertificateKeyFile", "/etc/mongo/certs/mongo1.pem",
"--tlsCAFile", "/etc/mongo/certs/ca.crt"
```

| Mode | Behaviour |
|---|---|
| `disabled` | No TLS |
| `allowTLS` | Accepts both, prefers cleartext |
| `preferTLS` | Accepts both, prefers encrypted |
| `requireTLS` | Encrypted only |

**The intermediate modes exist to migrate a live cluster without downtime**, advancing in stages: enable `allowTLS`, migrate the clients, move to `preferTLS`, and finally to `requireTLS` once nothing uses cleartext. They are not permanent postures.

### Characteristic symptom of `requireTLS`

A client without `--tls` **does not get rejected, it hangs**. It sends cleartext, the server waits for a TLS handshake, neither understands the other, and both wait until the timeout expires.

> **An indefinite hang usually means a protocol mismatch, not a denial.**

---

## 11. Mutual TLS

Setting `--tlsCAFile` makes MongoDB **also require a client certificate** (mTLS). This is the opposite of web TLS, where only the server identifies itself.

### The symptom and how to read it

```
"Ingress TLS handshake complete"
"No SSL certificate provided by peer; connection rejected"
codeName: "SSLHandshakeFailed"
```

The TLS handshake **completed**: valid CA, valid server certificate, encryption established. The subsequent rejection is an authorization decision.

Read without the preceding line, the `SSLHandshakeFailed` code sends the investigation towards certificates, SAN entries and the CA — all of which were correct.

> **An error code names the layer where a problem surfaces, not its cause.**

### Two ways forward

**Allow clients without certificates** (identity via SCRAM):

```yaml
"--tlsAllowConnectionsWithoutCertificates"
```

Nodes still present certificates to each other; only the client requirement is relaxed.

**Issue client certificates** (the production norm):

```bash
openssl genrsa -out client.key 2048
openssl req -new -key client.key -out client.csr -subj "/C=ES/O=mongo-ha-lab/CN=admin-client"
openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out client.crt -days 825
cat client.key client.crt > client.pem
chmod 400 client.pem
```

Then connect with `--tlsCertificateKeyFile path/client.pem`.

### The option never to use

```bash
--tlsAllowInvalidCertificates
```

Frequently suggested online as a "fix" for certificate errors. It disables verification: **traffic is encrypted and handed to whoever can interpose**. It defeats the purpose of TLS.

---

## 12. UIDs vs. usernames

Checking keyfile permissions may show something like:

```
-r-------- 1 dnsmasq systemd-journal 1024 keyfile
```

despite having run `chown 999:999`. **This is correct.**

**The kernel does not know usernames, only numbers.** Names are a presentation layer that each system resolves through its own `/etc/passwd`. On the host, UID 999 may be `dnsmasq`; inside the container, that same 999 is `mongodb`.

Host and container **share the kernel but have different user files**, so the same numeric identifier displays under different names depending on where you look.

```bash
ls -ln              # shows numbers, untranslated
ls -l               # translates to local system names
id -u dnsmasq       # check which UID a name maps to
```

> **When working with mounted volumes, reason in UIDs, not names.**

This is the source of real surprises: a file that appears on the host to belong to an unrelated service is in fact accessible to the container process, and vice versa.

---

## 13. Diagnosis and common errors

| Symptom | Cause | Fix |
|---|---|---|
| `unrecognised option '--keyfile'` | MongoDB is case-sensitive: it is `--keyFile` | Fix it. Argument-parsing errors kill the process before it touches anything |
| Container in `Exited (2)` | `mongod` failed to start | `docker compose logs`; usually permissions or a misspelled option |
| `docker compose ps` shows nothing | It lists **running** containers only | Use `ps -a` |
| Keyfile permissions too open | Mode other than `400` | `chmod 400` |
| Permission denied reading the keyfile | UID mismatch | `chown 999:999` |
| `Authentication failed` with correct credentials | Missing `authSource=admin` | Add it to the connection string |
| `SSLHandshakeFailed` after a completed handshake | mTLS: no client certificate | `--tlsAllowConnectionsWithoutCertificates`, or issue one |
| Connection hangs with no error | Protocol mismatch: client without `--tls` against `requireTLS` | Add `--tls` |
| Hostname verification error | The name used is not in the SAN | Reissue with the correct SAN, or use a declared name |
| Long wait with `?replicaSet=` | The client is discovering the full topology | Drop the option to isolate a single node |

### Order of diagnosis

1. `docker compose ps -a` — do they exist, are they alive?
2. `docker compose logs <service>` — what does the process say?
3. `openssl s_client` — does TLS work below MongoDB?
4. Connect to a single node, without `?replicaSet=` — isolate
5. `rs.status()` from the node — what does the cluster think?

**An identical `ECONNREFUSED` can have entirely different causes** — a misresolved address, or a process that fails to start. The correct reflex is not to review the connection string, but to check `docker compose ps -a` and the logs.

### Viewing logs without blocking the terminal

```bash
docker compose up -d
docker compose logs -f mongo1
```

`docker compose up` without `-d` attaches the terminal, and `Ctrl+C` **stops the containers**. With `-d` plus `logs -f`, `Ctrl+C` only stops the log view.

---

## 14. Command reference

### Generating secrets and certificates

```bash
openssl rand -base64 24                    # password
openssl rand -base64 756 > keyfile         # keyfile

openssl genrsa -out ca.key 4096
openssl req -new -x509 -days 3650 -key ca.key -out ca.crt -subj "/CN=my-CA"

openssl genrsa -out node.key 2048
openssl req -new -key node.key -out node.csr -subj "/CN=node"
openssl x509 -req -in node.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out node.crt -days 825 \
  -extfile <(printf "subjectAltName=DNS:node,IP:127.0.0.1")
cat node.key node.crt > node.pem
```

### Inspecting certificates

```bash
openssl x509 -in node.crt -noout -subject -ext subjectAltName
openssl x509 -in node.crt -noout -dates          # validity period
openssl s_client -connect host:port -CAfile ca.crt </dev/null
```

### Permissions

```bash
chmod 400 *.key *.pem keyfile
chmod 444 *.crt
chmod 600 .env
sudo chown 999:999 *.pem keyfile ca.crt
ls -ln                                      # untranslated UIDs
```

### Users and roles

```javascript
use admin
db.createUser({ user: "x", pwd: passwordPrompt(), roles: [{ role: "readWrite", db: "labdb" }] })
db.getUsers()
db.getUser("app_user")
db.changeUserPassword("app_user", passwordPrompt())
db.grantRolesToUser("app_user", [{ role: "read", db: "other" }])
db.revokeRolesFromUser("app_user", [{ role: "read", db: "other" }])
db.dropUser("app_user")
db.runCommand({ connectionStatus: 1 })      // which identity am I connected as
```

### Connecting

```bash
# Replica set with TLS and authentication
mongosh "mongodb://mongo1:27017,mongo2:27018,mongo3:27019/?replicaSet=rs0&authSource=admin" \
  --tls --tlsCAFile certs/ca.crt \
  --username admin --authenticationDatabase admin

# Single node (diagnosis)
mongosh "mongodb://mongo1:27017/?authSource=admin" \
  --tls --tlsCAFile certs/ca.crt \
  --username admin --authenticationDatabase admin
```

**Do not embed the password in the connection string:** it lands in shell history and is visible in `ps` to any user on the machine while the process runs.

### Checking for secrets in Git

```bash
git status --ignored | grep -E "\.env$|secrets|certs"
git grep -n "PASS="
git check-ignore -v certs/ca.key
```

---

## 15. Glossary

| Term | Meaning |
|---|---|
| Authentication | Establishing who you are |
| Authorization | Establishing what you may do |
| Internal authentication | Between cluster members, distinct from client authentication |
| Keyfile | Shared secret used for internal authentication |
| Least privilege | Granting only the permissions required |
| Privilege escalation | Obtaining more permissions than were granted |
| Authentication database | Where a user is defined (`authSource`) |
| Certificate authority (CA) | The entity that signs certificates |
| Subject alternative name (SAN) | The names a certificate is valid for |
| Certificate signing request (CSR) | Request for a certificate to be issued |
| TLS handshake | Initial negotiation of the encrypted session |
| Mutual TLS (mTLS) | Both parties present certificates |
| Encryption in transit | Protection of data over the network |
| Encryption at rest | Protection of data on disk |
| Credential rotation | Periodic replacement of credentials |
| Impersonation / spoofing | Passing oneself off as another party |
| Defense in depth | Layered security, no single layer sufficient |
| Verifier | The derived value stored in place of a password |
| Salt | Per-user random value mixed into the derivation |

---

## Further reading

- MongoDB security manual: `mongodb.com/docs/manual/security/`
- Official security checklist: `mongodb.com/docs/manual/administration/security-checklist/`
- RFC 5802 (SCRAM) and RFC 8446 (TLS 1.3)
- *Bulletproof TLS and PKI*, Ivan Ristić

---

*Stage 2 completed · September 2026 · `mongo-ha-lab`*
