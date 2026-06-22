"""Transparent OpenAI-compatible reverse proxy that disables Qwen3 "thinking".

Hindsight's LLM client exposes no way to pass chat_template_kwargs, and Qwen3.6
ignores --reasoning-budget, so the only working lever is the per-request body flag
chat_template_kwargs={"enable_thinking": false} (verified on llama.cpp build b9628).

This proxy injects that flag into every /v1/chat/completions request and forwards
everything else (and all other paths) unchanged. Point HINDSIGHT_API_LLM_BASE_URL at
http://nothink-proxy:8000/v1; set UPSTREAM_BASE_URL to your chat host ROOT (no /v1).
"""

import json
import logging
import os
from contextlib import asynccontextmanager

import httpx
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, StreamingResponse

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("nothink-proxy")

UPSTREAM = os.environ["UPSTREAM_BASE_URL"].rstrip("/")  # host root, no /v1
TIMEOUT = float(os.environ.get("PROXY_TIMEOUT", "600"))

client = httpx.AsyncClient(timeout=httpx.Timeout(TIMEOUT))


@asynccontextmanager
async def lifespan(app: FastAPI):
    yield
    await client.aclose()  # close pooled connections on shutdown


app = FastAPI(lifespan=lifespan)


@app.get("/healthz")
async def healthz():
    return {"ok": True, "upstream": UPSTREAM}


@app.api_route("/{path:path}", methods=["GET", "POST", "PUT", "PATCH", "DELETE"])
async def proxy(path: str, request: Request):
    body = await request.body()

    # Only touch chat completions; everything else passes straight through.
    if request.method == "POST" and path.endswith("/chat/completions"):
        try:
            data = json.loads(body or b"{}")
            kwargs = data.get("chat_template_kwargs") or {}
            kwargs["enable_thinking"] = False  # merge, don't clobber other keys
            data["chat_template_kwargs"] = kwargs
            body = json.dumps(data).encode()
        except (json.JSONDecodeError, ValueError, UnicodeDecodeError):
            # Non-JSON or compressed body: forward unchanged, but stay observable —
            # silently dropping the flag would defeat the proxy's only job.
            log.warning(
                "enable_thinking NOT injected: unparseable chat body (content-encoding=%s)",
                request.headers.get("content-encoding"),
            )

    fwd_headers = {
        k: v
        for k, v in request.headers.items()
        if k.lower() not in ("host", "content-length", "connection")
    }
    try:
        upstream = await client.send(
            client.build_request(
                request.method,
                f"{UPSTREAM}/{path}",
                content=body,
                headers=fwd_headers,
                params=request.query_params,
            ),
            stream=True,
        )
    except httpx.TimeoutException as exc:
        log.warning("upstream timeout: %s", exc)
        return JSONResponse(
            status_code=504,
            content={"error": {"message": f"upstream timeout: {exc}", "type": "upstream_timeout"}},
        )
    except httpx.HTTPError as exc:
        # Expected whenever llama-swap is cold-loading/swapping the model.
        log.warning("upstream request failed: %s", exc)
        return JSONResponse(
            status_code=502,
            content={"error": {"message": f"upstream request failed: {exc}", "type": "upstream_error"}},
        )

    async def body_iter():
        try:
            async for chunk in upstream.aiter_raw():
                yield chunk
        finally:
            await upstream.aclose()

    # content-type (and content-encoding) ride along in resp_headers.
    resp_headers = {
        k: v
        for k, v in upstream.headers.items()
        if k.lower() not in ("content-length", "transfer-encoding", "connection")
    }
    return StreamingResponse(
        body_iter(),
        status_code=upstream.status_code,
        headers=resp_headers,
    )
