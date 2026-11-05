# PDF processing and retrieval

The pipeline uses Docling for extraction and LangChain `Document`, `Embeddings`,
`RecursiveCharacterTextSplitter`, `VectorStore`, and retriever interfaces. It returns
source evidence; it does not generate answers or infer whether the evidence suffices
to answer a question. Chat model entitlements remain a separate server responsibility.
No client-supplied model, tier, parser, or vector-store setting grants access.

## Run a local demonstration

Use the existing backend virtual environment and install its updated requirements:

```sh
cd backend
.venv/bin/pip install -r requirements.txt
export OLLAMA_BASE_URL=http://127.0.0.1:11434
export EMBEDDING_MODEL=nomic-embed-text:latest
export INGESTION_BATCH_PAGES=2
export DOCLING_PIPELINE=standard
export DOCLING_OCR_ENGINE=tesseract
# The configured embedding model must already be installed in this Ollama instance.
# OCR also requires Tesseract and the configured language data on the server.
.venv/bin/python -m chatpdf.demo --directory var/retrieval-demo --ocr
```

Without `--pdf`, this creates a small three-page PDF with a funding table, an image
chart with an explicit caption, and a scanned appendix. It uploads the PDF through
the real authenticated upload handler, runs the normal worker, then queries the index
through a LangChain retriever. It uses a dedicated local SQLite database and random,
process-local demo credentials; it never changes real accounts. No public server is
started. It reads the backend `.env` without overriding explicitly exported variables. Model artifacts may download on the first standard Docling conversion.

The sample's proposed Boreal budget is present as a complete table row. A query for
the scanned appendix can retrieve OCR text on page 3 when OCR is enabled. The chart
is retained as a PDF-region reference/caption, not an interpretation of bar heights.

Run again with the same configuration to reopen the persisted vectors without
parsing or embedding the PDF again:

```sh
.venv/bin/python -m chatpdf.demo --directory var/retrieval-demo --ocr \
  --question 'What is the reserve funding in the scanned appendix?'
```

A rerun also retries a retryable failed job from its saved checkpoint; it does not
automatically restart a cancelled job. Use `--reindex` only when regenerating derived
data with new settings is intended.

Use `--pdf /path/to/document.pdf` with a new `--directory` to demonstrate your own
PDF. `--reindex` explicitly regenerates derived data from the retained original
when settings change. To demonstrate the infrastructure without services/models:

```sh
.venv/bin/python -m chatpdf.demo --directory var/offline-demo --native --offline
```

That alternative uses **lexical feature hashing, not semantic embeddings**, and
native PDF text/region extraction, **not table recognition, layout inference, or
OCR**. It reports these limitations and sparse image-only pages rather than
pretending they were understood. Production defaults are standard Docling and the
configured Ollama embedding model, not the offline demonstration.

The generated samples, databases, and indexes stay under the chosen demo directory;
`var/` is ignored by Git. The default vector store persists in `demo.sqlite3`, not in
an untracked in-memory global. Demo state contains no reusable authentication token.

## Normal service configuration

Copy the public examples in `.env.example` into your local environment and supply
real server secrets separately. Relevant settings:

