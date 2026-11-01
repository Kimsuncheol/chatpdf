# ChatPDF Flask backend

A separate Python project for the mobile document library and ingestion worker. Python 3.12+ on a
POSIX platform with symlink-safe `shutil.rmtree` is required (tested on macOS
with Python 3.14). There was no previous backend, storage provider, or database to
preserve. This implementation deliberately uses SQLite and private local storage,
not a hidden external vector database requiring separate cleanup.

## Setup

```sh
cd backend
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
cp .env.example .env
# Set JWT_SECRET_KEY in .env to a random secret of at least 32 bytes.
.venv/bin/flask --app chatpdf:create_app create-user --email reader@example.com
# Password is prompted without echo and stored as a Werkzeug scrypt hash.
.venv/bin/flask --app chatpdf:create_app import-pdf --email reader@example.com /path/to/example.pdf
.venv/bin/flask --app chatpdf:create_app run --host 127.0.0.1 --port 5000
```

In a second terminal, from `backend/` with the same environment:

```sh
.venv/bin/flask --app chatpdf:create_app ingestion-worker
# Or process one queued/recoverable document and exit:
.venv/bin/flask --app chatpdf:create_app ingestion-worker --once
```

`.env` is loaded by Flask CLI/python-dotenv. No fallback signing secret exists.
`DATABASE_PATH` and `DOCUMENT_STORAGE_ROOT` are environment-configured paths relative
to the backend working directory unless absolute. Keep them private and back them
up as a coordinated unit. The DB must be outside the document storage root.

The development server binds loopback only. Place an HTTPS proxy/tunnel with a
trusted certificate in front of it and set Flutter's `API_BASE_URL` to
`https://<your-api-host>/api/v1/`. Production needs a production WSGI server, HTTPS
termination, persistent private volumes, and login rate limiting at the gateway.
Do not expose SQLite, document files, index artifacts, or Ollama directly. No mobile
service secrets or Ollama URL are required by this implementation.

`create-user` provisions free accounts administratively; it accepts no tier from the
mobile client. `import-pdf` uses the same validated upload endpoint and queues a durable job.
The worker processes it independently of Flask requests. Supervise the worker as a
separate service in deployment; do not start a thread for every WSGI request.

## API

All document routes require `Authorization: Bearer <access_token>`. JSON errors use
`{error: {code, message}}`. Successful and failed responses use `Cache-Control: no-store`.

| Route | Result |
| --- | --- |
| POST `/api/v1/auth/login` with `{email,password}` | `{access_token}`; 30-minute signed token |
| GET `/api/v1/auth/me` | `{id,email,subscription_tier}` from server user record |
| GET `/api/v1/documents?limit=20&q=report&cursor=…` | `{items:[document],next_cursor:string-or-null}` |
| GET `/api/v1/documents/:id` | owned document metadata |
| GET `/api/v1/uploads/limits` | `{max_bytes,max_pages}` |
| POST `/api/v1/documents/upload` | raw `application/pdf` body, acceptance receipt |
| GET `/api/v1/uploads/:uploadKey` | own accepted receipt, or 404 |
| GET `/api/v1/documents/:id/status` | `{document,job}` |
| GET `/api/v1/jobs/:jobId` | own document/job receipt |
| POST `/api/v1/documents/:id/cancel` | cancels queued/running work; keeps checkpoints |
| POST `/api/v1/documents/:id/retry` | queues retryable failed/cancelled work |
| DELETE `/api/v1/documents/:id` | 204 only after cleanup completes |

Document fields: `id`, `name` (display title), `uploaded_at` (UTC ISO 8601), `status`,
`processed_pages`, `total_pages` (nullable). IDs are server-generated canonical UUIDs.
Statuses are `queued`, `processing`, `ready`, `failed`, and `deleting`.
No filesystem paths, extracted text, indexes, or owner identifiers are exposed.

`limit` is 1–100 (default 20). Search is a literal Unicode-casefolded substring of
the title, capped at 200 characters; `%` and `_` are literal. Owner scoping occurs
inside every query, including search. Sort order is newest upload first, then UUID
descending to resolve ties. Signed keyset cursors are bound to the authenticated
user and normalized search, expire after 24 hours, and tolerate deletion of a page
boundary row. Invalid cursors/parameters return 400; refresh starts over. A list is
not a frozen snapshot: new uploads appear on refresh; deleting rows does not shift
offsets or skip the next page.

