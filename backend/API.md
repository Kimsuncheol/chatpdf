# Flask API reference

Base path: `/api/v1`. All routes below except login and `/health` require
`Authorization: Bearer <access_token>`. Transport from Flutter must be HTTPS.
Responses are JSON with `Cache-Control: no-store`; errors have
`{"error":{"code":"...","message":"..."}}`. 401 includes `WWW-Authenticate: Bearer`;
503 includes `Retry-After: 3`. Do not log bearer tokens or request/response bodies.
Foreign and missing document/conversation IDs return the same 404.

## Authentication and entitlements

| Method/path | Request | Response |
| --- | --- | --- |
| POST `/auth/login` | `{ "email":"...", "password":"..." }` | `{ "access_token":"..." }` |
| GET `/auth/me` | — | `{id,email,subscription_tier}` |
| GET `/auth/entitlements` | — | `{tier,subscription_status,subscription_expires_at,entitlements:{chat,model_family,allowed_models,unavailable_reason}}` |

Access tokens expire after 30 minutes. Every protected request checks an active
account in the database. Client tiers/model names and JWT tier claims never grant
access. Paid access requires a future timezone-aware server expiry; expired/missing
expiry denies chat, without automatically downgrading the account. Entitlement
responses describe authorization/configuration, not Ollama health.

There are **no** registration, password-reset, token-refresh, revocation, billing,
account-deletion or public subscription-update endpoints. Flutter contains some
placeholder screens/contracts for those features. Provision users with `create-user`
and plans with the administrative `set-subscription` CLI; see [Ollama guide](OLLAMA.md).

## Documents, upload and jobs

| Method/path | Request | Response |
| --- | --- | --- |
| GET `/documents` | `?limit=20&q=title&cursor=...` | `{items:[document],next_cursor}` |
| GET `/documents/:id` | — | `document` |
| DELETE `/documents/:id` | — | 204 after files/index/related rows are cleaned |
| GET `/uploads/limits` | — | `{max_bytes,max_pages}` |
| POST `/documents/upload` | Raw PDF bytes, headers below | 202 `{document,job}`; accepted replay returns 200 |
| GET `/uploads/:uploadKey` | — | Own accepted `{document,job}` receipt or 404 |
| GET `/documents/:id/status` | — | `{document,job}` |
| GET `/jobs/:jobId` | — | `{document,job}` |
| POST `/documents/:id/cancel` | Empty JSON object | `{document,job}` |
| POST `/documents/:id/retry` | Empty JSON object | `{document,job}` |
| GET `/documents/:id/processing-report` | `?after_page=0&limit=50` | `{pages,document_warnings,warning_summary,next_page}` |

A document is `{id,name,uploaded_at,status,processed_pages,total_pages}`. Timestamps
are UTC ISO 8601; total pages may be null. IDs are canonical UUIDs. List limits are
1–100. Search is a literal case-insensitive title substring (max 200 characters).
Opaque cursors bind the user and query, expire after 24 hours, and must not be edited.

Upload headers: `Content-Type: application/pdf`, `X-Filename` as a URI-encoded PDF
basename, and `Idempotency-Key` as a new UUID for that selection. This is **not**
multipart upload. Reuse the same key when checking/retrying a lost response for the
same file; use receipt lookup first. An accepted key returns the original receipt.
Partial byte transfers restart; ingestion progress resumes independently.

```sh
# API_BASE_URL here is the public Flask HTTPS /api/v1/ address.
# Supply TOKEN privately; do not commit tokens or put them in URL parameters.
curl --fail-with-body -H "Authorization: Bearer $TOKEN" \
  -H 'Content-Type: application/pdf' -H "Idempotency-Key: $UPLOAD_KEY" \
  -H 'X-Filename: Report.pdf' --data-binary @Report.pdf \
  "${API_BASE_URL}documents/upload"
```