| Setting | Meaning |
| --- | --- |
| `DOCLING_PIPELINE=standard` | Layout, headings, tables, and configurable OCR; native mode is an explicitly limited alternative |
| `DOCLING_OCR`, `DOCLING_OCR_ENGINE` | Enable OCR and select `tesseract`, `auto`, `rapidocr`, or `ocrmac` |
| `DOCLING_OCR_LANGUAGES` | Comma-separated language codes supported by the chosen installed OCR engine |
| `DOCLING_OCR_FORCE_FULL_PAGE` | Use full-page OCR instead of Docling's normal region selection |
| `DOCLING_ARTIFACTS_PATH` | Optional pre-provisioned model-artifact directory |
| `INGESTION_BATCH_PAGES` | Pages per short-lived parse subprocess, default 3, range 1–10 |
| `CHUNK_SIZE`, `CHUNK_OVERLAP` | Soft character target and paragraph-fragment overlap |
| `MAX_CHUNK_SIZE` | Hard input cap; an oversized intact row/heading fails clearly rather than being silently truncated |
| `LOW_TEXT_CHARACTERS` | Sparse-page diagnostic threshold, default 40; not an OCR confidence score |
| `EMBEDDING_PROVIDER` | `ollama`, `openai`, `custom`, or explicit `hash-demo` |
| `EMBEDDING_MODEL`, `EMBEDDING_DIMENSIONS` | Server model and dimensions; 0 means provider default |
| `OLLAMA_BASE_URL` | Required server-only Ollama URL for the local embedding provider |
| `OPENAI_BASE_URL`, `OPENAI_API_KEY` | Required for the OpenAI-compatible LangChain provider |
| `EMBEDDING_TIMEOUT`, `EMBEDDING_TASK_TIMEOUT` | Per-provider request timeout and whole page-batch embedding deadline |
| `EMBEDDING_BATCH_SIZE` | Number of retrieval chunks per embedding request, default 16 |
| `PARSER_FACTORY`, `EMBEDDING_FACTORY`, `VECTOR_STORE_FACTORY` | Trusted server-side Python factory paths, described below |
| `PARSER_REVISION`, `EMBEDDING_REVISION`, `VECTOR_STORE_REVISION` | Explicit compatibility revisions; bump when plugin/model behavior changes in place |

The default Ollama adapter implements LangChain's `Embeddings` interface using the
public Ollama client. It requests `truncate=False`, so an over-context table row is
not quietly discarded. The OpenAI-compatible provider uses `OpenAIEmbeddings`.
Embedding calls receive text chunks and heading/caption context, not image pixels.
Selecting a remote embedding provider sends that text and queries to its configured
endpoint; URLs and API keys stay in the backend environment and never enter Flutter.
The embedding model is independent of the configured Gemma/Kimi chat entitlements.

Run Flask and the durable worker separately:

```sh
.venv/bin/flask --app chatpdf:create_app ingestion-worker
# Or process one queued/recoverable document:
.venv/bin/flask --app chatpdf:create_app ingestion-worker --once
```

There is no per-request untracked worker thread. An upload commits the queued job;
the separate worker claims it. Parser/model configuration errors leave a safe,
retryable job failure. Missing artifacts, unavailable embedding services, and model
context limits are not bypassed by silently falling back to another provider.

## Extraction and chunking

Each parser subprocess opens the original as a seekable file, copies only the
current small page batch into a private temporary PDF, and gives that subset to
Docling. Page/picture image retention, picture descriptions/classification, and
remote inference services are disabled. Standard layout/OCR can rasterize the
current subset internally; the worker never retains an entire-document page-image
list. The subprocess and its temporary data are released after the batch.

Raw extracted elements are stored separately from retrieval chunks. They retain:

- Original 1-based page number(s), element label, position, and source element ID.
- Docling reference, bounding boxes/coordinate origins, and available character spans.
- Heading level and caption association where Docling provides them.
- Table rows/cells, headers, row/column spans, captions, and full Markdown text.
- Figure references containing document/page/region/caption metadata.

A figure reference points at a region of the original, access-controlled PDF. No
standalone image export is required. Captions can be indexed as explicit textual
evidence, but their chunks carry `evidence_kind=figure_caption` and
`visual_understanding=false`. OCR may recover labels from an image; neither that
nor ordinary text extraction establishes the meaning of a chart, trend, or visual
comparison. This pipeline performs no visual question answering.

Page dimensions and source parent/child references are retained with available
list markers and Docling ordering metadata.

The structure-aware chunker packs neighboring paragraphs from the same page and
uses LangChain's recursive splitter only for long text blocks. It prepends the
current heading hierarchy to body/table chunks and stores heading source pages.
Heading context is checkpointed across page batches. Standalone headers/footers
and attached captions do not produce noisy duplicate retrieval chunks.

