# Render deployment

The root `render.yaml` defines one Docker web service in Singapore with one 5 GB
persistent disk. This is a paid deployment, not an ephemeral free-tier demo.
The initial compute plan is `1c-2g` (1 CPU / 2 GB RAM); Docling uses one page per
batch and CPU-only PyTorch wheels. Profile real PDFs before increasing load. Large
scans may need more RAM; a paid plan is not a guarantee that every PDF fits memory.

## Why one service

The current storage design uses SQLite and local document files. Render cannot
mount a service's persistent disk in a separate web/worker service. `chatpdf.serve`
therefore supervises an independent Gunicorn process and an independent ingestion
worker process in the same container. This is not a background thread per request.
If either process exits, the supervisor shuts down both so Render can restart them.
Process groups include parser subprocesses, and saved job checkpoints survive.

Keep exactly one service instance. Store the SQLite DB under `/var/data/db` and PDFs
under `/var/data/documents`; they must be outside one another. Both survive redeploys.
Parser artifacts are downloaded into the Docker image during build. No account
records, private PDFs, local `.env`, model credentials or development databases are
copied into the image. Runtime secrets are generated/set in Render.

Free instances cannot attach this disk. Do not remove the disk just to make the
deployment free: account records, tokens' signing secret consistency, PDFs and
index state must survive restarts. Render disk deployments also have brief downtime
on redeploy. Use coordinated database/file backups and an appropriate retention policy.

## Deploy

1. Add a payment method in the Render workspace and approve the recurring compute
   and disk cost. The proposed baseline is $25/month compute plus $1.25/month for
   5 GB disk ($26.25/month before tax and metered overages). Confirm current pricing
   in Render before creation; do not change the workspace subscription plan.
2. Create a Blueprint using this repository, deployment branch
   `codex/render-deployment`, and root `render.yaml`.
3. Supply a server-reachable `OLLAMA_BASE_URL`, any required `OLLAMA_API_KEY`,
   `EMBEDDING_MODEL`, `GEMMA_MODEL_TAG`, and `KIMI_MODEL_TAG`. A laptop's
   `127.0.0.1:11434` is not reachable from Render. Do not expose an unauthenticated
   Ollama server publicly. Use a trusted authenticated HTTPS endpoint or a private
   reachable service. Hosting Ollama/model hardware is separate from this API plan.
4. Let Render generate `JWT_SECRET_KEY`. Keep it stable across deploys. Never put
   credentials in `render.yaml` or Flutter. Enforce login rate limits at the gateway.
5. Deploy and monitor the build, then require HTTPS `GET /health` to return
   `{"status":"ok"}`. Readiness verifies database access; it does not claim Ollama
   health. Unauthenticated `GET /api/v1/auth/entitlements` must return 401.

No payment method is provisioned by code. Do not put billing details or API keys in
chat or commit them. Docker image builds can take several minutes because Docling,
CPU model wheels and parsing artifacts are substantial. Docker is not installed on
the current workstation; the actual image build must be verified on Render or on
another Docker-equipped machine before declaring the deployment successful.

## After deployment

Use Render's service Shell/SSH (the live instance, not a one-off job, because the
latter cannot see its persistent disk):

```sh
flask --app chatpdf:create_app verify-ollama-models --generate
flask --app chatpdf:create_app create-user --email YOUR_EMAIL
# Password is prompted privately and hashed; no default account is created.
```

If paid access is authorized, use the administrative `set-subscription` command
documented in `OLLAMA.md`. This application does not process payments. Standard
parsing is enabled; set `DOCLING_OCR=true` for the bundled English Tesseract path.
Install additional Tesseract language packs in the Dockerfile if needed.

Then configure Flutter with the **actual service URL assigned by Render**:

```sh
cd mobile
API_BASE_URL="https://ACTUAL_SERVICE.onrender.com/api/v1/" dart run tool/launch.dart --configure
dart run tool/launch.dart
```

The displayed service name does not establish its assigned hostname; verify it in
Render and through TLS before writing the mobile configuration. Fully rebuild and
reinstall the previous unconfigured mobile build. Validate sign-in, a small PDF,
processing status, owner-scoped retrieval and deletion against the new environment.

References: [Render disks](https://render.com/docs/disks),
[Docker deployment](https://render.com/docs/docker),
[compute plans](https://render.com/docs/compute-plans),
[pricing](https://render.com/pricing).

## Separate free demo

The paid Blueprint above is a prepared durable deployment, not the configuration
of the separately created free demo. That demo uses temporary `/tmp/chatpdf`
storage, native text parsing and no configured Ollama provider. It can lose accounts,
PDFs and indexes on restart/redeploy and is not a durable production installation.
Do not apply this paid Blueprint or add a disk without cost approval. Local source
changes do not automatically update the deployed demo: verify the deployed commit
in Render before assuming newer endpoints exist there. Local deployment instructions
are in [LOCAL_DEPLOYMENT.md](LOCAL_DEPLOYMENT.md).
