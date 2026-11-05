# ChatPDF mobile foundation

## Run

Requires Flutter 3.47.2 / Dart 3.13.2 or compatible newer SDKs.

```sh
cd mobile
flutter pub get
# Set your actual Flask HTTPS address; no API address is bundled by default.
API_BASE_URL="https://<your-api-host>/api/v1/" dart run tool/launch.dart --configure
dart run tool/launch.dart
# Select a device if needed:
dart run tool/launch.dart -- -d DEVICE_ID
```

The setup command writes an ignored `config/development.json` containing only the
public Flask URL and environment. It validates HTTPS and rejects the known example
addresses. The launcher checks that file before running Flutter, so missing setup is
reported in the terminal instead of installing an unconfigured build. Alternatively,
copy/edit `config/development.example.json` and pass it to Flutter explicitly.

When opening the repository root in VS Code, choose **ChatPDF: development** in
Run and Debug. Its launch profile passes the local configuration and checks it
before launch. Generic `flutter run` or an unconfigured IDE Run action does not load
the JSON file. If opening only `mobile/`, use the launcher in its terminal.

For production configure and validate the production Flask URL, then build:

```sh
API_BASE_URL="https://<your-production-api-host>/api/v1/" dart run tool/launch.dart --production --configure
dart run tool/launch.dart --production --check
flutter build appbundle --dart-define-from-file=config/production.json
# Or, with your Apple signing team configured:
flutter build ipa --dart-define-from-file=config/production.json
```

Alternatively pass `--dart-define=APP_ENV=development` and
`--dart-define=API_BASE_URL=https://your-api.example.com/api/v1/`.
`.env.example` describes the same public environment variables; it is not loaded
at runtime. Local JSON configuration files and .env files are ignored. Both
supported environments require HTTPS, including local development (use a trusted
HTTPS development proxy/tunnel). Missing/invalid configuration displays a setup
screen and never falls back to another server. Developer instructions are available
only in debug builds. API path prefixes are preserved.

### “App setup is incomplete” / “Set API_BASE_URL” at startup

This means build configuration failed **before any API call**. It does not indicate
a password, token, PDF or Ollama error. `String.fromEnvironment` reads Dart's build
definitions; it does not read `.env`, shell variables or JSON files automatically.
Run the configure command above, then fully stop and relaunch with the launcher or
the named editor profile. Hot reload/restart cannot change compiled definitions;
an installed APK/IPA must be rebuilt and reinstalled. Never substitute an example
URL just to dismiss this screen. The Flask HTTPS endpoint must be reachable from
the phone, with a trusted TLS certificate; phone `localhost` refers to the phone.
No live Flask URL is known until the deployment's actual address is supplied.

Build configuration is readable from the compiled app: it must contain only the
public Flask URL and environment name. Keep passwords, signing secrets, service
credentials, Ollama URLs, and model configuration on the backend.

## Structure and choices

```text
lib/
  main.dart                    composition root: constructs dependencies
  app/
    app.dart                   Material theme and router lifecycle
    navigation/                route paths and authentication redirects
  core/
    config/                    validated build-time API configuration
    auth/                      token-storage interface and secure implementation
    network/                   HTTPS JSON client, bearer auth, errors, timeout
  data/
    models/                    user, document, conversation, message, citation
    repositories/              authentication and document API contracts
  state/                       ChangeNotifier session, load, and chat controllers
  ui/
    screens/                   auth, library, upload/status, chat, history, settings
    widgets/                   shared navigation shell and async content states
config/                        development/production examples
tool/launch.dart               validates local configuration before launch
android/, ios/                 separate native mobile runners
test/                        mocked API/session tests and navigation widget tests
```