Tables are packed between whole rows, repeating available column headers and
captions for each fragment. Connected row-spanning cells stay in the same group.
An individual row may exceed the soft target to preserve it intact. If it exceeds
the hard cap, processing reports `chunk_too_large`/`oversized_atomic_chunk`; the
original and earlier batches remain recoverable. Configure a suitable limit/model
or use a smaller source. Cross-batch table continuity is **not inferred**: a table
at a batch boundary is flagged for review. Native mode cannot provide table row
structure, so it reports a limitation instead of assigning invented table labels.

Chunk metadata includes `document_id`, `page_number`, `page_numbers`, `element_type`,
`element_types`, `section_heading` (nearest heading, or null), `heading_path`
(ordered title/section hierarchy), source element IDs, heading context, figure references, and the
visual-understanding flag. Multi-page Docling items are stored per source page but
indexed once per batch, with their supporting pages retained. This metadata is
used by the implemented grounded chat/citation layer; see [API reference](API.md).

## Persistence and interrupted jobs

Schema version 3 adds raw `extracted_elements`, `processing_warnings`, quality on
`document_pages`, JSON metadata on `chunks`, typed/profiled vectors on `embeddings`,
and parser continuation/profile fields on jobs. Migrations add columns/tables and
retain existing source documents and conversations. Legacy completed documents
have no compatible retrieval index and must be explicitly reindexed:

```sh
.venv/bin/flask --app chatpdf:create_app reindex-document \
  --email reader@example.com DOCUMENT_UUID
.venv/bin/flask --app chatpdf:create_app ingestion-worker --once
```

Reindex invalidates an existing lease, resets derived checkpoints/context, and blocks
retrieval while rebuilding. It retains the original PDF and conversations. Earlier
raw/chunk records are replaced page by page; they are not exposed as a ready index.
An old partial job with no profile also requires reindex instead of mixing legacy
character-split chunks with new embeddings.

The worker keeps its lease alive while parsing and embedding. Embeddings are
computed in bounded requests outside DB write locks. Cancellation stops subsequent
embedding requests; an already-running provider request may finish, but its output
cannot publish after lease invalidation. Provider vectors must have consistent,
nonzero dimensions, finite values, and a nonzero norm. Restart worker/Flask processes after changing provider credentials
or settings; credential rotation does not itself require reindexing.

One fenced transaction replaces the batch's raw elements/chunks, publishes vectors,
upserts completed pages/quality/warnings, saves heading continuation, and advances
`next_page`. Chunk IDs are deterministic per document/page/ordinal. A replay cannot
duplicate vectors or progress; a failed embedding/index write cannot advance the
checkpoint. On restart, an expired lease resumes at the next unfinished batch.
A document becomes ready only when every page is checkpointed and its chunks have
matching persisted index entries.

The job exposes `embedding` and `saving` stages through the existing status API.
Embedding failures record `embedding_failed`; publication failures record
`indexing_failed`. Both are retryable and leave `next_page` at the uncommitted batch.
Incompatible indexes record `reindex_required` and require explicit reindexing.
The metadata contract was updated with explicit section-heading fields; previously
indexed documents require reindexing to acquire this metadata consistently.

An opaque compatibility fingerprint covers parser/OCR/batch/chunk settings,
embedding provider/model/revision/dimensions/endpoint, and vector adapter/revision/
namespace. API keys are excluded. A changed profile cannot resume an old job or
query old vectors; explicit reindex is required. When weights change under the same
model tag/artifact path, bump the corresponding revision. This avoids mixing
vectors from incompatible models even if their dimensions happen to match.

