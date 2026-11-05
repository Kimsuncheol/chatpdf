# ChatPDF

Independent projects:

- [Flutter mobile app](mobile/README.md): authentication UI, searchable/paginated
  document library, streamed PDF uploads, resumable processing status, chat and conversation screens.
- [Flask backend](backend/README.md): login/session validation and authenticated,
  owner-scoped document APIs, validated uploads, resumable Docling workers, and deletion cleanup.

The client communicates only with the configured Flask HTTPS API. SQLite and
private document/index storage remain on the server. Run the ingestion worker
alongside Flask as described in the backend README. Grounded Ollama/LangChain chat and citation page previews are implemented.
Subscription purchases remain a clearly marked placeholder. Structure-aware Docling parsing,
configurable embeddings and persistent LangChain retrieval are implemented; see
[the local pipeline demonstration](backend/PIPELINE.md).

Both projects include environment examples without real credentials. See their
READMEs for independent setup and the shared document API contract.

For local setup, operational checks and troubleshooting, see the
[local deployment guide](backend/LOCAL_DEPLOYMENT.md) and [API reference](backend/API.md).
