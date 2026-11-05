# Environment reference

Backend variables are read at startup. Flask CLI and `python -m chatpdf.serve` load
local `.env`; existing process environment wins. Changing configuration requires
restarting API and worker. `.env.example` has public examples and empty secrets;
never reuse a signing secret from documentation. Relative paths resolve from the
process working directory (use `backend/`).

The table below lists every variable read by `create_app`, with its **code default**.
The example file deliberately overrides some defaults (notably embedding model and
loopback Ollama URL); no chat tags are guessed. `unset`/empty secrets require operator
configuration when the corresponding feature is used.

| Variable | Code default |
| --- | --- |
| `PREVIEW_MAX_EDGE` | `1200` |
| `PREVIEW_TIMEOUT` | `20` |
| `DATABASE_PATH` | `'var/chatpdf.sqlite3'` |
| `DOCUMENT_STORAGE_ROOT` | `'var/documents'` |
| `JWT_SECRET_KEY` | `''` |
| `JWT_ISSUER` | `'chatpdf-api'` |
| `JWT_AUDIENCE` | `'chatpdf-mobile'` |
| `MAX_PDF_BYTES` | `50 * 1024 * 1024` |
| `MAX_PDF_PAGES` | `10000` |
| `PDF_VALIDATION_TIMEOUT` | `30` |
| `INGESTION_BATCH_PAGES` | `3` |
| `INGESTION_BATCH_TIMEOUT` | `180` |
| `INGESTION_LEASE_SECONDS` | `30` |
| `DOCLING_PIPELINE` | `'standard'` |
| `DOCLING_OCR` | `'false'` |
| `DOCLING_ARTIFACTS_PATH` | `unset` |
| `DOCLING_OCR_ENGINE` | `'tesseract'` |
| `DOCLING_OCR_LANGUAGES` | `'eng'` |
| `DOCLING_OCR_FORCE_FULL_PAGE` | `'false'` |
| `PARSER_FACTORY` | `'chatpdf.pipeline.parsers:DoclingParser'` |
| `PARSER_REVISION` | `'docling-2.142.1-structured-v1'` |
| `CHUNK_SIZE` | `1800` |
| `CHUNK_OVERLAP` | `150` |
| `MAX_CHUNK_SIZE` | `16000` |
| `LOW_TEXT_CHARACTERS` | `40` |
| `EMBEDDING_PROVIDER` | `'ollama'` |
| `EMBEDDING_MODEL` | `''` |
| `EMBEDDING_REVISION` | `'1'` |
| `EMBEDDING_DIMENSIONS` | `0` |
| `EMBEDDING_FACTORY` | `''` |
| `EMBEDDING_BATCH_SIZE` | `16` |
| `EMBEDDING_TIMEOUT` | `90` |
| `EMBEDDING_TASK_TIMEOUT` | `300` |
| `OLLAMA_BASE_URL` | `unset` |
| `OLLAMA_API_KEY` | `unset` |
| `GEMMA_MODEL_TAG` | `''` |
| `KIMI_MODEL_TAG` | `''` |
| `OLLAMA_CHAT_TIMEOUT` | `120` |
| `OLLAMA_CHAT_MAX_TOKENS` | `1024` |
| `OLLAMA_CHAT_MAX_INPUT_CHARS` | `60000` |
| `OPENAI_API_KEY` | `unset` |
| `OPENAI_BASE_URL` | `unset` |
| `VECTOR_STORE_FACTORY` | `'chatpdf.pipeline.vectorstores:SQLiteVectorStore'` |
| `VECTOR_STORE_REVISION` | `'1'` |
| `VECTOR_STORE_URL` | `unset` |
| `VECTOR_STORE_NAMESPACE` | `'chatpdf'` |
| `VECTOR_STORE_API_KEY` | `unset` |

## Meaning and constraints

- `DATABASE_PATH`, `DOCUMENT_STORAGE_ROOT`: persistent private DB/file paths; DB
  must be outside document root. SQLite setup is automatic, current schema 5.
- `JWT_SECRET_KEY`: mandatory, at least 32 UTF-8 bytes, random and stable. Issuer and
  audience must be identical across API instances and administrative token issuance.