The default SQLite store persists normalized float32 vectors in the existing private
SQLite database, with foreign keys to canonical chunks. It performs streamed exact
cosine search within the selected owned document, keeping only top-k candidates in
memory. It is a small deployment default, **not an ANN engine or a performance claim
for a large corpus**. Deleting a document cascades raw elements, warnings, page
checkpoints, chunks, vectors, jobs and receipts; the stored adapter also gets a
cleanup hook. No unsafe pickle/index deserialization is used.
The SQLite adapter checks canonical ownership for publication, counts, and cleanup,
and validates each vector's chunk/document/page/type membership before publication.
Repeated publication of the same canonical chunk ID updates its vector rather than
creating another entry. This complements the worker's atomic batch replacement.

## Retrieval and quality report

Authenticated, owner-scoped routes:

```text
POST /api/v1/documents/:id/search
     {"query":"What is the proposed budget?","k":4}
GET  /api/v1/documents/:id/processing-report?after_page=0&limit=50
```

Search uses a document-bound LangChain `as_retriever().invoke(query)`, rejects
unready/incompatible indexes, and rechecks ownership/readiness during vector reads
after the query embedding call. It returns candidate source content and metadata,
not a generated answer or a promise that the PDF answers the query. Foreign/missing
documents return 404. Limits are 2,000 query characters and k=1–20. Models, owner IDs,
subscription tiers and vector settings from request bodies are not consulted.

The paginated report includes completed pages and pages with warnings from an
uncommitted failed batch, element/image/text counts, safe warning categories, and
summary counts. It records sparse pages, figure limitations, native-mode limits,
Docling partial/runtime warnings, OCR orientation warnings and table-boundary/row
chunking warnings. Raw parser traces, source text and service URLs are not placed
in warning messages. Multi-page table text counts can be approximate; diagnostics
are not an assertion that OCR found every character or understood an image.

## Replacement interfaces

Factories are imported from **trusted server environment configuration only**:

```text
PARSER_FACTORY=my_package.parsers:build_parser
EMBEDDING_PROVIDER=custom
EMBEDDING_FACTORY=my_package.embeddings:build_embeddings
VECTOR_STORE_FACTORY=my_package.indexes:PersistentIndex
```

- Parser factory: `(config) -> BatchParser`, implementing `parse(job,start,end)`.
  Return the requested original page numbers, structured elements, optional quality
  and safe warnings, or `None` on cancellation. Respect the batch boundary and do
  not retain previous batches. See `pipeline/contracts.py` and `parse_batch.py`.
- Embedding factory: `(config) -> langchain_core.embeddings.Embeddings`, implementing
  document/query embeddings with compatible dimensions and bounded calls. Set
  `EMBEDDING_REVISION` when custom behavior or endpoint configuration changes.
- Vector factory: `(config, *, owner_id, document_id, embedding, profile)` returns a
  `TransactionalVectorStore` (a LangChain `VectorStore`). Implement search plus
  `publish(connection,documents,vectors)`, `count_indexed(connection)`, and
  `delete_document(connection)`. It must enforce canonical owner/document/profile
  visibility and atomically participate in publication. A generic community store
  cannot simply be named here without this adapter.

For a future remote vector store, implement a durable outbox/manifest and visibility
fencing before enabling it; uncommitted vectors must not be searchable, writes and
cleanup must be idempotent, and deletion must clean the document's remote namespace.
Persist adapter connection/namespace references per document/profile (secrets remain
environment references), so changing endpoints cannot orphan the old index. The
factory receives the stored profile for cleanup. `VECTOR_STORE_URL`, namespace and
API-key settings are available for that adapter; the built-in SQLite store ignores
remote credentials. Chroma/FAISS/remote adapters are not claimed to be bundled.

## Verification performed

No tests were added for this change. The local demonstration exercised real Docling
standard parsing, Tesseract OCR, local Ollama vectors, SQLite persistence and a
LangChain retriever. The offline variant exercises native parsing and explicit sparse/
visual limitations. Compilation/static checks and manual authenticated API calls
are used for this implementation. Existing fixtures now select explicit offline/native
providers, and existing assertions follow the current additive schema and the prepared-checkpoint
interface. No new test cases were added.
