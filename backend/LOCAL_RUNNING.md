# Current local setup

The backend's ignored `.env` selects local Ollama on `127.0.0.1:11434`,
`bge-m3:latest` embeddings, and `gemma3:4b` free-tier chat. Single-page Docling
standard parsing uses downloaded artifacts under `var/parser-models` and English
Tesseract OCR. Kimi paid-tier chat has not been provisioned and fails closed.
Do not substitute a different model for paid accounts.

The API/worker supervisor is running with `BIND_HOST=127.0.0.1`, port 10000.
Ollama is also loopback-only. Only Flask is exposed through the temporary
Cloudflare HTTPS tunnel; never tunnel port 11434. HTTPS traffic passes through
Cloudflare, while PDF parsing, embeddings and model generation run on this Mac.
Application authentication still protects private routes. Quick tunnels are for
local development, not a production uptime guarantee.

Runtime logs/PIDs are in ignored `backend/var/runtime/`:
`api.log`, `api.pid`, `tunnel.log`, `tunnel.pid`. Logs contain operational messages;
do not add private prompt/body logging. The current tunnel URL is recorded in the
ignored development config and public debug default asset in `mobile/config/`.
No credentials are stored in mobile configuration.

Keep this Mac awake, Ollama running, and the API/worker/tunnel processes active.
Local account/database records are separate from the Render demo; create/sign in
to an account on the local backend. Existing Render PDFs were not migrated.

To restart manually from `backend/`:

```sh
.venv/bin/python -m chatpdf.serve
# In a second terminal:
cloudflared tunnel --url http://127.0.0.1:10000 --no-autoupdate
```

Do not start duplicates while the existing processes are running. A restarted quick
tunnel gets a new hostname. Update both mobile development configurations and
rebuild/reinstall the Android app when that changes. No paid hosting or inference
provider was enabled. Persist/back up the local database and PDF directory together.

The local macOS supervisor uses Waitress to avoid native-library fork failures.
Linux/Render retains Gunicorn. Grounded chat requests JSON-formatted model output
so the server can validate exact source citations.