- `MAX_PDF_BYTES`, `MAX_PDF_PAGES`, `PDF_VALIDATION_TIMEOUT`: positive upload/page/
  validation caps. Flask also derives `MAX_CONTENT_LENGTH` from the byte limit.
- `INGESTION_BATCH_PAGES`: 1–10. Batch timeout and lease seconds are positive;
  worker heartbeats maintain the lease during parsing/embedding.
- `DOCLING_PIPELINE`: `standard` or `native`. OCR booleans enable only the literal
  value `true` (case-insensitive). Engines: `auto`, `tesseract`, `rapidocr`, `ocrmac`;
  runtime engine dependencies must exist. Languages are comma-separated engine
  codes. Artifacts path is optional; provision models explicitly for predictable runs.
- `CHUNK_SIZE`, `MAX_CHUNK_SIZE`: 128 <= target <= hard cap <= 100000 characters.
  `CHUNK_OVERLAP` is >= 0 and < target. `LOW_TEXT_CHARACTERS` is a diagnostic threshold.
- `PARSER_FACTORY`, `EMBEDDING_FACTORY`, `VECTOR_STORE_FACTORY`: trusted Python
  `module:callable` paths, never request inputs. Custom vector adapters must implement
  the transactional contract; a provider URL is not an adapter.
- `EMBEDDING_PROVIDER`: `ollama`, `openai`, `custom`, or explicit `hash-demo` (lexical
  offline diagnostics, not semantic embeddings). `EMBEDDING_MODEL` is independent
  of paid chat access. `EMBEDDING_DIMENSIONS`: 0 for provider default, maximum 32768.
  Batch size 1–256; request/task timeouts must be positive.
- `OLLAMA_BASE_URL`: server-only root endpoint; loopback when colocated. Chat rejects
  URL credentials, query strings, fragments and redirects. `OLLAMA_API_KEY` is used
  for chat authorization when supplied. The Ollama embedding adapter forwards this key as a bearer header as well;
  verify embedding authentication on the configured target. Prefer backend loopback/private networking.
- `OPENAI_API_KEY`, `OPENAI_BASE_URL`: required by the OpenAI-compatible embedding
  provider alongside the model. This sends chunk/query text to that endpoint.
- `GEMMA_MODEL_TAG`, `KIMI_MODEL_TAG`: distinct exact `name:tag` identifiers. Free gets
  only configured Gemma, unexpired paid only configured Kimi. Missing config fails
  closed; no automatic download, substitution or downgrade.
- `OLLAMA_CHAT_TIMEOUT`, `OLLAMA_CHAT_MAX_TOKENS`, `OLLAMA_CHAT_MAX_INPUT_CHARS`:
  positive transport timeout/output/input limits. Timeout is not an absolute
  end-to-end deadline. Chat route bounds evidence/history as documented in API.md.
- `*_REVISION`: bump when behavior/weights change in place. Parser/OCR/chunk/model/
  vector profile changes require reindexing. Credentials are excluded from profiles.
- `VECTOR_STORE_URL`, `VECTOR_STORE_NAMESPACE`, `VECTOR_STORE_API_KEY`: available to
  custom adapters. Built-in SQLite uses DATABASE_PATH and ignores remote credentials.
- `PREVIEW_MAX_EDGE`: 256–1600 pixels. `PREVIEW_TIMEOUT`: 1–25 seconds. Preview PNG
  output is capped at 2 MiB; concurrency is one render per API process.

## Process and tooling variables

`PORT` is read by `chatpdf.serve` (default 10000, range 1–65535). `HF_HOME` can place
Hugging Face caches on persistent storage. The Dockerfile also sets
`OMP_NUM_THREADS=1`, `TOKENIZERS_PARALLELISM=false`, unbuffered Python output and
no bytecode/pip cache; these affect dependency/runtime behavior, not authorization.
The app's `.env` does not configure an already running Ollama daemon: configure its
`OLLAMA_HOST`/context/hardware settings in that daemon's own environment.

Mobile uses only `APP_ENV` (`development` or `production`) and `API_BASE_URL` (HTTPS
Flask base including `/api/v1/`). They are public compiled Dart definitions; use
`mobile/tool/launch.dart` and ignored `mobile/config/*.json`. No server signing
secret, database credentials, Ollama URL/key or model policy belongs in Flutter.
