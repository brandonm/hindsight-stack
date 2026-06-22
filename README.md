# hindsight-stack

Self-hosted [Hindsight](https://github.com/vectorize-io/hindsight) memory server for
[Hermes Agent](https://github.com/NousResearch/hermes-agent), wired to **your own**
embedding + chat endpoints and a dedicated **VectorChord** Postgres — no third-party cloud.

It runs Hermes' semantic memory on a 4096-dim Qwen3-Embedding-8B model and keeps every
byte on your infrastructure.

## Architecture

```
Hermes Agent ──(memory provider, mode: local_external)──▶ hindsight  :8888  (web UI :9999)
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
cp .env.example .env       # then EDIT it — placeholder URLs boot fine but fail at the first LLM/embed call
make up                    # build + start (or: docker compose up -d --build)
make smoke                 # validate end-to-end (needs jq)
```

`make smoke` should print `failed_operations: 0` at the stats step and end with a non-empty `recall` result.

## Configuration (`.env`)

| Var | What |
|-----|------|
| `POSTGRES_PASSWORD` | Hindsight DB password. **URL-safe** — it goes into a `postgresql://` URL. |
| `EMBEDDINGS_BASE_URL` | Your `/v1` embeddings endpoint (Qwen3-Embedding-8B). **Include `/v1`.** |
| `EMBEDDINGS_MODEL` | Embedding model id (default `qwen3-embedding-8b`). |
| `EMBEDDINGS_API_KEY` | Any non-empty string if your backend ignores auth. |
| `LLM_UPSTREAM_BASE_URL` | Chat host **root, no `/v1`** (the proxy adds the path). |
| `LLM_MODEL` | Chat model id (default `qwen3.6-35b-a3b`). |
| `HINDSIGHT_IMAGE` / `VCHORD_IMAGE` | Image pins — bump to update. |

## Wire up Hermes Agent

On the Hermes host:

```bash
hermes config set memory.provider hindsight
```
then in `~/.hermes/config.yaml`:
```yaml
memory:
  provider: hindsight
  hindsight:
    mode: local_external           # run our own server (not Hindsight cloud)
    api_url: "http://<this-box-ip>:8888"
    bank_id: hermes
```

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
init/01-vchord.sql      CREATE EXTENSION vchord CASCADE (runs on first DB init)
nothink-proxy/          FastAPI proxy that disables Qwen3 thinking
scripts/smoke.sh        end-to-end validation
Makefile                common ops — run `make help` to list targets
```
