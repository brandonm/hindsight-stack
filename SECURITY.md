# Security

## Why this matters

This stack stores **personal agent memory** — facts derived from your conversations with
Hermes (habits, plans, relationships, health, finances, anything you mention in passing).
And it has an awkward shape: Hermes runs on a **different host**, so the Hindsight API on
`:8888` **must be reachable off-box** — `localhost`-only binding isn't an option.

Two facts make that dangerous out of the box:

1. **Hindsight ships unauthenticated.** Its own docs say verbatim *"By default, Hindsight runs
   without authentication."* Anyone who can reach `:8888` gets full CRUD on every memory bank.
2. **The scariest threat isn't theft — it's poisoning.** An attacker can `POST .../memories`
   to inject false "facts" that your agent then treats as **trusted truth** and acts on. Quietly
   corrupting memory is lower-effort and higher-impact than reading it, and far harder to notice.

There's a third twist: `PATCH .../banks/{id}/config` lets a caller **repoint a bank's LLM
`base_url`** at a server they control — turning your memory server into an outbound exfiltration
channel that ships extracted facts (and the forwarded auth header) to them.

So "it's only on my LAN" is not safe enough: a guest device, an IoT gadget, or one compromised
machine on the network is all it takes. This repo therefore defaults to **auth-on**.

## Threat model (LAN-deployed, single user)

| Threat | Impact | Primary control |
|---|---|---|
| **Exfiltration** — list/recall all memory | Privacy breach of sensitive personal data | Bearer-token auth |
| **Poisoning** — inject false memories | Agent acts on attacker-planted "facts" | Bearer-token auth |
| **Destruction** — delete/invalidate memories | Data loss | Auth + backups |
| **Config repoint (SSRF/exfil)** — `PATCH …/config` | Memory + auth header sent to attacker | Auth + egress restriction |
| **Sniffing** — plaintext HTTP between hosts | Reads payloads and steals the bearer key | TLS, or an encrypted tunnel (Tailscale/WG) |
| **Admin UI** — open `:9999` control plane | Management surface over the same data | UI not published by default |

`nothink-proxy` was reviewed and is **not** an SSRF/open-proxy risk: it only ever appends the
request path to a fixed `UPSTREAM_BASE_URL`, runs as `nobody`, and is never host-exposed.

## What this repo does for you (secure-by-default)

- ✅ **Bearer auth required.** `HINDSIGHT_API_TENANT_API_KEY` is wired to `${HINDSIGHT_API_KEY}`
  with a fail-fast guard — `make up` refuses to start until you set it. Every API call then needs
  `Authorization: Bearer <key>` or gets 401.
- ✅ **Admin UI (`:9999`) not published.** It's commented out in `docker-compose.yml`; the API
  (`:8888`) is all Hermes needs.
- ✅ **Image pinned** to a fixed tag (`hindsight:0.8.3`), not the mutable `:latest`.
- ✅ **DB never host-exposed**; `.env` gitignored; only `.env.example` placeholders are tracked.
- ✅ **`BIND_ADDR`** lets you serve `:8888` on one interface (e.g. your Tailscale IP) instead of all.

## What you must still do (operator actions)

1. **Set a strong key.** `HINDSIGHT_API_KEY=$(openssl rand -hex 32)` in `.env` on the Hindsight
   host, and the **same** value on the Hermes side (memory-provider `api_key`).
2. **Isolate the network — recommended: Tailscale/WireGuard** between the two hosts, then set
   `BIND_ADDR` to the tailnet IP so `:8888` isn't on the open LAN at all. The tunnel also encrypts
   the link, which solves the plaintext-HTTP problem for free.
   - *Cheaper alternative:* a host firewall (`ufw`/`nftables`) default-deny on `:8888`, allow only
     the Hermes host's IP. Effective but IP-spoofable on a shared LAN and breaks if the IP changes.
   - *Don't rely on the LAN being "trusted."* App auth + network isolation are complementary.
3. **Use TLS if not tunneling.** Put Caddy in front of `:8888` (auto-HTTPS) and point Hermes at
   `https://` — otherwise the bearer key crosses the network in cleartext.
4. **Back up.** `make backup` (gzipped `pg_dump`). Keep copies off-box.
5. **Rotate the key** if either host is ever suspect. The key is a single shared secret — fine for
   one user/one client, but it's as sensitive as the data; store it only in gitignored `.env`.
6. *(Defense-in-depth, optional)* restrict the Hindsight container's **egress** to your known
   embedding/chat endpoints so a config-repoint can't reach an arbitrary host even if auth were
   bypassed; add `security_opt: ["no-new-privileges:true]"` to the services.

## Verify it's actually locked

```bash
# from the Hermes host (or anywhere that can reach :8888):
curl -s -o /dev/null -w '%{http_code}\n' http://<box>:8888/v1/default/banks      # expect 401/403
curl -s -H "Authorization: Bearer $HINDSIGHT_API_KEY" http://<box>:8888/v1/default/banks  # expect 200
make smoke   # runs the auth-enforced end-to-end check (HINDSIGHT_API_KEY must be set)
```

## Wiring the key into Hermes

In `~/.hermes/config.yaml`, the hindsight provider must send the bearer token:

```yaml
memory:
  provider: hindsight
  hindsight:
    mode: local_external
    api_url: "https://<box>:8888"   # https if you front it with TLS; http only inside a VPN tunnel
    api_key: "${HINDSIGHT_API_KEY}"  # same value as on the Hindsight host
    bank_id: hermes
```

## Not access control

Hindsight's **Memory Defense** (regex secret/PII scrubbing on store) is content sanitization, not
authentication — useful as belt-and-suspenders so stray secrets aren't persisted, but it does not
authorize anyone. Don't count it toward the controls above.

## Reporting

This is a personal/solo deployment. If you find an issue in the upstream projects, report to
[vectorize-io/hindsight](https://github.com/vectorize-io/hindsight) or
[tensorchord/VectorChord](https://github.com/tensorchord/VectorChord).
