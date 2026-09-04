# Reference · Docker, networking and MongoDB replication

> Stage 1 of the `mongo-ha-lab` project.
> Suggested location: `docs/reference/docker-replication.md`
>
> From container fundamentals to replication architecture, including the
> failover experiments performed and their interpretation.
>
> **Note:** connection examples in this guide predate Stage 2. For current
> connection commands with authentication and TLS, see
> [`mongodb-security.md`](mongodb-security.md).

---

## Contents

1. [Container fundamentals](#1-container-fundamentals)
2. [Docker Compose](#2-docker-compose)
3. [Networking and name resolution](#3-networking-and-name-resolution)
4. [`bind_ip`: lab vs. production](#4-bind_ip-lab-vs-production)
5. [MongoDB replication architecture](#5-mongodb-replication-architecture)
6. [Elections, quorum and split-brain](#6-elections-quorum-and-split-brain)
7. [Initialising the replica set](#7-initialising-the-replica-set)
8. [Reading `rs.status()`](#8-reading-rsstatus)
9. [Failover experiments performed](#9-failover-experiments-performed)
10. [MongoDB startup warnings](#10-mongodb-startup-warnings)
11. [Managed vs. self-managed: Atlas](#11-managed-vs-self-managed-atlas)
12. [Diagnosis and common errors](#12-diagnosis-and-common-errors)
13. [Preflight checks](#13-preflight-checks)
14. [Command reference](#14-command-reference)
15. [Glossary](#15-glossary)

---

## 1. Container fundamentals

### What a container is

A container is a process on the host system running **isolated** from the rest through Linux kernel features: *namespaces* (giving it its own view of processes, network, filesystem and hostname) and *cgroups* (limiting how much CPU and memory it may consume).

The distinction from a virtual machine matters and comes up in interviews:

| | Virtual machine | Container |
|---|---|---|
| What is isolated | A full virtualised machine | Processes on the host kernel |
| Kernel | One per machine | Shares the host's |
| Startup | Tens of seconds | Milliseconds |
| Size | Gigabytes | Megabytes |
| Isolation | Very strong | Weaker: shared kernel |

Practical consequence: a Linux container needs a Linux kernel. On macOS and Windows, Docker actually runs a lightweight virtual machine underneath, which accounts for some performance and networking differences there.

### Image vs. container

An **image** is an immutable read-only template: a filesystem containing the application and its dependencies. A **container** is a running instance of an image, with its own writable layer on top.

The usual analogy: the image is the class, the container is the object. One image can back any number of containers, all sharing the read-only layers without duplicating them on disk.

Images are built in **layers**. Each `Dockerfile` instruction produces a layer, and layers are cached and reused between images. This is why pulling a second Debian-based image is far faster than the first.

### Image tags, and why not `latest`

```
mongo:7.0.14
│     │
│     └── tag: version
└── repository
```

`mongo:latest` **does not mean "the newest version"** in any guaranteed sense: it is simply the tag applied by default, pointing at whatever the maintainer decides at any given moment. Using it means the same configuration file produces different environments depending on the day.

This project pins `7.0.14`. It is the same pinning principle as in `pre-commit`: **a deployment that is not reproducible is a deployment you do not control**. For maximum precision there is the *digest* (`mongo@sha256:...`), which identifies exact, immutable content.

### State, and why databases are delicate in containers

A container writes to a temporary layer that **disappears when it is removed**. For a stateless application that is an advantage. For a database it is total data loss.

The answer is **volumes**: storage managed by Docker, independent of the container lifecycle.

| Type | Syntax | Use |
|---|---|---|
| Named volume | `mongo1_data:/data/db` | Managed by Docker. The norm for data |
| *Bind mount* | `./config:/etc/mongo` | Maps a host directory. Useful for configuration and development |
| `tmpfs` | — | In memory, always ephemeral. For temporary sensitive data |

This is the root of why running databases in containers — and even more so in Kubernetes — requires care: the container model is built for disposable, replaceable processes, and a database is precisely the opposite. Identity and persistence matter. Kubernetes addresses this with `StatefulSet` and `PersistentVolumeClaim`.

### Lifecycle

```
docker pull      download the image
docker create    create the container (does not start it)
docker start     start it
docker stop      SIGTERM → wait → SIGKILL. Graceful shutdown
docker kill      SIGKILL directly. Simulates an abrupt failure
docker rm        remove the container (volumes survive)
```

`docker run` combines `pull` + `create` + `start`.

**The difference between `stop` and `kill` matters greatly in this project:**

| | Signal | What the process does |
|---|---|---|
| `stop` | SIGTERM, then SIGKILL after 10 s | Can catch it and shut down gracefully: close files, notify the cluster, step down as primary |
| `kill` | SIGKILL | Not catchable. The process dies instantly, like a power cut |

Almost all real failures resemble `kill`, not `stop`. See [section 9](#9-failover-experiments-performed).

---

## 2. Docker Compose

### The problem it solves

Starting three containers with `docker run` requires three long commands, with ports, volumes and networking, executed in the right order and repeated identically every time. Compose replaces that with **a single declarative, versionable file**: you describe the desired state and one command realises it.

This is the first appearance of the *declarative vs. imperative* principle, which returns in Ansible and Terraform: instead of stating *how* to reach a state, you describe *what* the state is.

Compose automatically creates a dedicated network for the project and prefixes resource names with the directory name, avoiding collisions with other projects.

### Recognised filenames

`compose.yaml`, `compose.yml`, `docker-compose.yaml`, `docker-compose.yml`. Searched for in the **current directory**. A hyphen typed as a dot, or running the command from the wrong directory, produces `no configuration file provided`.

Historical note: `docker-compose` with a hyphen is version 1, written in Python and deprecated since 2023. `docker compose` with a space is the current plugin. The syntax differs in details.

### The file, directive by directive

```yaml
services:
  mongo1:
    image: mongo:7.0.14
    container_name: mongo1
    hostname: mongo1
    command: ["mongod", "--replSet", "rs0", "--bind_ip_all", "--port", "27017"]
    ports:
      - "27017:27017"
    volumes:
      - mongo1_data:/data/db
    networks:
      - mongo-net

networks:
  mongo-net:
    name: mongo-net

volumes:
  mongo1_data:
```

| Directive | Function |
|---|---|
| `services` | Each entry defines a container. The key (`mongo1`) is also the DNS name inside the network |
| `image` | Image and tag. Pinned, never `latest` |
| `container_name` | Fixed container name. Without it, Compose generates `project-service-1`. Convenient for commands, but prevents scaling the service to several replicas |
| `hostname` | The name the container gives itself (what `hostname` returns inside). Relevant because MongoDB uses it when identifying itself |
| `command` | Replaces the image's default command. In list form (*exec form*), avoiding shell interpretation |
| `ports` | Publishes a port on the host. Format **`host:container`** |
| `volumes` | Persistence. `name:/path/in/container` |
| `networks` | Networks the container joins |

**The top-level `volumes` block** declares volumes; the one inside the service uses them. They are easily confused: two distinct sections with the same name.

### Main commands

```bash
docker compose config      # validate the YAML and show the resolved configuration
docker compose up -d       # create and start in the background
docker compose ps          # status of the project's services
docker compose logs -f s   # live logs for a service
docker compose exec s cmd  # run something inside a running container
docker compose stop        # stop without removing
docker compose start       # restart what was stopped
docker compose down        # stop and REMOVE containers and network
docker compose down -v     # also removes volumes: DESTROYS THE DATA
```

`docker compose config` deserves to become a habit: it validates YAML syntax without touching anything. For any doubt about the file, it is the first command.

`down -v` is destructive and asks for no confirmation. It is the equivalent of `DROP DATABASE`.

### `exec` vs. `run`

`exec` enters an **already running** container. `run` creates a new one. To inspect a live service, always `exec`.

---

## 3. Networking and name resolution

### The Compose network and its DNS

Compose creates a bridge network and runs an internal DNS server. Within that network, **the service name resolves to the container's IP**: from `mongo1` you can reach `mongo2` without knowing its address. IPs change between restarts; names do not. Hence names, never IPs, in configuration.

```bash
docker network ls
docker network inspect mongo-net
docker compose exec mongo1 ping -c1 mongo2
```

### `localhost` means different things in different places

This is the most frequent conceptual error with containers.

`localhost` (127.0.0.1) always means **"this same machine"**. But inside a container, "this same machine" is the container, not your host. A `mongod` configured to listen only on `localhost` inside the container is unreachable from outside, even with the port published.

Hence `--bind_ip_all`, which makes it listen on all interfaces.

### Port publishing

```
ports:
  - "27018:27018"
     │      └── port inside the container
     └── port on your machine
```

Publishing a port starts a host process forwarding traffic. A host port can be held by only one process: if a native MongoDB is listening on 27017, `up` will fail.

```bash
ss -tlnp | grep 27017      # see what holds a port
```

### `/etc/hosts` and resolution order

`/etc/hosts` is a name-to-IP mapping file the system consults **before** DNS. The order is defined in `/etc/nsswitch.conf` (`hosts: files dns`): files first, then DNS.

This lab adds:

```
127.0.0.1   mongo1 mongo2 mongo3
```

so that the names registered in the replica set also resolve from the host machine.

It is local machine configuration, **not versioned**, and must be listed as a prerequisite in the README for anyone cloning the repository.

### The design fault found, and its lesson

The first version of the file mapped `27018:27017` and `27019:27017`: all three `mongod` processes listened internally on 27017 and were published on distinct host ports. The replica set was configured with `mongo1:27017`, `mongo2:27017`, `mongo3:27017`.

From the host, with all three `/etc/hosts` entries pointing at 127.0.0.1, **the three addresses resolved to `127.0.0.1:27017`** — always mongo1. The cluster worked while mongo1 was primary, by coincidence, and failed with `ECONNREFUSED` as soon as that node was stopped.

The fix was for each `mongod` to listen on its own port with symmetric publishing (`27018:27018`), so that a single address is valid from inside and outside.

> **General rule.** The addresses recorded in a replica set configuration must
> resolve to the correct nodes **from every client that will connect**, not
> only from within the cluster. The client receives those addresses from the
> cluster itself and reconnects using them.

And a broader reliability lesson: the system **worked correctly for a period by coincidence** and only failed when one specific node went down. Latent faults that surface only during an incident are the most damaging, because they appear at the worst possible moment.

### Replica set connection string

```
mongodb://mongo1:27017,mongo2:27018,mongo3:27019/?replicaSet=rs0
```

Connecting this way is **not** connecting to three servers. The list is only an entry point (*seed list*): the driver contacts any of them, asks for the topology, and from then on manages the whole cluster — identifying the primary, routing writes and detecting changes without intervention.

This is why, during failover, the client found the new primary on its own. The contrast with `mongosh --port 27017` is substantial: that is a direct connection to one node, with no cluster awareness.

---

## 4. `bind_ip`: lab vs. production

`--bind_ip_all` makes `mongod` listen on **all** network interfaces. In this lab it is acceptable because the network is isolated and holds no real data. On a server with a public address, a MongoDB listening on every interface without authentication is a compromised database within hours — there were waves of MongoDB ransom attacks caused by exactly this configuration.

### What is actually done

Network exposure is limited to what is strictly necessary and, above all, **is never relied on alone**:

1. **`bind_ip` set to specific addresses.** The private IP of the interface connections should arrive on, plus `127.0.0.1`. Never a public interface.
   ```yaml
   net:
     bindIp: 127.0.0.1,10.0.1.15
     port: 27017
   ```
2. **Private network.** The cluster lives in a subnet with no route from the internet.
3. **Firewalls and security groups.** Port 27017 open only from the other replica set nodes and the application servers. Default deny.
4. **Mandatory authentication** (`security.authorization: enabled`) and internal authentication between nodes.
5. **TLS** to encrypt traffic in transit.
6. **Administrative access via bastion or VPN**, never directly from the internet.

### The underlying idea

`bind_ip` is **one layer among several**, just as `.gitignore` is for secrets. A MongoDB reachable over the network but protected by authentication and TLS is awkward to attack; one restricted by network but without authentication falls as soon as someone reaches the same subnet — through a compromised container, a misconfigured VPN or a breached application server.

This is **defence in depth**, and the reason Stage 2 adds authentication and TLS rather than settling for network restriction.

In Atlas this layer is visible and remains your responsibility: the IP access list and network peering are exactly this, even though you do not administer the servers.

---

## 5. MongoDB replication architecture

### The model

A **replica set** is a group of `mongod` processes holding copies of the same data.

| Role | Function |
|---|---|
| **Primary** | The only member accepting writes. Records every operation in the oplog |
| **Secondary** | Replicates and applies the primary's oplog. May serve reads if the client allows it |
| **Arbiter** | Votes in elections but stores no data. **Discouraged**: adds no redundancy and complicates write guarantees |

Replication exists **for availability and durability**, not to spread write load: every write goes through a single node. Spreading writes is the purpose of *sharding*, which is a different mechanism.

### The oplog

The *oplog* (operations log) is a fixed-size *capped collection* in the `local` database where the primary records every data-modifying operation in **idempotent** form: applying the same entry twice yields the same result. That allows safe reapplication after an interruption.

Secondaries read their sync source's oplog and apply it.

**The oplog window** is the timespan from the oldest to the newest operation it holds. It is the key operational metric: if a secondary is down for longer than that window, the operations it needed have already been overwritten and it **cannot catch up incrementally**; it requires a full resync from scratch, which on a large database can take hours.

Monitoring the oplog window is a standard alert in any serious deployment. The oplog is also the basis of point-in-time recovery and of *change streams*.

```javascript
use local
db.oplog.rs.find().limit(5)
db.getReplicationInfo()              // oplog size and window
rs.printSecondaryReplicationInfo()   // per-secondary lag
```

### Sync source

A secondary does not necessarily replicate from the primary: it may chain from another secondary (*chained replication*), choosing the closest source by latency. The `syncSourceHost` field in `rs.status()` shows this.

In the experiment, mongo3 switched its `syncSourceHost` to the new primary automatically after failover.

### Asynchronous replication and its consequences

Replication is **asynchronous**: the primary does not wait for secondaries before acknowledging a write, unless explicitly asked to.

Hence **write concern**, the guarantee you demand on acknowledgement:

| Value | Meaning |
|---|---|
| `w: 1` | Acknowledged when the primary applies it. Fast, but can be lost if the primary fails before replicating |
| `w: "majority"` | Acknowledged when a majority of nodes hold it. Survives primary failure. Default since MongoDB 5.0 |
| `j: true` | Additionally requires the write to be in the on-disk journal |
| `wtimeout` | Maximum wait |

This is where the latency-versus-durability trade-off becomes concrete.

### Read preference

Determines which nodes the client may direct reads to: `primary` (default), `primaryPreferred`, `secondary`, `secondaryPreferred`, `nearest`.

Reading from secondaries spreads load but introduces **eventual consistency**: you may read slightly stale data. It is an application design decision, not a free optimisation.

### Other member settings

| Option | Use |
|---|---|
| `priority: 0` | Never becomes primary. For nodes in a secondary data centre |
| `hidden: true` | Invisible to clients. For backup or analytics work |
| `secondaryDelaySecs` | Delayed replica. Protects against human error: if someone drops a collection, this node has not applied it yet |
| `votes: 0` | Participates without voting. To exceed the 7 voting member limit |

A replica set supports up to 50 members, of which at most 7 may vote.

---

## 6. Elections, quorum and split-brain

### How failure is detected

Members exchange heartbeats every 2 seconds (`heartbeatIntervalMillis: 2000`). If a secondary receives no response from the primary for `electionTimeoutMillis` — **10 seconds** by default — it considers it down and stands as a candidate.

### The election

MongoDB implements a variant of the **Raft** consensus algorithm. The candidate requests votes; to win it needs a **strict majority** of voting members, and only succeeds if its data is sufficiently current.

Before being promoted, the new primary runs a *catch-up* phase, ensuring it has applied every operation its predecessor might have held (`numCatchUpOps`).

### The `term`

Each election increments a monotonic counter, the **term**. This is what prevents split-brain: if a former primary revives after a network partition and attempts to write with a stale term, the rest of the cluster rejects it. **Nobody needs to inform it that it has been deposed: the number gives it away.**

Any writes from the previous term that never replicated to a majority are rolled back and archived to disk when the node rejoins.

### Quorum arithmetic

`rs.status()` exposes this explicitly:

```
votingMembersCount: 3     majorityVoteCount: 2     writeMajorityCount: 2
```

| Nodes | Majority | Failures tolerated |
|---|---|---|
| 1 | 1 | 0 |
| 2 | 2 | **0** |
| 3 | 2 | 1 |
| 4 | 3 | 1 |
| 5 | 3 | 2 |

**Why an odd number.** With 4 nodes the majority is 3, so you tolerate one failure just as with 3, but pay for an extra server. The even node adds no tolerance, only cost. Additionally, in a network partition splitting the cluster into two equal halves, neither reaches a majority and the whole cluster is left without a primary.

### Why the survivor refuses writes

On losing the majority, the surviving node **demotes itself to secondary**. It stays up and can serve reads, but accepts no writes.

The reason is that **an isolated node cannot distinguish two situations**: its peers having died, or itself having been cut off. If it assumed it could keep writing and the latter were true, there would be two primaries accepting divergent writes: *split-brain*, and irreconcilable data.

MongoDB prefers to **stop accepting writes rather than risk consistency**. This is a deliberate design choice: in CAP terms, MongoDB sits on the CP side, sacrificing write availability.

### How it looks from the client

On quorum loss, the client returns:

```
MongoServerSelectionError: connect ECONNREFUSED ...
```

The driver **does not report "no quorum"** — that is a cluster state, not an operation error. It attempts to select a valid server for the write, finds no primary, and returns the last network error it collected, which corresponds to the dead nodes.

> **Operational lesson.** In an incident, the client tells you something is
> unreachable; only the server tells you why. Connecting directly to the
> surviving node (`mongosh --port XXXXX`) and inspecting `rs.status()` and the
> logs is the first diagnostic step, ahead of the application's error message.

---

## 7. Initialising the replica set

With `--replSet rs0`, the process starts but refuses operations until the set is initialised:

```javascript
rs.initiate({
  _id: "rs0",
  members: [
    { _id: 0, host: "mongo1:27017" },
    { _id: 1, host: "mongo2:27018" },
    { _id: 2, host: "mongo3:27019" }
  ]
})
```

`_id` must match the name passed to `--replSet`. The addresses must be resolvable from every client (section 3).

`rs.initiate()` runs **exactly once**, from any member. The others receive the configuration through replication.

### Operating on the configuration

```javascript
rs.conf()                                  // current configuration
rs.add("mongo4:27020")                     // add a member
rs.remove("mongo4:27020")                  // remove a member
rs.stepDown(60)                            // primary yields its role
rs.reconfig(cfg)                           // apply a modified configuration
rs.printSecondaryReplicationInfo()         // secondary lag
```

`rs.stepDown()` is the planned failover tool: it is used before maintenance to trigger a controlled primary change rather than waiting for one to happen unexpectedly.

---

## 8. Reading `rs.status()`

Relevant fields from the lab's actual output:

### Global state

| Field | Meaning |
|---|---|
| `set` | Replica set name |
| `myState` | State of the queried node: 1 primary, 2 secondary |
| `term` | Current term. Increments with each election |
| `heartbeatIntervalMillis` | Heartbeat frequency (2000 ms) |
| `majorityVoteCount` | Votes required to win an election |
| `writeMajorityCount` | Nodes required to acknowledge `w:majority` |

### Last election metrics

```
electionCandidateMetrics: {
  lastElectionReason:  'stepUpRequestSkipDryRun',
  lastElectionDate:                10:11:00.249,
  newTermStartDate:                10:11:00.254,
  wMajorityWriteAvailabilityDate:  10:11:00.260,
  numVotesNeeded: 2,
  electionTimeoutMillis: 10000,
  numCatchUpOps: 0
}
```

`wMajorityWriteAvailabilityDate` minus `lastElectionDate` is **the real write-unavailability window**. In the experiment: 11 milliseconds.

Values of `lastElectionReason`:

| Value | Situation |
|---|---|
| `electionTimeout` | No heartbeats received from the primary. **A real failure** |
| `stepUpRequestSkipDryRun` | The primary yielded gracefully |
| `priorityTakeover` | A higher-priority node claimed the role |
| `catchUpTakeover` | A more current node displaced a lagging primary |

> **The system already measures its own metrics precisely.** Before timing
> anything by hand, check whether the database is already recording it. This is
> the raw material of observability.

### Per member

| Field | Meaning |
|---|---|
| `stateStr` | `PRIMARY`, `SECONDARY`, `STARTUP2`, `RECOVERING`, `(not reachable/healthy)` |
| `health` | 1 healthy, 0 unreachable |
| `syncSourceHost` | Which node this one replicates from |
| `optimeDate` | Time of the last applied operation |
| `lastHeartbeatMessage` | Failure reason, if any |

**An important interpretive detail.** A downed node shows `optimeDate: 1970-01-01T00:00:00.000Z`, the Unix epoch. The cluster is not claiming "it is at time zero" but **"I have no information"**. Distinguishing *missing data* from *zero value* prevents serious misreadings when the data reaches a monitoring graph — a zero gets averaged, an absence does not.

### `$clusterTime` and the signature

```
signature: { hash: 'AAAAAAA...', keyId: 0 }
```

The cluster time signature is empty because internal authentication is not configured. With a keyfile in place, this field carries a real signature: the mechanism preventing a third party from forging coordination messages between nodes.

---

## 9. Failover experiments performed

### Experiment 1 · Graceful shutdown (`docker compose stop`)

- **Result:** immediate election, new primary in **11 ms**.
- **Recorded reason:** `stepUpRequestSkipDryRun`.
- **Interpretation:** `stop` sends SIGTERM. MongoDB catches it, understands it is shutting down and **yields the role before dying**: it selects the most current secondary and asks it to step up. The candidate skips the dry run because the outgoing primary vouches for it.

> **This is not a failure, it is a clean shutdown.** A real server rarely shuts
> down gracefully when it fails: power is cut, the kernel panics, the network
> drops, the disk fills.

### Experiment 2 · Abrupt failure (`docker compose kill`)

- **Expected reason:** `electionTimeout`.
- **Expected duration:** on the order of 10 seconds (`electionTimeoutMillis`) plus the election.

Comparing the two numbers is the result with real value: it measures the difference between planned maintenance and an incident.

Operational corollary: **run `rs.stepDown()` before maintenance** to turn a tens-of-seconds incident into a milliseconds one.

### Experiment 3 · Quorum loss (two nodes down)

- The surviving node becomes `SECONDARY` and **refuses writes**.
- Reads remain possible by connecting to it directly.
- The client returns `MongoServerSelectionError` wrapping a `MongoNetworkError`.

A practical demonstration of the CP choice in CAP terms and of why an odd number of nodes is used.

### Recovery

On restart, nodes pass through `STARTUP2` or `RECOVERING` before reaching `SECONDARY`: they are applying the oplog accumulated during their absence.

**The original primary does not reclaim its role on return.** There is no preference for the initial node: the primary is simply whoever won the last election. If a preferred node is wanted, it is configured with `priority`.

---

## 10. MongoDB startup warnings

```
Using the XFS filesystem is strongly recommended with the WiredTiger storage engine
Access control is not enabled for the database
Soft rlimits for open file descriptors too low
```

| Warning | Meaning |
|---|---|
| **XFS recommended** | WiredTiger, the storage engine, performs better on XFS than on ext4, due to its allocation and concurrent write handling |
| **Access control disabled** | Anyone reaching the port has full read, write and administrative access |
| **File descriptor limit too low** | Each connection consumes a descriptor. A low limit means refused connections under load (`ulimit -n`, 64000 recommended) |

> **Recommended habit: always read a database's startup warnings.** They are a
> free diagnostic the engine offers on every start and that almost everyone
> ignores.

---

## 11. Managed vs. self-managed: Atlas

**MongoDB Atlas** is the vendor's own managed offering (*DBaaS*). The servers run on provider infrastructure; you receive a connection string and a console.

### Division of responsibility

| Responsibility | Self-managed | Atlas |
|---|---|---|
| Server and OS provisioning | You | Provider |
| MongoDB installation and patching | You | Provider |
| Replica set configuration | You | Provider |
| Automatic failover | You configure it | Included |
| Backups and their verification | You | Automated (verifying restores remains yours) |
| Basic monitoring | You build it | Included |
| **Data modelling and indexes** | **You** | **You** |
| **Query design and performance** | **You** | **You** |
| **Access control and users** | **You** | **You** |
| **IP access list and networking** | **You** | **You** |
| **Cost and sizing** | **You** | **You** |
| **Recovery strategy (RPO/RTO)** | **You** | **You** |

This is the **shared responsibility model**: the provider takes on the infrastructure, the customer remains responsible for their data, their access and their design. A managed cluster does not protect against a missing index, a query doing a collection scan, an over-privileged user or an accidental deletion.

### What Atlas hides

In Atlas the replica set **exists but is invisible**: someone configured it, someone manages the elections, and the user sees only a connection string. Building it by hand, breaking it and watching the election is what turns that black-box component into something understood.

That is the boundary between **using** a database and being **responsible for its reliability**.

### When to choose which

| Self-managed | Managed |
|---|---|
| Compliance or data sovereignty requirements | Small teams without a dedicated DBA |
| Need for highly specific configuration | Time-to-market priority |
| Cost at large scale | Variable or unpredictable load |
| Offline or on-premise environments | Reducing operational toil |

Many organisations combine both. And it is worth knowing that Atlas is standard MongoDB underneath: nearly everything learned here applies equally.

### Practical note

Atlas consumes no local resources and does not interfere with a Docker lab. A **natively installed** MongoDB does, because it occupies port 27017:

```bash
systemctl status mongod
sudo systemctl stop mongod
```

And a warning: an Atlas connection string contains a username and password. **It must never end up in a repository**, not even a private one.

---

## 12. Diagnosis and common errors

### Order of diagnosis

1. `docker compose ps -a` — are the containers running?
2. `docker compose logs <service>` — what does the process say?
3. `docker compose exec <service> mongosh --port X` — does the node respond?
4. `rs.status()` from the node — what does the cluster think of itself?

Outside in, and **always reading the logs before changing anything**.

### Error table

| Symptom | Cause | Fix |
|---|---|---|
| `no configuration file provided` | Wrong directory or incorrect filename | `pwd`, `ls -la`. Valid names in section 2 |
| `port is already allocated` | Another process holds the host port | `ss -tlnp \| grep PORT`; stop the native MongoDB |
| `ECONNREFUSED` from the client | Nothing listening at that address: node down or address misresolved | Check `/etc/hosts` and the port mapping |
| `MongoServerSelectionError` | The driver finds no valid node for the operation | May be quorum loss: query the surviving node |
| `not primary` | Attempting to write to a secondary | Use the connection string with `?replicaSet=` |
| `no replset config has been received` | `rs.initiate()` missing | Initialise the set |
| Node stuck in `STARTUP2` | Initial sync in progress, or outside the oplog window | Wait; check `getReplicationInfo()` |
| Container in a restart loop | `mongod` fails to start | `docker compose logs`; usually permissions or configuration |
| Data disappears on restart | Missing volume, or `down -v` was used | Review the `volumes` section |
| Permission denied using `docker` | User not in the `docker` group | `sudo usermod -aG docker $USER` and log back in |

### Security note on the `docker` group

Membership of the `docker` group is **effectively equivalent to root** on the machine: it allows mounting the host filesystem inside a privileged container. It is not a harmless group, and on a shared server granting it is a security decision, not a convenience one.

---

## 13. Preflight checks

Verifying preconditions before an operation, rather than launching it and debugging the failure. This appears in deployment runbooks, backup scripts and restore procedures.

| Check | Command | Why |
|---|---|---|
| Correct directory | `pwd` | Compose looks for the file in the current directory |
| Clean repository | `git status` | Avoids mixing work from different sessions |
| Virtualenv active | `source .venv/bin/activate` | Without it, `pre-commit` is not on the PATH |
| Hooks working | `pre-commit run --all-files` | Two seconds that prevent surprises at commit time |
| Docker service running | `systemctl status docker` | Does not autostart on every distribution |
| Disk space | `df -h /` | A full disk produces confusing MongoDB failures |
| Free ports | `ss -tlnp \| grep -E '27017\|27018\|27019'` | A native MongoDB prevents the lab from starting |

---

## 14. Command reference

### Docker

```bash
docker ps                       # running containers
docker ps -a                    # including stopped ones
docker images                   # local images
docker volume ls                # volumes
docker network ls               # networks
docker logs <container>         # logs
docker inspect <container>      # full configuration as JSON
docker stats                    # live resource usage
docker rm -f <container>        # force removal
docker volume prune -f          # remove unused volumes
docker system df                # space used by Docker
```

### Docker Compose

```bash
docker compose config           # validate the YAML
docker compose up -d            # start in the background
docker compose ps -a            # status, including stopped
docker compose logs -f mongo1   # live logs
docker compose exec mongo1 mongosh --port 27017
docker compose stop mongo1      # graceful shutdown (SIGTERM)
docker compose kill mongo1      # abrupt failure (SIGKILL)
docker compose start mongo1
docker compose restart
docker compose down             # remove containers and network
docker compose down -v          # + volumes: DESTRUCTIVE
```

### MongoDB — replica set

```javascript
rs.initiate({...})              // initialise (once only)
rs.status()                     // full set status
rs.conf()                       // configuration
db.hello()                      // role of the current node
db.hello().primary              // who is primary
db.hello().isWritablePrimary    // does this node accept writes
rs.stepDown(60)                 // yield the primary role
rs.add("host:port")
rs.remove("host:port")
rs.printSecondaryReplicationInfo()
db.getReplicationInfo()         // oplog window
```

### MongoDB — general

```javascript
show dbs
use dbName
show collections
db.collection.insertOne({...})
db.collection.find()
db.collection.countDocuments()
db.serverStatus()
db.currentOp()                  // operations in flight
```

### System

```bash
ss -tlnp                        # listening ports
df -h /                         # disk space
systemctl status docker
ping -c1 mongo1
cat /etc/hosts
```

---

## 15. Glossary

| Term | Meaning |
|---|---|
| Replica set | A group of nodes holding the same data |
| Primary / secondary | Roles within the set |
| Failover | Automatic promotion after a failure |
| Election | The process of choosing a new primary |
| Majority / quorum | Minimum count required to decide |
| Split-brain | Two divergent primaries accepting writes |
| Heartbeat | Periodic liveness probe between nodes |
| Term | Monotonic election counter |
| Oplog | Replicable log of write operations |
| Oplog window | The timespan the oplog covers |
| Write concern | The acknowledgement guarantee demanded |
| Read preference | Which nodes reads are directed to |
| Replication lag | How far behind a secondary is |
| Catch-up | Applying outstanding operations before promotion |
| Rollback | Discarding writes that never reached a majority |
| Step down | A primary voluntarily relinquishing its role |
| Initial sync | A full copy from scratch |
| Volume | Persistent storage decoupled from the container |
| Image / container | Template / running instance |
| Publish a port | Expose a container port on the host |
| Preflight check | Validating preconditions before acting |
| Defence in depth | Layered security, no single layer sufficient |
| Toil | Manual, repetitive, automatable work |

---

## Further reading

- Replication manual: `mongodb.com/docs/manual/replication/`
- *MongoDB: The Definitive Guide* (Bradshaw, Brazil, Chodorow) — replication chapters
- Docker Compose documentation: `docs.docker.com/compose/`
- Raft consensus algorithm: `raft.github.io` — the interactive visualisation explains in five minutes what happens during an election

---

*Stage 1 completed · August 2026 · `mongo-ha-lab`*
