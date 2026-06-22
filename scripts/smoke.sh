#!/usr/bin/env bash
# End-to-end validation of the Hindsight stack: auth enforced -> dry-run extract (LLM path)
# -> store -> stats -> recall (vchord 4096 index). Requires `jq` and HINDSIGHT_API_KEY.
#
# Usage: HINDSIGHT_API_KEY=... ./scripts/smoke.sh
#        HINDSIGHT_HOST=http://box:8888 BANK=test HINDSIGHT_API_KEY=... ./scripts/smoke.sh
set -euo pipefail

HOST="${HINDSIGHT_HOST:-http://localhost:8888}"
BANK="${BANK:-smoke}"
KEY="${HINDSIGHT_API_KEY:?set HINDSIGHT_API_KEY (the same bearer token the server enforces)}"
AUTH=(-H "Authorization: Bearer ${KEY}")
TEXT="Ada uses a VectorChord-backed Hindsight for agent memory."

echo "== health =="; curl -fsS "$HOST/health"; echo

echo "== auth enforced? (a request with NO token must be rejected) =="
code=$(curl -s -o /dev/null -w '%{http_code}' "$HOST/v1/default/banks")
if [ "$code" = "401" ] || [ "$code" = "403" ]; then
  echo "OK: unauthenticated request rejected ($code)"
else
  echo "WARNING: expected 401/403 without a token, got $code — auth may be OFF. Stop and check."
fi

echo "== dry-run extract (exercises the chat LLM, no persistence) =="
curl -fsS "${AUTH[@]}" -X POST "$HOST/v1/default/banks/$BANK/memories/dry-run-extract" \
  -H 'Content-Type: application/json' -d "{\"content\":\"$TEXT\"}" | jq '{facts, usage}'

echo "== store (retain) =="
curl -fsS "${AUTH[@]}" -X POST "$HOST/v1/default/banks/$BANK/memories" \
  -H 'Content-Type: application/json' \
  -d "{\"items\":[{\"content\":\"$TEXT\",\"timestamp\":\"unset\"}]}" | jq

echo "== stats (expect total_nodes>0, failed_operations=0) =="
curl -fsS "${AUTH[@]}" "$HOST/v1/default/banks/$BANK/stats" \
  | jq '{total_nodes, total_documents, pending_operations, failed_operations}'

echo "== recall (hits the vchord 4096 index) =="
curl -fsS "${AUTH[@]}" -X POST "$HOST/v1/default/banks/$BANK/memories/recall" \
  -H 'Content-Type: application/json' \
  -d '{"query":"What does Ada use for memory?"}' | jq '.results'