There was no existing approach to reuse. Flutter's built-in `ChangeNotifier` with
`ListenableBuilder` keeps state lightweight and testable without another state
package. Dependencies are passed through constructors from the composition root.
Local form state stays in widgets. `go_router` centralizes routes, deep links,
startup restoration, and auth redirects without manual navigation-stack bookkeeping.
See the official [Flutter architecture guidance](https://docs.flutter.dev/app-architecture/recommendations) and [go_router documentation](https://pub.dev/packages/go_router) for the underlying approaches.
Repositories isolate transport and response shapes from screens. UI-specific view
models own asynchronous work and avoid updates after disposal.

## Navigation

| Screen | Route |
| --- | --- |
| Sign in | `/sign-in` |
| Create account | `/create-account` |
| Reset password | `/reset-password` |
| Home / document library | `/` |
| PDF upload / processing status | `/upload`, `/upload?documentId=…` |
| Document chat | `/documents/:documentId/chat?conversationId=…` |
| Conversation history | `/history` |
| Settings and subscription | `/settings` |

`/startup` waits for session validation and offers retry when offline. Protected
routes return to sign-in without a validated session and resume the requested route
after authentication. Unknown paths have a recovery link. Library, upload, history,
and settings share bottom navigation; document/chat screens support back navigation.

## Authentication behavior

Sign-in, create-account, and reset-password routes share a reusable form. Fields
validate email format and required values; registration also checks password
confirmation. Password strength, account eligibility, authorization, and subscription
rules belong to Flask. Password confirmation is never sent to the API.

Forms and sign-out show progress and disable controls during requests. Duplicate
operations are also blocked by `SessionController`. The screens only collect inputs
and render controller feedback; they make no API calls or session decisions.
`AuthRepository` maps response statuses to safe messages and validates the token and
account response shapes. Raw server diagnostics are never displayed.

Passwords exist only for the active request/form, are cleared from form controllers
on submission, and are never saved by the app. Keyboard suggestions and personalized
learning are disabled for password fields. Only the access token is persisted in
platform secure storage; iOS uses a device-only Keychain item accessible while
unlocked, with synchronization disabled. No refresh token is currently used.

On startup the router holds the app on `/startup` until `auth/me` validates the saved
token. Offline/server failures preserve the saved token and offer retry. Missing or
rejected tokens return to sign-in with an expiry message. A pending restore cannot
bring back a session that has since expired. Signing out deletes the secure token,
clears the user, and redirects to sign-in. If secure storage cannot be cleared,
explicit sign-out reports failure and allows retry rather than claiming success.

Password reset requests display the same confirmation for all successful responses.
Flask must return a generic 2xx response whether or not an account exists. The app
only requests reset instructions; Flask's email/reset-link flow completes the reset.

## Flask contract

The separate [Flask backend](../backend/README.md) implements login, `auth/me`,
document list/retrieve/delete, upload, job status, cancellation, and retry. Registration, password-reset delivery,
conversation, and chat endpoints remain contracts for future backend work. Paths are relative to `API_BASE_URL`.
IDs are strings, page numbers are 1-based, and responses are JSON except 204s.

| Method/path | Body | Response |
| --- | --- | --- |
| POST `auth/login` | `{email, password}` | `{access_token}` |
| POST `auth/register` | `{email, password}` | `{access_token}` (auto-login contract) |
| POST `auth/reset-password` | `{email}` | 2xx; generic response to avoid account enumeration |
| GET `auth/me` | — | `{id, email, subscription_tier}` |
| GET `documents?limit=20&q=…&cursor=…` | — | `{items: [{id, name, uploaded_at, status, processed_pages, total_pages}], next_cursor}` |
| GET `documents/:id` | — | same document object |
| GET `uploads/limits` | — | `{max_bytes, max_pages}` |
| POST `documents/upload` | raw PDF stream; `X-Filename`, `Idempotency-Key` headers | `{document, job}`; 202 (or 200 on replay) |
| GET `uploads/:key` | — | accepted upload receipt or 404 |
| GET `documents/:id/status` | — | `{document, job}` |
| POST `documents/:id/cancel` | `{}` | updated receipt, with checkpoints preserved |
| POST `documents/:id/retry` | `{}` | queued receipt resuming saved progress |
| DELETE `documents/:id` | — | 204 after files/indexes and relational content are removed; 503 if cleanup needs retry |
| GET `conversations` | — | `[{id, document_id, title}]` |
| GET `documents/:id/conversations/:conversationId/messages` | — | `[{role, content, citations}]` |
| POST `documents/:id/chat` | `{question, conversation_id?}` | `{conversation_id, message: {role, content, citations}}` |

Citations have `{page_number, element_type}`. Document status `ready` enables chat;
other statuses open progress. Processing progress is fetched from the backend and
is polled automatically while jobs are active, with manual refresh and retry. The
server persists a page checkpoint and extracted elements atomically after each batch.

The access token is stored using `flutter_secure_storage` (iOS Keychain / Android
secure storage), attached only to authenticated API requests, and validated through
`auth/me` on launch. A 401 clears the current session; network/server errors retain
a saved token and allow retry. A delayed 401 for an old token is ignored. Redirects
are disabled for HTTP requests. Tokens/passwords are never logged. Sign out clears
local credentials; server-side revocation/refresh is a future contract.

Flask must check authentication, document ownership, subscription, conversation /
document association, document readiness, and model access on every request. The
client sends no model name or subscription tier. The subscription shown in settings
is server data for display only. Flask chooses its configured Gemma model for free
accounts and configured Kimi model for paid accounts. It must ground answers in the
selected PDF, preserve page/element metadata, cite supporting pages, and state when
evidence is insufficient. Flutter displays returned answers and citations; it cannot
enforce answer grounding or authorization.

## Document library

Home has a persistent Upload PDF action, a debounced server-side title search,
upload dates formatted in the device locale, processing status, and page counts
when available. It handles initial loading/empty/error states, pull-to-refresh,
load-more pagination, and retry without discarding an already loaded page. Query
changes reset the cursor; stale search responses cannot overwrite new results.

Ready documents open document chat; queued/processing/failed documents open their
status screen. Deletion requires a confirmation describing permanent PDF, content,
index, and conversation cleanup. The affected card shows progress and disables
opening while deleting. Items are removed only after success (or an already absent
404). Failure retains the item and shows a retry message; refreshed `deleting`
metadata disables opening and offers Retry deletion. A completed deletion cannot
be resurrected by an older in-flight list response.

The API list is now a paginated envelope, replacing the initial bare-array
placeholder contract. Search spans all the user's documents on the server, not just
loaded pages. The client never sends an owner ID or decides document authorization.

## Implemented scope

All eight screens are reachable through navigation with auth guards. Authentication
forms, secure session restoration, document list/detail, conversation history, and
chat requests are wired to the contract above, including loading, empty, error,
and retry states. There is no fake login, document data, or generated answer.

Token refresh, purchases, reset-link completion, and a PDF page viewer remain
unimplemented. Citation chips display page/type metadata but do not open a PDF yet.
Docling extraction is implemented on the backend; LangChain/Ollama answer generation,
and HTTPS hosting remain separate work. Persistent vector retrieval is implemented
on the backend; see [the pipeline guide](../backend/PIPELINE.md).

## Upload and processing

`file_picker` selects one PDF. Its `readAsByteStream()` feeds an abortable request
through the existing HTTPS API client; neither `readAsBytes()` nor multipart buffering
is used. Size and extension are checked locally using server-provided limits. Flask
validates actual content, encryption, page count, and byte limits. Only safe error
codes are mapped to user messages; arbitrary server diagnostics are not displayed.

Upload progress counts bytes consumed by the transport, not server acknowledgements.
At 100%, the screen shows server validation until an acceptance response arrives.
An upload can be stopped; the server may already have accepted it. The controller
retains an idempotency key for that selection and checks its receipt before retrying,
preventing duplicate accepted documents after a lost response. Selecting another file
creates a new key. Partial byte transfers restart from byte zero; this is not a
multipart/resumable-byte upload protocol. If the app restarts, accepted documents are
recoverable through the library even though a pending local selection is not saved.

The status route includes the document ID, so reopening it restores server progress.
It shows queued, extracting, saving/completed, failed, or cancelled stages and page
counts. Polling uses a two-second interval with backoff on connection errors, pauses
when the app backgrounds, stops for terminal jobs or missing resources, and ignores
old status responses after a cancellation/retry. Cancelling processing keeps the PDF
and completed batches; Resume/Retry queues the next unfinished batch. Validation
failures require a new selection. A non-retryable processing failure also offers a
new PDF. Deleting a document remains a separate confirmed operation.

Run the backend's `ingestion-worker` alongside Flask. The default `standard` Docling
pipeline extracts layout and tables. Configure the server OCR engine/languages for
scanned PDFs and supply the embedding provider settings. The explicit native mode
reports missing structure/OCR and sparse image-only pages. Figures remain source
references/captions; chart meaning is not inferred. All pipeline configuration
stays on the server.

Android has release Internet permission, cleartext traffic disabled, and backup
disabled for credential storage. iOS has Keychain entitlements. Device signing and
actual platform secure-storage behavior require device verification.

## Verify

```sh
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
```

Tests use in-memory tokens and mocked HTTP responses, not production credentials.

## Native build verification

Android debug compilation and iOS simulator compilation were verified with a public
placeholder HTTPS API URL; no deployment or real credentials were used. The iOS
build succeeded from a temporary local source copy outside the synced Desktop
folder. The Desktop build encountered Finder metadata on generated framework bundles.
If codesign reports `resource fork, Finder information, or similar detritus not
allowed`, inspect generated bundle attributes as described in
[Apple QA1940](https://developer.apple.com/library/archive/qa/qa1940/_index.html).
A local non-synced checkout avoided this observed build-artifact issue. No app
signing settings were changed. File selection on a physical device and live HTTPS
hosting still need deployment/device verification.

## Settings, subscription and privacy

Settings loads `GET auth/entitlements` through the existing authenticated API client.
The response is display-only: current tier, subscription status, optional UTC expiry,
chat availability and exact allowed model tags come from the backend. Opening settings,
returning from background, or choosing Refresh fetches current server data. Failed
loads offer retry and label any sign-in tier snapshot as unverified; they never infer
model access from that snapshot. Normal 401 session handling still returns to sign-in.

`/settings/subscription` shows refreshed entitlement details and a clearly marked
subscription preview with disabled purchase controls. It never submits a payment,
changes a tier, or reports a successful purchase. A later billing integration must
update backend account records through a trusted server integration, not Flutter.

`/settings/privacy` explains server/provider processing, links to document deletion
in the library, and explicitly marks self-service account deletion as unavailable.
Opening it does not submit a deletion request. Existing sign-out remains independent
of entitlement loading and removes the device session, not server documents.

The backend already supplies the owner-authenticated, no-store entitlement endpoint
via `ModelPolicy`; paid expiry and model enforcement remain server-controlled.

## Citation navigation

Citation chips open `/documents/:documentId/pages/:pageNumber` and request one page
through the authenticated API client. The original 1-based citation number is never
shifted or inferred from array positions. Saved citation snippets travel as in-memory
navigation extras, not URL query text. The viewer supports zoom, loading and retry;
page number and cited text remain visible when rendering fails. Legacy citations
fall back to the answer text; deep links without saved text state that no snippet is
available. No API tokens are put in image URLs and no private images are cached to disk.

### Generic debug launches

A debug/development build without `API_BASE_URL` now loads the tracked public
`config/development.defaults.json`, pointing to the free Render demo. This prevents
an ordinary IDE Run or `flutter run` from reinstalling an unconfigured debug build.
Explicit Dart definitions take precedence. Release/profile or production-environment
builds still require explicit API configuration and never use this debug fallback.
The bundled file contains no secrets; the free demo still has temporary storage.
