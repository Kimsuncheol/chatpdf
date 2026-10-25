# ChatPDF mobile foundation

## Run

Requires Flutter 3.47.2 / Dart 3.13.2 or compatible newer SDKs.

```sh
cd mobile
flutter pub get
cp config/development.example.json config/development.json
# Edit development.json to use your Flask HTTPS API.
flutter run --dart-define-from-file=config/development.json
```

For production copy `config/production.example.json` to `config/production.json`,
set the production Flask URL, then:

```sh
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
message and never falls back to a production server. API path prefixes are preserved.

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

## Proposed Flask contract

No backend was present. These are client contracts to implement/align with Flask,
not claims that endpoints already exist. Paths are relative to `API_BASE_URL`.
IDs are strings, page numbers are 1-based, and responses are JSON except 204s.

| Method/path | Body | Response |
| --- | --- | --- |
| POST `auth/login` | `{email, password}` | `{access_token}` |
| POST `auth/register` | `{email, password}` | `{access_token}` (auto-login contract) |
| POST `auth/reset-password` | `{email}` | 2xx; generic response to avoid account enumeration |
| GET `auth/me` | — | `{id, email, subscription_tier}` |
| GET `documents` | — | `[{id, name, status, processed_pages, total_pages}]` |
| GET `documents/:id` | — | same document object |
| GET `conversations` | — | `[{id, document_id, title}]` |
| GET `documents/:id/conversations/:conversationId/messages` | — | `[{role, content, citations}]` |
| POST `documents/:id/chat` | `{question, conversation_id?}` | `{conversation_id, message: {role, content, citations}}` |

Citations have `{page_number, element_type}`. Document status `ready` enables chat;
other statuses open progress. Processing progress is fetched from the backend and
can be refreshed manually. The server must save resumable page-batch progress.

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

## Implemented scope

All eight screens are reachable through navigation with auth guards. Authentication
forms, secure session restoration, document list/detail, conversation history, and
chat requests are wired to the contract above, including loading, empty, error,
and retry states. There is no fake login, document data, or generated answer.

File selection/multipart transfer, automatic processing polling, token refresh,
purchases, reset-link completion, and a PDF page viewer are not implemented in this
foundation. Upload and purchase UI clearly identify these pending integrations.
Citation chips display page and element metadata but do not open a PDF yet.
Backend processing, LangChain/Docling/Ollama, and HTTPS hosting remain separate work.

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
