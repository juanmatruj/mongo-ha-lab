# ADR 0002 · Keyfile for internal authentication, TLS for transport

**Status:** Accepted
**Date:** 2026-09-02

---

## Context

MongoDB distinguishes two identity problems:

- **Client authentication** — who is connecting. Handled by SCRAM-SHA-256, a challenge-response mechanism in which the password never crosses the network.
- **Internal authentication** — whether a peer is a legitimate member of the replica set. Without it, anything reaching the network could join the cluster, receive full replication of the data, and vote in elections.

Two mechanisms exist for internal authentication: a shared keyfile, or X.509 certificates.

Separately, transport encryption is a distinct concern. Authentication protects credentials; it leaves the data itself in cleartext on the wire.

## Decision

**Keyfile for internal authentication.** A 756-byte base64 secret, identical on all three nodes, mounted read-only at `/etc/mongo/keyfile` with mode `400` and ownership `999:999`.

**TLS in `requireTLS` mode for transport**, using a project-local certificate authority, one certificate per node with SAN entries, and `--tlsAllowConnectionsWithoutCertificates` so that clients authenticate with credentials rather than certificates.

## Rationale

**Why keyfile over X.509 for internal auth.** For three nodes with a shared lifecycle, a single shared secret is simpler to reason about and to verify. X.509 for internal authentication introduces per-node certificate lifecycle management — issuance, distribution, expiry tracking, rotation — which is justified at scale but is overhead here.

The trade-off is real and worth naming: **a shared secret cannot be rotated per node.** Rotating the keyfile requires a coordinated rolling restart across all members, whereas X.509 allows replacing one node's credential independently. In a production cluster of meaningful size, X.509 is the better choice for exactly this reason.

**Why `--tlsAllowConnectionsWithoutCertificates`.** Setting `--tlsCAFile` makes MongoDB require client certificates by default — mutual TLS. That is a reasonable default for internal infrastructure, but it means every client needs an issued certificate and a distribution mechanism.

For this lab, encryption and server identity verification are the goals; client identity is already established by SCRAM. Nodes still present certificates to each other, so peer verification within the cluster is unaffected.

## Consequences

**Positive**

- Cluster membership cannot be forged without the keyfile.
- All traffic is encrypted; `requireTLS` rejects unencrypted connections outright.
- Clients verify server identity against the CA, preventing impersonation.
- The client certificate path remains available as an incremental hardening step.

**Negative**

- Keyfile rotation requires a coordinated restart of all members.
- The CA private key lives alongside the certificates it signs. In production it belongs in an HSM or a secrets manager; anyone holding it can issue certificates the cluster will trust.
- All three node certificates include `DNS:localhost` and `IP:127.0.0.1`, so they are interchangeable for that destination. This weakens per-node identity verification and is a direct consequence of co-locating nodes on one host.
- Certificates expire in 825 days with no renewal automation. Expiry is a classic cause of self-inflicted outages.

## Observed behaviour worth recording

Enabling `--tlsCAFile` without `--tlsAllowConnectionsWithoutCertificates` produced this sequence in the server log:

```
"Ingress TLS handshake complete"
"No SSL certificate provided by peer; connection rejected"
```

The handshake **completed successfully** — CA valid, server certificate valid, encryption established — and the connection was then rejected by authorization policy. The reported error code was `SSLHandshakeFailed`.

Read without the preceding line, that code points the investigation at certificates, SAN entries and the CA, all of which were correct. **An error code names the layer where a problem surfaces, not its cause.**

## Alternatives considered

**X.509 for internal authentication.** Correct for larger clusters and for environments requiring per-node credential rotation. Rejected here as disproportionate for three nodes.

**Mutual TLS with client certificates.** Stronger, and the production default for internal services. Deferred; the procedure is documented so it can be adopted without reconfiguring the servers.

**`preferTLS` instead of `requireTLS`.** Would allow unencrypted fallback. Rejected: the four TLS modes (`disabled`, `allowTLS`, `preferTLS`, `requireTLS`) exist to enable staged migration of a live cluster without downtime, not as a permanent posture. This lab starts from a clean state, so there is nothing to migrate.

**`--tlsAllowInvalidCertificates` on the client.** Frequently suggested online as a fix for certificate errors. It disables verification entirely: traffic is encrypted, but to an unverified party. This defeats the purpose of TLS and is explicitly rejected.
