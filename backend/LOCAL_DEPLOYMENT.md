# Local deployment and operations

## Network boundary

**Ollama must be reachable only from the backend network, never directly from
Flutter. Never put the Ollama URL or credentials in mobile configuration, expose
port 11434 to mobile clients, or proxy Ollama routes through the public API.**

Run Ollama on backend loopback when colocated, or use a backend-only private network
with firewall rules allowing only backend machines. If multiple machines require
transport protection, put authenticated TLS inside that restricted network. TLS
and API keys do not replace source-network restrictions. Flutter receives only the
Flask HTTPS base URL. Database files, PDF storage and parser artifacts are private.
See the [official Ollama network configuration FAQ](https://docs.ollama.com/faq).

## Native setup

Prerequisites: Python 3.12+ (development checked on 3.14), Flutter SDK matching
`mobile/README.md`, Ollama on the backend host, and a POSIX OS with symlink-safe
file removal. Docker is an alternative below. Install Tesseract and its language
packs only when using Tesseract OCR; no OCR executable is required when OCR is off.

```sh
cd backend
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
cp .env.example .env
# Generate a unique signing secret, then save it privately as JWT_SECRET_KEY in .env:
.venv/bin/python -c 'import secrets; print(secrets.token_hex(48))'
chmod 600 .env
```

Set the actual model tags as described in [Ollama setup](OLLAMA.md). The example
intentionally leaves chat tags and signing secrets empty; it is not runnable until
configured. Keep the same signing secret across restarts. Changing it invalidates
existing tokens. Do not commit `.env`, `.venv`, databases, PDFs or model credentials.

```sh
# Download only parser models used by the standard pipeline:
.venv/bin/docling-tools models download layout tableformer --output-dir var/parser-models
.venv/bin/python -m chatpdf.e5_local download var/e5-model
# Set DOCLING_ARTIFACTS_PATH to that directory's absolute path in .env.
.venv/bin/flask --app chatpdf:create_app verify-ollama-models --generate
.venv/bin/flask --app chatpdf:create_app create-user --email reader@example.com
```

Passwords are prompted privately and hashed. Registration is available through `/api/v1/auth/register`; email reset delivery is not implemented. The
administrative paid-plan command is documented in `OLLAMA.md`; no payment processing
is installed. A local Llama 3.1-only trial can use a free account before provisioning
Kimi, but the two-model verification command requires both tags to be configured.

For development, run each in a separate terminal with the same `backend/` directory
and `.env` (Flask CLI loads it automatically):

```sh
.venv/bin/flask --app chatpdf:create_app run --host 127.0.0.1 --port 5000
.venv/bin/flask --app chatpdf:create_app ingestion-worker
```

For a supervised deployment on one host, use instead:

```sh
PORT=10000 .venv/bin/python -m chatpdf.serve
```

The supervisor loads `.env` without overriding existing process variables, creates
schema/storage, and starts independent WSGI and durable-worker processes (Waitress on macOS; Gunicorn on Linux). Do
not run another worker by accident when using this command. It binds `0.0.0.0`;
restrict this backend port with host/firewall rules and expose only the HTTPS proxy.
Gunicorn uses one process/four threads and a 180-second timeout. On child failure,
the supervisor terminates both process groups and exits for your process manager
to restart. SIGTERM allows shutdown; incomplete jobs resume after lease expiration.

Use an HTTPS reverse proxy with a hostname and certificate trusted by the phone.
The proxy must forward only Flask routes, preserve Authorization, allow the PDF
byte limit, and use request timeouts consistent with upload/chat/render deadlines.
Do not disable certificate checks or add cleartext exceptions in Flutter. Phone
`localhost` is the phone, not the backend. Local CA certificates must be properly
trusted on the test device; do not bypass browser/device security warnings.

```sh
cd ../mobile
flutter pub get
API_BASE_URL="https://YOUR_TRUSTED_API_HOST/api/v1/" dart run tool/launch.dart --configure
dart run tool/launch.dart
```

Flutter's `.env.example` is descriptive, not automatically loaded. The launcher
creates ignored local public build configuration and passes it as Dart definitions.
Fully rebuild/reinstall after changing the URL; hot reload cannot change it.

## Docker alternative

From the repository root, with Docker installed:

```sh
docker build -t chatpdf-backend ./backend
docker volume create chatpdf-data
docker run --name chatpdf-backend --env-file backend/.env \
  -e DATABASE_PATH=/var/data/db/chatpdf.sqlite3 \
  -e DOCUMENT_STORAGE_ROOT=/var/data/documents \
  -e DOCLING_ARTIFACTS_PATH=/opt/docling-models \
  -e HF_HOME=/var/data/cache/huggingface \
  -p 127.0.0.1:10000:10000 -v chatpdf-data:/var/data chatpdf-backend
```

The image includes CPU PyTorch, standard parser artifacts, English Tesseract and
the supervisor. Ollama is **not** included. Container loopback is not host loopback:
configure an Ollama host reachable through a private backend container/network
boundary, and ensure host/firewall rules deny mobile/client access. Do not publish
Ollama's port. The above volume preserves accounts/PDFs/indexes across replacement
containers. `.dockerignore` excludes local secrets and user data. `docker exec -it
chatpdf-backend flask --app chatpdf:create_app create-user --email ...` operates on
the live mounted database; stop the container gracefully with `docker stop`.

## Database, vectors, migrations and backups

Application startup creates private SQLite schema 5 additively. No database server,
manual SQL schema import, Redis, Chroma or FAISS installation is needed. SQLite WAL
and foreign keys are enabled per the code. Default vectors are normalized float32
blobs with chunk foreign keys and compatibility profiles; search is exact per-document
cosine search, not an ANN scalability guarantee. Place DB outside the document root.
Use one host/instance with persistent local storage, not SQLite over a shared NFS
mount. Shared/multi-host scaling requires a storage/queue redesign.

For a consistent backup, stop API and worker writes, take a SQLite-consistent backup
(using the SQLite backup facility or checkpoint/close before copying), and back up
the corresponding document tree in the same maintenance window. Never copy only
the main SQLite file while ignoring an active WAL. Protect backups with restricted
access/encryption and a retention policy. Restore DB and PDF tree together while
writers are stopped, preserve permissions and model/index configuration, then check
health and a sample owned document. Live deletion does not rewrite old backups.

Changing parser/OCR/chunk/embedding/vector profile requires reindexing, not merely
restarting. For custom model changes under the same tag, bump the matching revision:

```sh
.venv/bin/flask --app chatpdf:create_app reindex-document --email reader@example.com DOCUMENT_UUID
.venv/bin/flask --app chatpdf:create_app ingestion-worker --once
```

Custom embedding/vector factories are trusted server code, not client inputs.
Remote stores must implement the transactional adapter/visibility/cleanup contract;
setting a Chroma/FAISS URL alone does not install an adapter. See [pipeline](PIPELINE.md).

## Large PDFs and resource tuning

Start with `INGESTION_BATCH_PAGES=1`, one worker, and realistic hardware. Increase
batch size only after measuring peak memory on representative tables/scans. The
allowed range is 1–10 pages. The worker copies only that subset into a temporary PDF,
releases its parser process each batch, and atomically saves elements/chunks/vectors,
page completion and heading context. It never retains a whole-document image list.
A single complex page can still exhaust RAM. Use OS/container limits and adequate
scratch disk as well as application limits; parser batches have time/output caps,
but the general parser does not install an OS address-space limit.

PDF upload defaults: 50 MiB/10000 pages; validation 30 seconds. Batch timeout is
180 seconds, lease 30 seconds with heartbeats. Keep the disk large enough for PDFs,
SQLite/WAL, temporary batch files and artifacts. Embedding sub-batches default to
16 chunks; lower this and batch pages on constrained hosts. Avoid parallel workers
competing for the same CPU/model hardware.

`standard` enables structure/table extraction; `native` is a cheaper, explicitly
limited text path without structured table recognition or OCR. Set `DOCLING_OCR=true`
with an installed/configured OCR engine for scans. English Tesseract is bundled in
the image; additional languages need additional packages. Do not assume full-page
OCR is cheaper. Page-quality warnings identify sparse pages and uncertain conversions.
Tables split only between connected row groups and repeat context; oversized intact
rows fail rather than silently truncate. Model context limits still apply.

Preview rendering is one requested page at a time, one concurrent render per API
process, 1200px longest edge and 2 MiB PNG cap by default; timeout 20 seconds. Linux
renderer address space/CPU limits are 384 MiB/20 seconds. These limits are separate
from Docling ingestion. Failures leave citation page/text available in Flutter.

## Logging and health

Run stdout/stderr under a process manager with bounded rotation/retention. Log safe
codes, job IDs, stage/attempt/checkpoint counts and exception types. Never log JWTs,
passwords, environment dumps, private PDFs, questions, prompts, model responses or
provider bodies. Do not enable Flask interactive debugging, HTTP body debugging or
prompt tracing in production. Proxy/Ollama logs need the same controls. Gunicorn's
normal startup/error logs are available; request-body logging is not configured.

```sh
curl --fail https://YOUR_TRUSTED_API_HOST/health
.venv/bin/flask --app chatpdf:create_app verify-ollama-models --generate
```

Health checks only test a database read, not worker liveness/model capacity. Monitor
queued job age, `next_page`, warning counts, repeated failures, disk/RAM and worker
process status separately. Poll owned job/report APIs; they expose safe status data.
Use the included local demonstration for end-to-end ingestion/retrieval:

```sh
.venv/bin/python -m chatpdf.demo --directory var/local-verification
# Fast offline diagnostic, lexical rather than semantic:
.venv/bin/python -m chatpdf.demo --directory var/offline-verification --native --offline
```

The default demo needs configured embedding service/models. It does not itself prove
chat generation or mobile TLS. Verify sign-in, a small upload, job completion, search,
chat, a citation page, history and document deletion against your own test account.

## Troubleshooting

| Symptom | Check/action |
| --- | --- |
| App setup screen | Set real Flask HTTPS URL with the launcher; rebuild, not hot reload. |
| Signup fails | Use a valid email and 8–1024 character password; existing email returns 409. Password reset delivery is not implemented. |
| 401 | Token expired (30 min), disabled user, wrong issuer/audience, changed signing key; sign in again. |
| Expired paid access | Set a valid future server expiry or explicitly switch to free; no client override. |
| `model_not_configured`/`model_missing` | Set exact tags/host and verify on that same deployment; no guessed Kimi fallback. |
| Ollama unreachable | Check backend-only network, container-vs-host loopback, credentials and service status. |
| Model timeout | Check RAM/VRAM/load/context and server timeout. Mobile JSON calls time out at 30 seconds, even though backend chat defaults to 120 seconds; do not blindly retry a possibly committed chat. Reload history first. |
| Upload 413 or encrypted/corrupt | Check proxy/app limits; use an unencrypted valid PDF within configured limits. |
| Queued job does not move | Start durable worker with same env/DB/storage; inspect process and lease/checkpoint. |
| `embedding_failed`/`indexing_failed` | Fix provider/disk and retry; committed batches remain. |
| `reindex_required` | Run explicit reindex with current profile; do not mix model vectors. |
| Sparse or empty scan | Enable/configure OCR and review page warnings; extraction cannot infer chart meaning. |
| Preview unavailable/busy | Retry or read saved citation text; check source, timeout and rendering limits. |
| `cleanup_pending` | Fix file/index permissions/provider and retry DELETE; tombstone blocks writes. |
| Database locked | Check overlapping processes/transactions, host filesystem and disk pressure. |
| Lost free Render data | Free service disk is ephemeral; it is a demo, not durable local/production storage. |

There is no automatic refresh, payment flow or self-service account deletion. The
free Render deployment's settings differ from the prepared paid Blueprint; this
guide does not create charges or redeploy it. Use persistent local storage for this
workflow. See [API](API.md), [environment](ENVIRONMENT.md), [Ollama](OLLAMA.md), and
[Render-specific notes](RENDER.md).

### Local embeddings without Ollama embeddings

The example configuration now uses local `multilingual-e5-small`; follow the
[local E5 setup](ENVIRONMENT.md#local-multilingual-e5-no-embedding-api-key) before
starting the worker. Ollama verification concerns chat only. Use the demo with
`EMBEDDING_PROVIDER=local-e5`, `EMBEDDING_MODEL=intfloat/multilingual-e5-small`,
and `E5_MODEL_PATH` pointing to the downloaded directory. This option has no
embedding API charges but needs sufficient RAM; it is not verified to fit Render Free.
