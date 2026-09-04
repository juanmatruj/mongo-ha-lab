# Runbook · Adding a replica set node

**Objective:** add a fourth member to the set without interrupting service.

**Estimated duration:** 20 minutes plus initial sync time, which depends on data volume.
**Expected impact:** none on ongoing operations. Additional load on the sync source during initial sync.

---

## Before starting: how many nodes?

With three voting members, the majority is two and **one** failure is tolerated. With four, the majority is three and **one** failure is still tolerated. The fourth node adds no fault tolerance, only cost.

Adding a fourth member makes sense if it is:

- **Non-voting** (`votes: 0`), serving analytical reads or backups.
- **Hidden** (`hidden: true`), for work that should receive no client traffic.
- **Delayed** (`secondaryDelaySecs`), as protection against human error.
- A step towards five members, which does tolerate two failures.

If the goal is more fault tolerance, the correct jump is from three to five.

---

## Pre-checks

```bash
cd ~/dbre/proyectos/mongo-ha-lab/compose
docker compose ps
df -h /
```

Three healthy nodes and enough disk for a full copy of the data.

```javascript
rs.status()
db.getReplicationInfo()
```

Record the **oplog window**. If initial sync takes longer than that window, the new member cannot reach the current state and the sync must be restarted, likely after enlarging the oplog.

Do not add nodes during an incident, or with a secondary already lagging.

---

## Procedure

### 1 · TLS certificate for the new node

```bash
cd ~/dbre/proyectos/mongo-ha-lab/certs

openssl genrsa -out mongo4.key 2048

openssl req -new -key mongo4.key -out mongo4.csr \
  -subj "/C=ES/O=mongo-ha-lab/CN=mongo4"

openssl x509 -req -in mongo4.csr -CA ca.crt -CAkey ca.key \
  -CAcreateserial -out mongo4.crt -days 825 \
  -extfile <(printf "subjectAltName=DNS:mongo4,DNS:localhost,IP:127.0.0.1")

cat mongo4.key mongo4.crt > mongo4.pem
chmod 400 mongo4.pem mongo4.key
chmod 444 mongo4.crt
sudo chown 999:999 mongo4.pem
rm mongo4.csr
ls -ln
```

Verify the SAN before continuing:

```bash
openssl x509 -in mongo4.crt -noout -subject -ext subjectAltName
```

### 2 · Name resolution

```bash
sudo nano /etc/hosts
```

Add `mongo4` to the existing line.

### 3 · Define the service

```bash
cd ../compose
nano docker-compose.yml
```

Copy an existing service, changing the name, port (27020), volume and certificate path. The **keyfile is the same**: it is a shared secret, not a per-node identity.

```yaml
  mongo4:
    image: mongo:7.0.14
    container_name: mongo4
    hostname: mongo4
    command: ["mongod", "--replSet", "rs0", "--bind_ip_all", "--port", "27020",
              "--keyFile", "/etc/mongo/keyfile",
              "--tlsMode", "requireTLS",
              "--tlsCertificateKeyFile", "/etc/mongo/certs/mongo4.pem",
              "--tlsCAFile", "/etc/mongo/certs/ca.crt",
              "--tlsAllowConnectionsWithoutCertificates"]
    ports:
      - "27020:27020"
    volumes:
      - mongo4_data:/data/db
      - ../secrets/keyfile:/etc/mongo/keyfile:ro
      - ../certs:/etc/mongo/certs:ro
    networks:
      - mongo-net
```

And declare `mongo4_data:` in the top-level `volumes` block.

Symmetric port publishing, per [ADR 0001](../adr/0001-symmetric-port-publishing.md).

### 4 · Start the new node only

```bash
docker compose config
docker compose up -d mongo4
docker compose ps
docker compose logs mongo4 | tail -30
```

Naming the service in `up` avoids touching the existing nodes. Confirm it starts stably before adding it: a container in a restart loop must not be joined to the set.

### 5 · Join it to the replica set

Connect to the primary:

```bash
mongosh "mongodb://mongo1:27017,mongo2:27018,mongo3:27019/?replicaSet=rs0&authSource=admin" \
  --tls --tlsCAFile ../certs/ca.crt \
  --username admin --authenticationDatabase admin
```

```javascript
db.hello().primary        // confirm this is the primary
rs.add("mongo4:27020")
```

For a hidden, non-voting member:

```javascript
rs.add({ host: "mongo4:27020", priority: 0, hidden: true, votes: 0 })
```

`rs.add()` modifies the set configuration and **may trigger an election**. Run it in a maintenance window if the service is sensitive.

### 6 · Follow the initial sync

```javascript
rs.status()
```

The new member passes through `STARTUP` → `STARTUP2` → `RECOVERING` → `SECONDARY`. It is copying the data and then applying the accumulated oplog.

```javascript
rs.printSecondaryReplicationInfo()
```

Do not consider the procedure complete until the member reads `SECONDARY` with minimal lag.

---

## Final verification

- [ ] `rs.status()` shows four members, the new one `SECONDARY`
- [ ] `rs.conf()` reflects the intended configuration (`priority`, `hidden`, `votes`)
- [ ] Replication lag is a few seconds
- [ ] `rs.status()` still shows exactly one `PRIMARY`
- [ ] `majorityVoteCount` matches the expected voting membership
- [ ] A `w:majority` write is acknowledged
- [ ] `git status` does not show `certs/`

```javascript
db.getSiblingDB("labdb").lab.insertOne(
  { verification: "node4", ts: new Date() },
  { writeConcern: { w: "majority" } }
)
```

---

## Rollback

```javascript
rs.remove("mongo4:27020")
```

```bash
docker compose stop mongo4
docker compose rm -f mongo4
docker volume rm compose_mongo4_data
```

Remove `mongo4` from the Compose file and from `/etc/hosts`. The certificates may be kept or deleted.

---

## Notes

**The keyfile is shared, the certificate is not.** The new node needs the same keyfile as the others, but its own certificate under its own name. Conflating the two is a common mistake.

**Watch the oplog window** during initial sync of large datasets. If the oplog wraps before the new member finishes, the sync fails and must be restarted, usually after enlarging the oplog.

**Effect on quorum.** Every voting member added changes `majorityVoteCount`. Check the arithmetic before applying the change: an even number of voters does not improve fault tolerance.
