#!/usr/bin/env bash
# End-to-end validation of the Hindsight stack: health -> dry-run extract (LLM path)
# -> store -> stats -> recall (vchord 4096 index). Requires `jq`.
#
# Usage: ./scripts/smoke.sh            (defaults to http://localhost:8888, bank "smoke")
#        HINDSIGHT_HOST=http://box:8888 BANK=test ./scripts/smoke.sh
set -euo pipefail

HOST="${HINDSIGHT_HOST:-http://localhost:8888}"
BANK="${BANK:-smoke}"
TEXT="Ada uses a VectorChord-backed Hindsight for agent memory."

echo "== health ==";                curl -fsS "$HOST/health"; echo

echo "== dry-run extract (exercises the chat LLM, no persistence) =="
curl -fsS -X POST "$HOST/v1/default/banks/$BANK/memories/dry-run-extract" \
  -H 'Content-Type: application/json' -d "{\"content\":\"$TEXT\"}" | jq '{facts, usage}'

echo "== store (retain) =="
curl -fsS -X POST "$HOST/v1/default/banks/$BANK/memories" \
  -H 'Content-Type: application/json' \
  -d "{\"items\":[{\"content\":\"$TEXT\",\"timestamp\":\"unset\"}]}" | jq

echo "== stats (expect total_nodes>0, failed_operations=0) =="
curl -fsS "$HOST/v1/default/banks/$BANK/stats" \
  | jq '{total_nodes, total_documents, pending_operations, failed_operations}'

echo "== recall (hits the vchord 4096 index) =="
curl -fsS -X POST "$HOST/v1/default/banks/$BANK/memories/recall" \
  -H 'Content-Type: application/json' \
  -d '{"query":"What does Ada use for memory?"}' | jq '.results'
