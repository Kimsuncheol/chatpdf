import os
import sqlite3
from pathlib import Path
from uuid import uuid4

import click
from flask import Flask, jsonify
from werkzeug.exceptions import HTTPException
from werkzeug.security import generate_password_hash

from . import auth, db, documents, uploads
from .errors import ApiError
from .storage import DocumentStorage


def create_app(test_config=None):
    app = Flask(__name__)
    app.config.from_mapping(
        DATABASE_PATH=os.environ.get('DATABASE_PATH', 'var/chatpdf.sqlite3'),
        DOCUMENT_STORAGE_ROOT=os.environ.get('DOCUMENT_STORAGE_ROOT', 'var/documents'),
        JWT_SECRET_KEY=os.environ.get('JWT_SECRET_KEY', ''),
        JWT_ISSUER=os.environ.get('JWT_ISSUER', 'chatpdf-api'),
        JWT_AUDIENCE=os.environ.get('JWT_AUDIENCE', 'chatpdf-mobile'),
        MAX_PDF_BYTES=int(os.environ.get('MAX_PDF_BYTES', 50 * 1024 * 1024)),
        MAX_PDF_PAGES=int(os.environ.get('MAX_PDF_PAGES', 10000)),
        PDF_VALIDATION_TIMEOUT=int(os.environ.get('PDF_VALIDATION_TIMEOUT', 30)),
        INGESTION_BATCH_PAGES=int(os.environ.get('INGESTION_BATCH_PAGES', 3)),
        INGESTION_BATCH_TIMEOUT=int(os.environ.get('INGESTION_BATCH_TIMEOUT', 180)),
        INGESTION_LEASE_SECONDS=int(os.environ.get('INGESTION_LEASE_SECONDS', 30)),
        DOCLING_PIPELINE=os.environ.get('DOCLING_PIPELINE', 'standard'),
        DOCLING_OCR=os.environ.get('DOCLING_OCR', 'false').lower() == 'true',
        DOCLING_ARTIFACTS_PATH=os.environ.get('DOCLING_ARTIFACTS_PATH') or None,
        DOCLING_OCR_ENGINE=os.environ.get('DOCLING_OCR_ENGINE', 'tesseract'),
        DOCLING_OCR_LANGUAGES=[value.strip() for value in os.environ.get('DOCLING_OCR_LANGUAGES', 'eng').split(',') if value.strip()],
        DOCLING_OCR_FORCE_FULL_PAGE=os.environ.get('DOCLING_OCR_FORCE_FULL_PAGE', 'false').lower() == 'true',
        PARSER_FACTORY=os.environ.get('PARSER_FACTORY', 'chatpdf.pipeline.parsers:DoclingParser'),
        PARSER_REVISION=os.environ.get('PARSER_REVISION', 'docling-2.142.1-structured-v1'),
        CHUNK_SIZE=int(os.environ.get('CHUNK_SIZE', 1800)),
        CHUNK_OVERLAP=int(os.environ.get('CHUNK_OVERLAP', 150)),
        MAX_CHUNK_SIZE=int(os.environ.get('MAX_CHUNK_SIZE', 16000)),
        LOW_TEXT_CHARACTERS=int(os.environ.get('LOW_TEXT_CHARACTERS', 40)),
        EMBEDDING_PROVIDER=os.environ.get('EMBEDDING_PROVIDER', 'ollama'),
        EMBEDDING_MODEL=os.environ.get('EMBEDDING_MODEL', ''),
        EMBEDDING_REVISION=os.environ.get('EMBEDDING_REVISION', '1'),
        EMBEDDING_DIMENSIONS=int(os.environ.get('EMBEDDING_DIMENSIONS', 0)),
        EMBEDDING_FACTORY=os.environ.get('EMBEDDING_FACTORY', ''),
        EMBEDDING_BATCH_SIZE=int(os.environ.get('EMBEDDING_BATCH_SIZE', 16)),
        EMBEDDING_TIMEOUT=int(os.environ.get('EMBEDDING_TIMEOUT', 90)),
        EMBEDDING_TASK_TIMEOUT=int(os.environ.get('EMBEDDING_TASK_TIMEOUT', 300)),
        OLLAMA_BASE_URL=os.environ.get('OLLAMA_BASE_URL'),
        OPENAI_API_KEY=os.environ.get('OPENAI_API_KEY'),
        OPENAI_BASE_URL=os.environ.get('OPENAI_BASE_URL'),
        VECTOR_STORE_FACTORY=os.environ.get('VECTOR_STORE_FACTORY', 'chatpdf.pipeline.vectorstores:SQLiteVectorStore'),
        VECTOR_STORE_REVISION=os.environ.get('VECTOR_STORE_REVISION', '1'),
        VECTOR_STORE_URL=os.environ.get('VECTOR_STORE_URL'),
        VECTOR_STORE_NAMESPACE=os.environ.get('VECTOR_STORE_NAMESPACE', 'chatpdf'),
        VECTOR_STORE_API_KEY=os.environ.get('VECTOR_STORE_API_KEY'),
    )
    if test_config:
        app.config.update(test_config)
    app.config['MAX_CONTENT_LENGTH'] = app.config['MAX_PDF_BYTES']
    for key in ('MAX_PDF_BYTES', 'MAX_PDF_PAGES', 'PDF_VALIDATION_TIMEOUT',
                'INGESTION_BATCH_TIMEOUT', 'INGESTION_LEASE_SECONDS'):
        if app.config[key] <= 0:
            raise RuntimeError(f'{key} must be positive')
    if not 1 <= app.config['INGESTION_BATCH_PAGES'] <= 10:
        raise RuntimeError('INGESTION_BATCH_PAGES must be between 1 and 10')
    if app.config['DOCLING_PIPELINE'] not in ('native', 'standard'):
        raise RuntimeError('DOCLING_PIPELINE must be native or standard')
    if not 128 <= app.config['CHUNK_SIZE'] <= app.config['MAX_CHUNK_SIZE'] <= 100000:
        raise RuntimeError('Require 128 <= CHUNK_SIZE <= MAX_CHUNK_SIZE <= 100000')
    if not 0 <= app.config['CHUNK_OVERLAP'] < app.config['CHUNK_SIZE']:
        raise RuntimeError('CHUNK_OVERLAP must be nonnegative and smaller than CHUNK_SIZE')
    if not 1 <= app.config['EMBEDDING_BATCH_SIZE'] <= 256 or app.config['EMBEDDING_TIMEOUT'] <= 0:
        raise RuntimeError('Invalid embedding batch size or timeout')
    if not 0 <= app.config['EMBEDDING_DIMENSIONS'] <= 32768 or app.config['EMBEDDING_TASK_TIMEOUT'] <= 0:
        raise RuntimeError('Invalid embedding dimensions or task timeout')
    if app.config['DOCLING_OCR_ENGINE'] not in ('auto', 'tesseract', 'rapidocr', 'ocrmac'):
        raise RuntimeError('Unsupported OCR engine')
    if len(app.config['JWT_SECRET_KEY'].encode()) < 32:
        raise RuntimeError('JWT_SECRET_KEY must be an environment secret of at least 32 bytes')
    database = Path(app.config['DATABASE_PATH']).resolve()
    storage = DocumentStorage(app.config['DOCUMENT_STORAGE_ROOT'])
    if database.is_relative_to(storage.root):
        raise RuntimeError('The database must be outside the document storage root')
    app.config['DATABASE_PATH'] = str(database)
    app.extensions['document_storage'] = storage
    app.teardown_appcontext(db.close_db)
    with app.app_context():
        db.initialize()
    app.register_blueprint(auth.bp)
    app.register_blueprint(documents.bp)
    app.register_blueprint(uploads.bp)
    from .pipeline.retrieval import bp as retrieval_bp
    app.register_blueprint(retrieval_bp)

    @app.after_request
    def private_response(response):
        response.headers['Cache-Control'] = 'no-store'
        response.headers['X-Content-Type-Options'] = 'nosniff'
        return response

    @app.errorhandler(ApiError)
    def api_error(error):
        response = jsonify(error={'code': error.code, 'message': error.message})
        response.status_code = error.status
        if error.status == 401:
            response.headers['WWW-Authenticate'] = 'Bearer'
        if error.status == 503:
            response.headers['Retry-After'] = '3'
        return response

    @app.errorhandler(HTTPException)
    def http_error(error):
        if error.code == 413:
            return jsonify(error={'code': 'oversized_pdf', 'message': uploads.PDF_ERRORS['oversized_pdf']}), 413
        return jsonify(error={'code': 'http_error', 'message': error.name}), error.code

    @app.errorhandler(sqlite3.Error)
    def database_error(error):
        app.logger.exception('Database operation failed')
        return jsonify(error={'code': 'temporarily_unavailable', 'message': 'Please retry later.'}), 503

    @app.cli.command('create-user')
    @click.option('--email', required=True)
    @click.password_option()
    def create_user(email, password):
        """Provision an account without committing credentials or accepting client tiers."""
        if '@' not in email or not 1 <= len(password) <= 1024:
            raise click.ClickException('A valid email and nonempty password are required.')
        try:
            with db.transaction() as connection:
                connection.execute('INSERT INTO users(id, email, password_hash) VALUES (?, ?, ?)',
                                   (str(uuid4()), email.strip(), generate_password_hash(password)))
        except sqlite3.IntegrityError:
            raise click.ClickException('Account already exists.') from None
        click.echo('Account created.')

    @app.cli.command('ingestion-worker')
    @click.option('--once', is_flag=True, help='Process one available document then exit.')
    def ingestion_worker(once):
        """Run the durable queue consumer separately from WSGI workers."""
        from .ingestion import run_worker
        run_worker(app, once=once)

    @app.cli.command('reindex-document')
    @click.option('--email', required=True)
    @click.argument('document_id')
    def reindex_document(email, document_id):
        """Rebuild derived chunks/index from the retained PDF with current providers."""
        user = db.get_db().execute('SELECT id FROM users WHERE email=? COLLATE NOCASE', (email.strip(),)).fetchone()
        if user is None: raise click.ClickException('Account not found.')
        from .pipeline.retrieval import queue_reindex
        try:
            queue_reindex(user['id'], document_id)
        except ApiError as error:
            raise click.ClickException(error.message) from None
        click.echo('Reindex queued; run ingestion-worker to resume it.')

    @app.cli.command('import-pdf')
    @click.option('--email', required=True)
    @click.argument('source', type=click.Path(exists=True, dir_okay=False, path_type=Path))
    def import_pdf(email, source):
        """Stream a local PDF through the same validated authenticated upload endpoint."""
        user = db.get_db().execute('SELECT id FROM users WHERE email = ? COLLATE NOCASE', (email.strip(),)).fetchone()
        if user is None:
            raise click.ClickException('Account not found.')
        from urllib.parse import quote
        with source.open('rb') as stream:
            response = app.test_client().post('/api/v1/documents/upload', input_stream=stream,
                content_type='application/pdf', content_length=source.stat().st_size, headers={
                    'Authorization': f"Bearer {auth.issue_token(user['id'])}",
                    'Idempotency-Key': str(uuid4()), 'X-Filename': quote(source.name),
                })
        if response.status_code != 202:
            raise click.ClickException(response.json['error']['message'])
        click.echo(f"Queued document {response.json['document']['id']}.")

    return app
