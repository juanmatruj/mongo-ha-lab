# ADR 0001 · Symmetric port publishing

**Status:** Accepted
**Date:** 2026-08-17

---

## Context

The lab runs three `mongod` processes as containers on a single host. Replica set members identify each other by hostname, and the addresses recorded in the cluster configuration are returned to clients, which then reconnect using them.

The initial configuration had all three nodes listening internally on port 27017, published to the host on 27017, 27018 and 27019:

```yaml
mongo2:  ports: ["27018:27017"]
```

The replica set was initialised with `mongo1:27017`, `mongo2:27017`, `mongo3:27017`. This is valid inside the Docker network, where each service name resolves to its own container IP.

From the host, however, `/etc/hosts` maps all three names to `127.0.0.1`. The three advertised addresses therefore collapsed into `127.0.0.1:27017` — always mongo1.

The cluster worked for as long as mongo1 happened to be primary. Stopping that node produced persistent `ECONNREFUSED` errors from the external client, even for reads, while the internal election completed correctly.

## Decision

Each `mongod` listens on its own port, published with the same number on the host:

```yaml
mongo1:  command: [..., "--port", "27017"]   ports: ["27017:27017"]
mongo2:  command: [..., "--port", "27018"]   ports: ["27018:27018"]
mongo3:  command: [..., "--port", "27019"]   ports: ["27019:27019"]
```

A single address is then valid from inside the Docker network and from the host.

## Consequences

**Positive**

- Failover works correctly from external clients.
- One connection string works everywhere; no environment-specific variants.
- Eliminates an entire class of divergent-resolution faults.

**Negative**

- Diverges from production layouts, where each node has its own machine and address and all use 27017. The conflict only exists when co-locating nodes on one host.
- Introduces an external dependency on `/etc/hosts` entries, which must be documented as a prerequisite.
- Applying the change required destroying volumes and re-running `rs.initiate()`, since member ports are part of the replica set configuration.

## Alternatives considered

**Run all clients inside the Docker network.** Sidesteps the problem entirely, but removes the ability to operate the cluster from the host — which is the skill the lab exists to practise.

**Distinct loopback addresses per node** (`127.0.0.2`, `127.0.0.3`) while keeping port 27017. Works on Linux, but is more obscure and not portable to macOS.

**Three virtual machines with real addresses.** Faithful to production, disproportionate for a lab.

## Notes

The underlying lesson outlived the fix. The system behaved correctly for a period **by coincidence**, and the defect surfaced only when one specific node failed — that is, during an incident, when diagnostic capacity is lowest and impact highest.

This is the operational argument for exercising recovery mechanisms deliberately and regularly rather than waiting to need them.