Tokens are validated using a fixed HS256 algorithm, required subject/expiry/issued-at,
issuer, and audience. Every request looks up an active server user. Unsigned/expired
or invalid tokens get 401. Ownership comes only from that user record. Client owner,
subscription, and model fields/headers confer no access. Foreign and missing IDs
both get 404 for GET and DELETE. A repeated DELETE after completed removal also gets
404; Flutter treats an already absent item as removed. Concurrent owned deletions
that both observed the document may both finish with 204.

Registration, email reset delivery, token refresh/revocation, generated-answer chat
APIs, chat model selection, and subscription purchasing remain separate work.
Structure-aware Docling ingestion and LangChain retrieval are implemented. The existing Flutter screens for those APIs remain intact. Future
model access must select configured Gemma/Kimi on the server using the database tier.

## Storage and deletion design

```text
var/
  chatpdf.sqlite3                 users, documents, chunks, embeddings,
                                 conversations, messages, processing_jobs,
                                 upload_requests, document_pages
  documents/<document-uuid>/
    original.pdf                 original document (server-selected filename)
    extracted/                   future per-page extraction artifacts
    index/                       future per-document search/vector index files
```

Extracted chunks include a 1-based page number and element type. Embeddings reference
chunks; messages reference conversations. Foreign keys cascade from document to
chunks/embeddings, conversations/messages, processing jobs, upload receipts,
and per-page checkpoints. Every SQLite
connection enables foreign keys. The original PDF, extracted files, and per-document
index files share a single document directory. There is no external shared index,
object-store key, or client-supplied file path to leave behind.

Deletion is a recoverable three-stage operation:

1. Verify ownership, then commit `status=deleting` and cancel the document's jobs.
2. Remove the private UUID directory, including original, extraction, and index
   artifacts. Descriptor-relative symlink-safe removal never follows links outside
   that directory. Already missing files are treated as cleaned up.
3. Delete the owned document row in a transaction. Foreign keys cascade all related
   content, embeddings, chats, messages, job progress, upload receipts, and completed-page records. Only then return 204.

Files and SQLite cannot share an atomic transaction. If storage removal or final DB
commit fails, return 503 with `cleanup_pending`; keep the tombstone so the owner can
retry the same DELETE. A retry works even if some/all files are already gone. The
library shows deletion pending and supports retry; it does not claim success early.
A crash after the tombstone commit likewise leaves a recoverable row. Deletion tombstones require
retry through the same authenticated endpoint. The idle ingestion worker separately
reaps abandoned upload temporary files and unreferenced UUID directories older than
24 hours, under the publication lock; it never removes an existing document row or
its directory. This covers a crash between the filesystem move and the DB commit.

The ingestion worker parses outside DB transactions. Its checkpoint transaction
rechecks the active lease token, job state, and document tombstone before committing
chunks and completed pages. Cancellation clears the lease; deletion removes the
job. Late workers cannot publish results or recreate a deleted document directory.
The parser only writes to private temporary directories outside document storage.
Future artifact/index writers must use `storage.writable_document(id)` per small
batch or the same lease/tombstone fencing inside their publication transaction.
Future content/chat/index reads must verify ownership and reject `deleting` status;
the current GET exposes metadata only to show deletion progress.

Replacing local storage or introducing a shared vector index requires extending this
deletion service and its failure/retry tests before writing artifacts there. Backups
and their retention are managed separately; deleting a live document does not rewrite
old infrastructure backups. Do not delete user/document rows through raw SQL in
application features, since that would bypass file cleanup.

