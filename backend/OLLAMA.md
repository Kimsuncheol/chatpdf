# Server-side chat models and entitlements

`model_policy.ModelPolicy` reads the active account from SQLite on every selection.
JWTs identify accounts; JWT claims, headers, query parameters and request-body tiers
or model names do not grant access. No plan is cached in the chat service.

| Server record | Chat access |
| --- | --- |
| `free` | Only `GEMMA_MODEL_TAG` |
| `paid`, future timezone-aware `subscription_expires_at` | Only `KIMI_MODEL_TAG` |
| `paid`, expired/missing/invalid expiry | Denied with `subscription_expired` |
| Disabled/missing account | Denied with `unauthorized` |

Expired paid accounts are not silently downgraded. Support can renew them or
explicitly set them to free. Migration to schema 4 preserves all records and adds
a nullable expiry column; existing paid rows without an expiry need provisioning.
Free accounts do not require an expiry. Expiry is compared against current UTC time,
including before an answer is released; it is not the JWT/session expiry.

## Configuration and model verification

In `backend/.env`, configure these **server-only** values:

```dotenv
OLLAMA_BASE_URL=http://127.0.0.1:11434
OLLAMA_API_KEY=
GEMMA_MODEL_TAG=
KIMI_MODEL_TAG=
OLLAMA_CHAT_TIMEOUT=120
OLLAMA_CHAT_MAX_TOKENS=1024
OLLAMA_CHAT_MAX_INPUT_CHARS=60000
```

Fill both model variables with exact installed `name:tag` identifiers for your
chosen Gemma and Kimi variants. They must differ. There is deliberately no guessed
Kimi tag, automatic model download, model substitution or paid-to-free fallback.
Administrators are responsible for provisioning the correct family/weights under
each configured tag; an alias or renamed local tag does not prove a model's origin.
Model tags identify access entitlements, not a guarantee about hardware suitability.
Use a trusted private Ollama host; Flutter receives neither its URL nor credentials.
The embedding model configuration is independent of these chat entitlements.

On the backend machine, inspect `/api/tags` on the configured `OLLAMA_BASE_URL` or
use Ollama's CLI against that same host to list/install the intended models. Do not
accidentally verify a different local Ollama instance. The app provides a command
that uses the same environment/host/credentials as its service:

```sh
cd backend
.venv/bin/flask --app chatpdf:create_app verify-ollama-models
# Additionally load both models and run a fixed, nonprivate generation prompt:
.venv/bin/flask --app chatpdf:create_app verify-ollama-models --generate
```

Verification requires exact matches in `/api/tags`, then checks `/api/show` for
completion capability. `--generate` also confirms both models can generate on this
deployment; it may take time and significant memory. Neither command pulls models
or changes account records. Missing configuration/models produce a nonzero exit
with a safe actionable message. Restart app processes after changing environment
settings. Remote/cloud Ollama configurations send supplied text to that service;
use a private local host if your deployment requires local-only processing.

## Administrative account provisioning

No payment processing or client-accessible plan-update endpoint is implemented.
Only trusted backend administrators should run these commands:

```sh
.venv/bin/flask --app chatpdf:create_app set-subscription \
  --email reader@example.com --tier paid --expires-at '2030-01-01T00:00:00Z'
.venv/bin/flask --app chatpdf:create_app set-subscription \
  --email reader@example.com --tier free
```

Paid expirations must be in the future and include a timezone; free clears expiry.
Choose the actual authorized end date. Changes apply to subsequent selections even
when the user continues using the same access token.

## Authenticated entitlements API

`GET /api/v1/auth/entitlements` requires the normal bearer token and returns:

```json
{
  "tier": "free",
  "subscription_status": "active",
  "subscription_expires_at": null,
  "entitlements": {
    "chat": true,
    "model_family": "gemma",
    "allowed_models": ["your-configured-gemma:tag"],
    "unavailable_reason": null
  }
}
```

The example tag is illustrative; the API returns the actual configured tag.
Expired paid accounts return their stored tier `paid`, status `expired`, no allowed
models, `chat=false`, and reason `subscription_expired`. Unconfigured chat returns
`chat=false`/`model_not_configured`. Authorization is reported without contacting
Ollama; this endpoint is not a model-health check. Client model/tier parameters and
headers are ignored. Responses are `Cache-Control: no-store`. `/auth/me` retains
its existing account/profile contract; use `/entitlements` for effective chat access.

## Service integration and safe errors

An authenticated, document-owning answer service can call:

```python
from flask import g
from chatpdf.ollama_chat import OllamaChatService

# Messages must be built on the server from the selected owned PDF's retrieved
# evidence, citation instructions and bounded history, after ownership checks.
answer = OllamaChatService().chat(g.user['id'], messages)
```

The service accepts no model, tier, arbitrary Ollama options, tools or image inputs.
It selects the model afresh, makes one bounded nonstreaming request, and rechecks
the account after generation to catch expiry, disablement or a plan change. It
validates the response's model tag and completion before releasing text. It never
retries against another model. HTTP redirects and environment proxy inheritance
are disabled for this transport. Timeout is a connect/read/write timeout; configure
the WSGI/gateway request deadline consistently for these nonstreaming calls.

This is a low-level chat-model service, not an ungrounded public chat endpoint.
It does not itself retrieve PDFs, claim citation grounding or save conversation
messages. Future answer routes should allowlist their request fields and pass only
server-built messages, never forward arbitrary client JSON to the Ollama SDK.

| HTTP | Code | Action |
| --- | --- | --- |
| 401 | `unauthorized` | Sign in; inactive accounts require support |
| 403 | `subscription_expired` | Renew or have support switch to free |
| 409 | `entitlements_changed` | Retry after an in-flight plan change |
| 503 | `model_not_configured` | Administrator configures host/exact tag |
| 503 | `model_missing` | Administrator installs/verifies configured tag |
| 503 | `ollama_unavailable` | Retry; administrator checks service/auth/capacity |
| 504 | `model_timeout` | Retry a shorter request; administrator checks capacity |
| 503 | `model_response_invalid` | Retry; administrator reviews model compatibility |

Provider exception bodies, private prompts/PDF content, responses, URLs, keys and
tracebacks are not logged or copied into these errors. Do not enable HTTP body
debugging, Flask interactive debugging or prompt tracing in production; secure
Ollama's own logs separately. The SDK transport avoids LangChain tracing hooks.

Ollama references: [chat API](https://docs.ollama.com/api/chat),
[model listing](https://docs.ollama.com/api/tags),
[Python client](https://github.com/ollama/ollama-python).
