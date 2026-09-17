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
cd ~/dbre/proyectos/mongo-ha-lab
docker ps --format "table {{.Names}}\t{{.Status}}"
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
The certificate is issued automatically by the `certificates` role, which iterates over `mongo_nodes`. No manual step is required.

### 2 · Name resolution

```bash
sudo nano /etc/hosts
```

Add `mongo4` to the existing line.

### 3 · Declare the node in the inventory

```bash
nano ansible/inventory/hosts.yml
```

Add an entry to `mongo_nodes`:

```yaml
    mongo_nodes:
      - name: mongo1
        port: 27017
      - name: mongo2
        port: 27018
      - name: mongo3
        port: 27019
      - name: mongo4
        port: 27020
```

That is the entire change. The certificate, volume, container and port
publishing are all derived from this list by the roles.

Symmetric port publishing, per [ADR 0001](../adr/0001-symmetric-port-publishing.md).

### 4 · Provision the new node

```bash
cd ansible
ansible-playbook site.yml --ask-vault-pass
```

The playbook is idempotent: it issues the certificate for the new node,
creates its volume and starts its container, leaving the existing nodes
untouched.

```bash
docker ps --format "table {{.Names}}\t{{.Status}}"
docker logs mongo4 --tail 30
```

Confirm the container is stable before joining it to the set: a container in
a restart loop must not become a member.

### 5 · Join it to the replica set

Connect to the primary:

```bash
docker exec -it mongo1 mongosh --port 27017 \
  --tls --tlsCAFile /etc/mongo/certs/ca.crt --tlsAllowInvalidHostnames \
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

Remove the `mongo4` entry from `ansible/inventory/hosts.yml`, then:

```bash
docker rm -f mongo4
docker volume rm mongo4_data
```

Also remove `mongo4` from `/etc/hosts`. Its certificate may be kept or
deleted; the role will not regenerate it once the node is out of the
inventory.

---

## Notes

**The keyfile is shared, the certificate is not.** The new node needs the same keyfile as the others, but its own certificate under its own name. Conflating the two is a common mistake.

**Watch the oplog window** during initial sync of large datasets. If the oplog wraps before the new member finishes, the sync fails and must be restarted, usually after enlarging the oplog.

**Effect on quorum.** Every voting member added changes `majorityVoteCount`. Check the arithmetic before applying the change: an even number of voters does not improve fault tolerance.

**Users are not created on a node added later.** The
`docker-entrypoint-initdb.d` bootstrap runs only on first initialisation of an
empty volume, and by then the node is not yet a set member. A node joined with
`rs.add()` receives users through replication from the primary, so no action
is needed — but the mechanism is different from the initial provisioning and
worth knowing.