Implementation references: [Flask tests](https://flask.palletsprojects.com/en/stable/testing/),
[PyJWT validation](https://pyjwt.readthedocs.io/en/latest/usage.html),
[Python symlink-safe deletion](https://docs.python.org/3/library/shutil.html#shutil.rmtree).

## Tests

```sh
cd backend
.venv/bin/python -m pytest -q
```

Tests use temporary databases/storage and signed test tokens only. They cover owner
isolation, forged/expired tokens, active-account checks, pagination/search and cursor
binding, cascaded cleanup, partial failures and retry, missing files, symlinks, and
worker tombstone protection, upload validation, receipt idempotency, lease recovery,
cancel/resume, batch replay, schema migration, orphan cleanup, and real Docling
subprocess parsing with preserved original page numbers. No real user documents are removed during verification.

## Validated uploads and durable ingestion

See [processing and retrieval guide](PIPELINE.md) for the current structure-aware
chunker, OCR controls, persistent vectors, provider interfaces and local demo.


Uploads use a raw binary body rather than multipart form buffering. Send
`Content-Type: application/pdf`, `X-Filename: <URI-encoded PDF filename>`, and a
UUID `Idempotency-Key`. Flask copies at most 64 KiB at a time into a private,
server-named `.incoming/*.part` file. The configured byte cap applies to both
Content-Length and streamed reads. The original filename is display metadata only;
its path cannot select storage locations.

A short-lived subprocess validates PDF magic, readable structure, encryption, and
page count using a seekable file handle. A filename is never handed to pypdf to
implicitly copy the whole file into `BytesIO`. Password-protected PDFs are rejected,
including those with empty passwords. Unsupported files get 415, corrupt/encrypted
files 422, and byte/page-limit violations 413. No accepted document/job exists for
these failures. Validation has a timeout and temporary files are cleaned on errors.

After validation, an atomic filesystem move plus an immediate SQLite transaction
creates the original PDF, document, queued job, and owner/key receipt. The worker
can only see the job after commit. A 202 receipt means queued, not already parsed.
A repeated accepted key returns the first receipt (200); keys are scoped to the
owner and bind the first accepted submission, not authorization or client identity.
Do not reuse a key for a different selection. Receipt lookup handles response loss
without re-sending bytes. Concurrent submissions serialize the final key check.
Receipts are removed with document deletion. Interrupted byte transfers must restart;
only ingestion checkpoints, not partial upload byte ranges, are resumable.

The schema migrates additively to version 3, preserving existing records. Jobs store
status, stage, next page, attempt count, safe error code, retryability, lease owner,
lease expiry, and update timestamp. `document_pages` records completed page numbers.
Each worker claims a queued job or an expired running lease under a write lock and
heartbeats during parsing. Restarting a worker resumes expired work at `next_page`.
It cannot claim cancelled or non-retryable failed work without an explicit retry.

Each batch is 3 pages by default (`INGESTION_BATCH_PAGES`, constrained to 1–10).
A short-lived process copies only those pages to a temporary PDF and invokes
Docling on that subset. Page/picture-image retention is explicitly disabled, and
process exit releases the batch's converter, native parser, and temporary data.
No accumulated whole-document Docling object, page-image list, or extracted export
is retained. The source is opened as a seekable disk stream. One exceptionally
complex page can still affect peak memory; byte, text/output, and batch-timeout
limits are enforced, while operating-system process memory limits are deployment configuration.

Docling provenance is offset to original 1-based pages. Raw text, tables, headings,
figure references, source geometry and page-quality warnings are retained separately
from retrieval chunks. Headings travel with relevant text; table fragments retain
whole rows and repeat available headers. LangChain embeddings are generated before
the checkpoint publishes canonical chunks and persistent vectors atomically.

`DOCLING_PIPELINE=standard` is now the default for layout/table recognition. Enable
`DOCLING_OCR=true`, select an installed OCR engine/languages, and provision its model
artifacts for scanned pages. The explicit `native` alternative reports its lack of
layout/table/OCR recognition. Both modes avoid retained whole-document page images.
Figures are PDF-region references and captions with visual-understanding disabled;
ordinary text/OCR extraction does not establish a chart's meaning.

`ready` now requires checkpointed pages and a compatible persistent retrieval index.
The default store performs exact cosine search on owned-document vectors in SQLite.
Parser, embedding and vector factories are server-configurable. Existing documents
need explicit reindex when their parser/model/index compatibility profile changes.
The [pipeline guide](PIPELINE.md) documents migration, factories, authenticated search,
quality-report pagination, and a local sample command. Generated answers and a
citation-linked PDF viewer remain separate features.

Cancellation is immediate at the durable job-state level and checked by the worker
roughly every 200 ms while a subprocess runs. Completed batches and the original
remain for Resume. For compatibility with the original document status CHECK,
cancelled jobs have document status `failed` and job status/stage `cancelled`; the
status screen displays this as cancelled with saved progress. Retry is idempotent
for already queued/running/completed jobs, resumes only retryable failures, and
rejects missing-source/no-readable-content/content-limit failures with 409.

Defaults in `.env.example`: 50 MiB upload limit, 10,000 pages, 30-second validation,
3 pages/batch, 180-second batch timeout, 30-second heartbeat lease. These are server
configuration, never proof supplied by the client. Status exposes counts/checkpoint
and safe job state to the owner, without text, filesystem paths, or parser traces.