`job` may be null; otherwise it contains `id,document_id,status,stage,next_page,
error_code,retryable,attempts,updated_at,warning_count,low_text_pages`. Job states:
queued, running, completed, failed, cancelled. Stages include queued, extracting,
embedding, saving, completed, failed, cancelled. Document states are queued,
processing, ready, failed, deleting; a cancelled job keeps document status failed.

Poll status while queued/running. Cancellation preserves committed pages. Retry
resumes retryable failures/cancellations and is harmless for already queued/running/
completed jobs. It cannot repair a missing source or incompatible index. Admin
`reindex-document` resets derived progress while retaining the source/conversations.

Validation errors include 415 `unsupported_pdf`, 422 corrupt/encrypted PDFs, 413
byte/page limits and validation timeout errors. A 202 means queued, not ready.
Cleanup failures return 503 `cleanup_pending`; retry deletion. Files, extracted
rows, vectors, messages, conversations, receipts and jobs cascade with deletion.
Backups have a separate retention policy. An already absent document returns 404.

The processing report uses page keyset pagination (1–100 rows per call), includes
completed and warned pages, safe parsing warnings, sparse-text diagnostics and
quality metadata. It does not claim chart understanding or OCR completeness.

## Retrieval, chat, history and citations

| Method/path | Request | Response |
| --- | --- | --- |
| POST `/documents/:id/search` | `{query,k?}` | `{matches:[{id,content,metadata}],notice}` |
| POST `/documents/:id/chat` | `{question,conversation_id?}` | `{conversation_id,message}` |
| GET `/conversations` | — | Latest 100 owned `{id,document_id,title,created_at}` entries, newest first |
| GET `/documents/:id/conversations/:conversationId/messages` | — | Latest 200 messages, chronological array |
| GET `/documents/:id/pages/:pageNumber/preview` | — | `{page_number,mime_type:"image/png",image_base64}` |

Search queries and questions are nonempty, at most 2000 characters. Search k is an
integer 1–20 (default 4). Chat retrieves 4 candidate chunks, uses bounded recent
history only to interpret references, and accepts only the two documented request
fields. Client model/tier/owner overrides are rejected by chat. Continuation must
match both the authenticated owner and selected document. Search requires a ready,
compatible index; chat additionally requires current model entitlements.

Messages contain `{id,role,content,created_at,citations}`. Citations contain
`{page_number,element_type,snippet,element_id,source_id}`. The server verifies exact
quote membership in canonical extracted elements, then assigns original 1-based
PDF pages. `source_id` is request-local; it is not a reusable authorization token.
Invalid model citation output or absent evidence produces an insufficient-evidence
answer with no citations. Quote provenance does not prove semantic entailment of
every model paraphrase. Table structure is retained where Docling provides it;
figure captions and OCR text are not assertions about visual/chart meaning.

Responses are complete JSON, **not streaming**. Successful user/assistant messages
commit together after account/document/conversation rechecks. Generation/retrieval
errors do not save half an exchange. There is no chat idempotency key: do not
blindly retry after an ambiguous network failure; reload history first.

Common failures: 400 `invalid_question`, 409 `not_ready`, `reindex_required`,
`conversation_changed`, `document_changed`, `entitlements_changed`; 403
`subscription_expired`; 503 `retrieval_unavailable`, `model_not_configured`,
`model_missing`, `ollama_unavailable`, `model_response_invalid`; 504 `model_timeout`.

Preview ownership is checked before rendering and before release. Exactly one page
renders per subprocess; 0/out-of-range pages return 404, busy rendering returns 503,
timeouts 504. No public file URL or cache is created. Flutter keeps the page number
and supporting text visible if previewing fails. See the resource reference for limits.

## Health

`GET /health` is outside `/api/v1`, requires no token, and returns
`{"status":"ok"}` after a database read. It verifies database accessibility, not
model health, disk capacity, worker progress or successful PDF ingestion. Test
Ollama separately with `verify-ollama-models --generate`.
