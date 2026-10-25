# ChatPDF

Inspection before implementation: this directory was empty, was not a Git checkout,
and contained no Flutter code, backend code, AGENTS.md, state management, or routing
conventions. Flutter 3.47.2 / Dart 3.13.2 were available.

`mobile/` is an independent Flutter Android/iOS project. The Flask backend belongs
in a separate project (for example a future `backend/` sibling). No Flask or Ollama
service is bundled with the client.

See [mobile setup and architecture](mobile/README.md) for configuration, navigation,
the proposed API contract, and the current implementation boundaries.
