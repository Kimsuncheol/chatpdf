from datetime import datetime, timezone
from uuid import uuid4

import pytest
from werkzeug.security import generate_password_hash

from chatpdf import create_app
from chatpdf.auth import issue_token
from chatpdf.db import get_db, transaction


@pytest.fixture
def app(tmp_path):
    app = create_app({
        'TESTING': True,
        'DOCLING_PIPELINE': 'native',
        'EMBEDDING_PROVIDER': 'hash-demo',
        'EMBEDDING_DIMENSIONS': 256,
        'DATABASE_PATH': str(tmp_path / 'db' / 'library.sqlite3'),
        'DOCUMENT_STORAGE_ROOT': str(tmp_path / 'files'),
        'JWT_SECRET_KEY': 'test-only-secret-never-use-in-production-1234',
    })
    with app.app_context(), transaction() as db:
        db.executemany('INSERT INTO users(id,email,password_hash) VALUES (?,?,?)', [
            ('alice', 'alice@example.com', generate_password_hash('a-test-password')),
            ('bob', 'bob@example.com', generate_password_hash('b-test-password')),
        ])
    return app


@pytest.fixture
def client(app):
    return app.test_client()


@pytest.fixture
def headers(app):
    def for_user(user='alice'):
        with app.app_context():
            return {'Authorization': f'Bearer {issue_token(user)}'}
    return for_user


@pytest.fixture
def seed(app):
    def document(owner='alice', name='Research.pdf', status='ready', uploaded_at=None):
        document_id = str(uuid4())
        with app.app_context(), transaction() as db:
            db.execute('INSERT INTO documents(id,owner_id,name,uploaded_at,status,processed_pages,total_pages) '
                       'VALUES (?,?,?,?,?,8,8)', (document_id, owner, name,
                       uploaded_at or datetime.now(timezone.utc).isoformat(), status))
        directory = app.extensions['document_storage'].directory(document_id)
        directory.mkdir()
        (directory / 'original.pdf').write_bytes(b'%PDF-test')
        (directory / 'extracted').mkdir()
        (directory / 'extracted' / 'pages.ndjson').write_text('{"page_number":1,"element_type":"table"}\n')
        (directory / 'index').mkdir()
        (directory / 'index' / 'vectors.bin').write_bytes(b'index data')
        with app.app_context(), transaction() as db:
            db.execute('INSERT INTO chunks(id,document_id,page_number,element_type,content) VALUES (?,?,?,?,?)', (f'chunk-{document_id}', document_id, 1, 'table', 'Evidence'))
            db.execute('INSERT INTO embeddings(chunk_id,vector) VALUES (?,?)', (f'chunk-{document_id}', b'\x00\x01'))
            db.execute('INSERT INTO conversations VALUES (?,?,?)', (f'chat-{document_id}', document_id, 'Question'))
            db.execute('INSERT INTO messages VALUES (?,?,?,?)', (f'msg-{document_id}', f'chat-{document_id}', 'assistant', 'Answer'))
            db.execute('INSERT INTO processing_jobs(id,document_id,status,next_page) VALUES (?,?,?,?)', (f'job-{document_id}', document_id, 'running', 9))
        return document_id
    return document
