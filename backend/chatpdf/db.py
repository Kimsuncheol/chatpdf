import sqlite3
from contextlib import contextmanager
from pathlib import Path

from flask import current_app, g

SCHEMA = """
CREATE TABLE IF NOT EXISTS users (
    id TEXT PRIMARY KEY,
    email TEXT NOT NULL UNIQUE COLLATE NOCASE,
    password_hash TEXT NOT NULL,
    subscription_tier TEXT NOT NULL DEFAULT 'free' CHECK (subscription_tier IN ('free', 'paid')),
    active INTEGER NOT NULL DEFAULT 1 CHECK (active IN (0, 1))
);
CREATE TABLE IF NOT EXISTS documents (
    id TEXT PRIMARY KEY,
    owner_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    name TEXT NOT NULL,
    uploaded_at TEXT NOT NULL,
    status TEXT NOT NULL DEFAULT 'queued'
      CHECK (status IN ('queued', 'processing', 'ready', 'failed', 'deleting')),
    processed_pages INTEGER NOT NULL DEFAULT 0 CHECK (processed_pages >= 0),
    total_pages INTEGER CHECK (total_pages IS NULL OR total_pages >= 0)
);
CREATE INDEX IF NOT EXISTS documents_owner_date ON documents(owner_id, uploaded_at DESC, id DESC);
CREATE TABLE IF NOT EXISTS chunks (
    id TEXT PRIMARY KEY,
    document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    page_number INTEGER NOT NULL CHECK (page_number >= 1),
    element_type TEXT NOT NULL,
    content TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS chunks_document ON chunks(document_id);
CREATE TABLE IF NOT EXISTS embeddings (
    chunk_id TEXT PRIMARY KEY REFERENCES chunks(id) ON DELETE CASCADE,
    vector BLOB NOT NULL
);
CREATE TABLE IF NOT EXISTS conversations (
    id TEXT PRIMARY KEY,
    document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    title TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS conversations_document ON conversations(document_id);
CREATE TABLE IF NOT EXISTS messages (
    id TEXT PRIMARY KEY,
    conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
    role TEXT NOT NULL,
    content TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS messages_conversation ON messages(conversation_id);
CREATE TABLE IF NOT EXISTS processing_jobs (
    id TEXT PRIMARY KEY,
    document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
    status TEXT NOT NULL,
    next_page INTEGER NOT NULL DEFAULT 1
);
CREATE INDEX IF NOT EXISTS jobs_document ON processing_jobs(document_id);
"""


def get_db():
    if 'db' not in g:
        db = sqlite3.connect(current_app.config['DATABASE_PATH'], timeout=10)
        db.row_factory = sqlite3.Row
        db.execute('PRAGMA foreign_keys = ON')
        db.create_function('casefold', 1, str.casefold, deterministic=True)
        g.db = db
    return g.db


@contextmanager
def transaction():
    db = get_db()
    db.execute('BEGIN IMMEDIATE')
    try:
        yield db
        db.commit()
    except BaseException:
        db.rollback()
        raise


def initialize():
    path = Path(current_app.config['DATABASE_PATH'])
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    db = get_db()
    path.chmod(0o600)
    db.execute('PRAGMA journal_mode = WAL')
    version = db.execute('PRAGMA user_version').fetchone()[0]
    if version not in (0, 1, 2, 3):
        raise RuntimeError('Unsupported database schema version')
    db.executescript('BEGIN IMMEDIATE;\n' + SCHEMA)
    columns = {row['name'] for row in db.execute('PRAGMA table_info(processing_jobs)')}
    for name, definition in {
        'stage': "TEXT NOT NULL DEFAULT 'queued'", 'error_code': 'TEXT',
        'retryable': 'INTEGER NOT NULL DEFAULT 1', 'attempts': 'INTEGER NOT NULL DEFAULT 0',
        'lease_owner': 'TEXT', 'lease_until': 'REAL', 'updated_at': "TEXT NOT NULL DEFAULT ''",
    }.items():
        if name not in columns:
            db.execute(f'ALTER TABLE processing_jobs ADD COLUMN {name} {definition}')
    additional_schema = '''
        CREATE TABLE IF NOT EXISTS upload_requests (
            owner_id TEXT NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            upload_key TEXT NOT NULL,
            document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
            size_bytes INTEGER NOT NULL,
            sha256 TEXT NOT NULL,
            PRIMARY KEY (owner_id, upload_key)
        );
        CREATE INDEX IF NOT EXISTS upload_document ON upload_requests(document_id);
        CREATE TABLE IF NOT EXISTS document_pages (
            document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE,
            page_number INTEGER NOT NULL CHECK(page_number >= 1),
            completed_at TEXT NOT NULL,
            PRIMARY KEY (document_id, page_number)
        );
    '''
    for statement in additional_schema.split(';'):
        if statement.strip():
            db.execute(statement)
    for table, definitions in {
        'processing_jobs': {'pipeline_fingerprint': 'TEXT', 'parser_context_json': "TEXT NOT NULL DEFAULT '{}'"},
        'documents': {'index_profile': 'TEXT', 'vector_store_factory': 'TEXT'},
        'chunks': {'metadata_json': "TEXT NOT NULL DEFAULT '{}'"},
        'embeddings': {'profile': 'TEXT', 'dimensions': 'INTEGER'},
        'document_pages': {'quality_json': "TEXT NOT NULL DEFAULT '{}'"},
    }.items():
        existing = {row['name'] for row in db.execute(f'PRAGMA table_info({table})')}
        for name, definition in definitions.items():
            if name not in existing:
                db.execute(f'ALTER TABLE {table} ADD COLUMN {name} {definition}')
    db.execute("CREATE TABLE IF NOT EXISTS extracted_elements (id TEXT PRIMARY KEY, "
        "document_id TEXT NOT NULL REFERENCES documents(id) ON DELETE CASCADE, page_number INTEGER NOT NULL, "
        "position INTEGER NOT NULL, element_type TEXT NOT NULL, content TEXT NOT NULL, metadata_json TEXT NOT NULL)")
    db.execute('CREATE INDEX IF NOT EXISTS elements_document_page ON extracted_elements(document_id,page_number)')
    db.execute("CREATE TABLE IF NOT EXISTS processing_warnings (document_id TEXT NOT NULL REFERENCES documents(id) "
        "ON DELETE CASCADE, page_number INTEGER NOT NULL, code TEXT NOT NULL, detail_json TEXT NOT NULL, "
        "PRIMARY KEY(document_id,page_number,code))")
    db.execute('PRAGMA user_version = 3')
    db.commit()


def close_db(_error=None):
    db = g.pop('db', None)
    if db is not None:
        db.close()
