# hindsight-stack

[![CI](https://github.com/brandonm/hindsight-stack/actions/workflows/ci.yml/badge.svg)](https://github.com/brandonm/hindsight-stack/actions/workflows/ci.yml)

Self-hosted [Hindsight](https://github.com/vectorize-io/hindsight) memory server for
[Hermes Agent](https://github.com/NousResearch/hermes-agent), wired to **your own**
embedding + chat endpoints and a dedicated **VectorChord** Postgres — no third-party cloud.

It runs Hermes' semantic memory on a 4096-dim Qwen3-Embedding-8B model and keeps every
byte on your infrastructure.

## Architecture

```
Hermes Agent ──(bearer-authed, mode: local_external)──▶ hindsight  :8888  (admin UI :9999 opt-in)
                                                            │
   embeddings ──▶ your llama-swap  /v1/embeddings  (Qwen3-Embedding-8B, 4096-dim)
   chat LLM   ──▶ nothink-proxy ──▶ your chat model /v1   (thinking disabled per-request)
   storage    ──▶ hindsight-db  (Postgres + VectorChord, its own volume)
```

Three containers (this repo): **hindsight**, **hindsight-db** (VectorChord), **nothink-proxy**.
Two endpoints **you** provide: an OpenAI-compatible `/v1/embeddings` and `/v1/chat/completions`.

## Why these pieces (the non-obvious bits)

- **VectorChord, not plain pgvector.** pgvector's HNSW index caps at **2000 dimensions**;
  Qwen3-Embedding-8B emits **4096**, so a vanilla `pgvector/pgvector` image fails on boot with
  `Embedding dimension 4096 ... exceeds pgvector HNSW index limit of 2000`. VectorChord indexes to
  60k dims. `HINDSIGHT_API_VECTOR_EXTENSION=vchord` + `shared_preload_libraries=vchord`.
- **The no-think proxy.** Qwen3.6 has thinking on by default and **ignores `--reasoning-budget 0`**;
  the only working off-switch is the request-body flag `chat_template_kwargs.enable_thinking=false`.
  Hindsight can't pass that, so a tiny proxy injects it. Without it, every fact-extraction call
  burns ~1.5–2.3k reasoning tokens (~10s/retain); with it, ~1–2s.
- **`LLM_UPSTREAM_BASE_URL` omits `/v1`** (the proxy receives it as `UPSTREAM_BASE_URL`). Hindsight calls
  `…/nothink-proxy:8000/v1/chat/completions`; the proxy mirrors that whole path onto the upstream host
  root. Putting `/v1` in `LLM_UPSTREAM_BASE_URL` gives a doubled `/v1/v1/...` 404.

## Quick start

```bash
cp .env.example .env
# Edit .env — at minimum:
#   HINDSIGHT_API_KEY   ->  openssl rand -hex 32   (REQUIRED — Hindsight is unauthenticated by default)
#   POSTGRES_PASSWORD, EMBEDDINGS_BASE_URL, LLM_UPSTREAM_BASE_URL, model ids
make up   # refuses to start until HINDSIGHT_API_KEY is set
HINDSIGHT_API_KEY="$(grep -E '^HINDSIGHT_API_KEY=' .env | cut -d= -f2-)" make smoke   # auth-enforced e2e (needs jq)
```

`make smoke` confirms auth is enforced (401 without a token), prints `failed_operations: 0`, and ends with a
non-empty `recall`.

> ⚠️ **Read [SECURITY.md](SECURITY.md) before exposing this.** The API serves personal memory and is
> unauthenticated by default; this repo turns auth on, but **you** must still set a strong key and isolate
> the network (the API must be reachable from the Hermes host but nothing else).

## Configuration (`.env`)

| Var | What |
|-----|------|
| `HINDSIGHT_API_KEY` | **REQUIRED.** Bearer token enforced on every API call. `openssl rand -hex 32`. Same value on the Hermes side. |
| `POSTGRES_PASSWORD` | Hindsight DB password. **URL-safe** — it goes into a `postgresql://` URL. |
| `EMBEDDINGS_BASE_URL` | Your `/v1` embeddings endpoint (Qwen3-Embedding-8B). **Include `/v1`.** |
| `EMBEDDINGS_MODEL` | Embedding model id (default `qwen3-embedding-8b`). |
| `EMBEDDINGS_API_KEY` | Any non-empty string if your backend ignores auth. |
| `LLM_UPSTREAM_BASE_URL` | Chat host **root, no `/v1`** (the proxy adds the path). |
| `LLM_MODEL` | Chat model id (default `qwen3.6-35b-a3b`). |
| `BIND_ADDR` | *(optional)* Interface to bind `:8888` to (e.g. your Tailscale IP). Unset = all interfaces. |
| `HINDSIGHT_CP_ACCESS_KEY` | *(optional)* Admin-UI key — only if you publish `:9999` (off by default). |
| `HINDSIGHT_IMAGE` / `VCHORD_IMAGE` | Image pins (default `hindsight:0.8.3`) — bump deliberately. |

## Wire up Hermes Agent

On the Hermes host:

```bash
hermes config set memory.provider hindsight
```
settings go in `~/.hermes/config.yaml`:
```yaml
memory:
  provider: hindsight
  hindsight:
    mode: local_external               # run our own server (not Hindsight cloud)
    api_url: "https://<this-box-ip>:8888"  # https if fronted by TLS; http only inside a VPN tunnel
    bank_id: hermes
```
and the bearer token — a secret — goes in `~/.hermes/.env` (the plugin reads `HINDSIGHT_API_KEY`
directly and sends `Authorization: Bearer <key>` in every mode; verified in the plugin source):
```bash
# ~/.hermes/.env
HINDSIGHT_API_KEY=<the SAME value as the server's HINDSIGHT_API_KEY>   # or every call 401s
```

## Security

The Hindsight API serves **personal memory** and is **unauthenticated by default** — and because
Hermes is on another host, `:8888` has to be reachable off-box. This repo defaults to **auth-on**
(`make up` won't start without `HINDSIGHT_API_KEY`), keeps the admin UI unpublished, and pins the
image. **You still must** set a strong key on both ends and isolate the network (Tailscale/WireGuard
recommended, or a firewall allowlist). The sneaky risk isn't theft but **memory poisoning** — planted
"facts" your agent later trusts. Full threat model, findings, and the hardening checklist are in
**[SECURITY.md](SECURITY.md)** — read it before exposing the port.

## Operations

```bash
make logs       # follow hindsight logs
make config     # `docker compose config` sanity check
make backup     # pg_dump -> hindsight-<date>.sql.gz
make wipe       # ⚠️ down -v: deletes the DB volume (see below)
```

**Updating:** bump `HINDSIGHT_IMAGE` / `VCHORD_IMAGE` in `.env` (or `docker compose pull`), then `make up`.

**Re-initialising:** Hindsight fixes the embedding **dimension and vector extension at
schema-creation time** and can't change them in place. To switch embedding models/dims or the
extension, `make wipe` (drops the volume) and start fresh — existing memories are lost, so
`make backup` first.

## Layout

```
docker-compose.yml      three services, all config via ${...} from .env
.env.example            copy to .env
SECURITY.md             threat model + hardening checklist — read before exposing
init/01-vchord.sql      CREATE EXTENSION vchord CASCADE (runs on first DB init)
nothink-proxy/          FastAPI proxy that disables Qwen3 thinking
scripts/smoke.sh        auth-enforced end-to-end validation
Makefile                common ops — run `make help` to list targets
```
