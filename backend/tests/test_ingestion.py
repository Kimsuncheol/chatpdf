import io
import time
from uuid import uuid4

import pytest
from pypdf import PdfReader, PdfWriter
from reportlab.pdfgen.canvas import Canvas

from chatpdf.db import get_db, transaction
from chatpdf.ingestion import claim_job, checkpoint, run_job
from chatpdf.pipeline.services import get_services


def pdf_bytes(pages=5):
    stream = io.BytesIO()
    canvas = Canvas(stream)
    for page in range(1, pages + 1):
        canvas.drawString(72, 720, f'ChatPDF evidence on original page {page}.')
        canvas.showPage()
    canvas.save()
    return stream.getvalue()


def submit(client, headers, data=None, key=None, name='Research.pdf'):
    return client.post('/api/v1/documents/upload', data=pdf_bytes() if data is None else data,
        content_type='application/pdf', headers=headers | {
            'Idempotency-Key': key or str(uuid4()), 'X-Filename': name})


def fake_batch(job, start, end):
    return {'pages': list(range(start, end + 1)), 'elements': [
        {'page_number': page, 'element_type': 'table', 'content': f'Evidence on page {page}'}
        for page in range(start, end + 1)]}


def test_upload_is_authenticated_and_idempotent(app, client, headers):
    key = str(uuid4())
    assert submit(client, {}, key=key).status_code == 401
    response = submit(client, headers(), key=key)
    assert response.status_code == 202
    document = response.json['document']
    assert document['status'] == 'queued' and document['total_pages'] == 5
    assert response.json['job']['next_page'] == 1
    assert submit(client, headers(), key=key).json['document']['id'] == document['id']
    assert client.get(f'/api/v1/uploads/{key}', headers=headers()).json['document']['id'] == document['id']
    with app.app_context():
        assert get_db().execute('SELECT count(*) FROM documents').fetchone()[0] == 1
        assert get_db().execute('SELECT count(*) FROM processing_jobs').fetchone()[0] == 1
    stored = app.extensions['document_storage'].directory(document['id']) / 'original.pdf'
    assert stored.read_bytes().startswith(b'%PDF-')
    assert not list((stored.parent.parent / '.incoming').iterdir())


@pytest.mark.parametrize('kind,code', [('text', 'corrupt_pdf'), ('broken', 'corrupt_pdf'),
                                      ('encrypted', 'encrypted_pdf'), ('extension', 'unsupported_pdf')])
def test_invalid_files_leave_no_documents_or_jobs(app, client, headers, kind, code):
    data, name = pdf_bytes(1), 'Document.pdf'
    if kind == 'text': data = b'not a PDF'
    if kind == 'broken': data = b'%PDF-1.7\ntruncated'
    if kind == 'encrypted':
        writer = PdfWriter(); writer.append(PdfReader(io.BytesIO(data))); writer.encrypt('test-password')
        stream = io.BytesIO(); writer.write(stream); data = stream.getvalue()
    if kind == 'extension': name = 'document.exe'
    response = submit(client, headers(), data=data, name=name)
    assert response.status_code in (415, 422)
    assert response.json['error']['code'] == code
    with app.app_context():
        assert get_db().execute('SELECT count(*) FROM documents').fetchone()[0] == 0
        assert get_db().execute('SELECT count(*) FROM processing_jobs').fetchone()[0] == 0


def test_server_byte_and_page_limits(app, client, headers):
    app.config['MAX_PDF_BYTES'] = app.config['MAX_CONTENT_LENGTH'] = 20
    response = submit(client, headers(), data=b'%PDF-' + b'a' * 100)
    assert response.status_code == 413 and response.json['error']['code'] == 'oversized_pdf'
    app.config['MAX_PDF_BYTES'] = app.config['MAX_CONTENT_LENGTH'] = 1024 * 1024
    app.config['MAX_PDF_PAGES'] = 1
    response = submit(client, headers(), data=pdf_bytes(2))
    assert response.status_code == 413 and response.json['error']['code'] == 'too_many_pages'
    assert client.get('/api/v1/uploads/limits', headers=headers()).json['max_bytes'] == 1024 * 1024


def test_job_and_upload_endpoints_are_owner_scoped(client, headers):
    key = str(uuid4())
    response = submit(client, headers(), key=key)
    document_id, job_id = response.json['document']['id'], response.json['job']['id']
    for method, route in [('get', f'uploads/{key}'), ('get', f'jobs/{job_id}'),
        ('get', f'documents/{document_id}/status'), ('post', f'documents/{document_id}/cancel'),
        ('post', f'documents/{document_id}/retry')]:
        path = f'/api/v1/{route}'
        assert getattr(client, method)(path).status_code == 401
        assert getattr(client, method)(path, headers=headers('bob')).status_code == 404
    assert client.get(f'/api/v1/jobs/{job_id}', headers=headers()).status_code == 200


def test_batch_failure_resume_and_replay_are_idempotent(app, client, headers):
    app.config['INGESTION_BATCH_PAGES'] = 2
    doc = submit(client, headers()).json['document']['id']
    def fail_second(job, start, end):
        return {'error': 'batch_timeout', 'retryable': True} if start == 3 else fake_batch(job, start, end)
    with app.app_context():
        run_job(claim_job(), parser=fail_second)
    state = client.get(f'/api/v1/documents/{doc}/status', headers=headers()).json
    assert state['document']['processed_pages'] == 2 and state['job']['next_page'] == 3
    assert state['job']['status'] == 'failed'
    assert client.post(f'/api/v1/documents/{doc}/retry', headers=headers()).status_code == 200
    resumed = []
    def resume(job, start, end):
        resumed.append((start, end)); return fake_batch(job, start, end)
    with app.app_context():
        run_job(claim_job(), parser=resume)
        assert get_db().execute('SELECT count(*) FROM chunks').fetchone()[0] == 5
        ids = {row[0] for row in get_db().execute('SELECT id FROM chunks')}
        with transaction() as db:
            db.execute("UPDATE processing_jobs SET next_page=1,status='queued'")
        run_job(claim_job(), parser=fake_batch)
        assert ids == {row[0] for row in get_db().execute('SELECT id FROM chunks')}
        assert get_db().execute('SELECT count(*) FROM document_pages').fetchone()[0] == 5
    assert resumed == [(3, 4), (5, 5)]
    state = client.get(f'/api/v1/documents/{doc}/status', headers=headers()).json
    assert state['document']['status'] == 'ready' and state['document']['processed_pages'] == 5


def test_expired_lease_is_reclaimed_and_stale_worker_cannot_publish(app, client, headers):
    submit(client, headers())
    with app.app_context():
        old = claim_job()
        with transaction() as db:
            db.execute('UPDATE processing_jobs SET lease_until=?', (time.time() - 1,))
        fresh = claim_job()
        assert old['lease_owner'] != fresh['lease_owner']
        assert checkpoint(old, 1, 3, fake_batch(old, 1, 3), [], [], {}, get_services()) is False
        run_job(fresh, parser=fake_batch)
        assert get_db().execute('SELECT count(*) FROM document_pages').fetchone()[0] == 5


def test_cancel_preserves_batches_and_rejects_late_publish(app, client, headers):
    app.config['INGESTION_BATCH_PAGES'] = 2
    doc = submit(client, headers()).json['document']['id']
    def cancel_midway(job, start, end):
        if start == 3:
            assert client.post(f'/api/v1/documents/{doc}/cancel', headers=headers()).status_code == 200
        return fake_batch(job, start, end)
    with app.app_context():
        run_job(claim_job(), parser=cancel_midway)
    state = client.get(f'/api/v1/documents/{doc}/status', headers=headers()).json
    assert state['document']['processed_pages'] == 2 and state['job']['status'] == 'cancelled'
    client.post(f'/api/v1/documents/{doc}/retry', headers=headers())
    with app.app_context():
        run_job(claim_job(), parser=fake_batch)
    assert client.get(f'/api/v1/documents/{doc}/status', headers=headers()).json['document']['status'] == 'ready'


def test_delete_during_parse_cannot_recreate_content(app, client, headers):
    app.config['INGESTION_BATCH_PAGES'] = 2
    doc = submit(client, headers()).json['document']['id']
    def deleting(job, start, end):
        if start > 1:
            assert client.delete(f'/api/v1/documents/{doc}', headers=headers()).status_code == 204
        return fake_batch(job, start, end)
    with app.app_context():
        run_job(claim_job(), parser=deleting)
        assert get_db().execute('SELECT count(*) FROM chunks').fetchone()[0] == 0
        assert get_db().execute('SELECT count(*) FROM upload_requests').fetchone()[0] == 0
        assert get_db().execute('SELECT count(*) FROM document_pages').fetchone()[0] == 0
    assert not app.extensions['document_storage'].directory(doc).exists()


def test_real_docling_worker_preserves_original_page_numbers(app, client, headers):
    app.config['INGESTION_BATCH_PAGES'] = 2
    app.config['INGESTION_BATCH_TIMEOUT'] = 90
    doc = submit(client, headers(), data=pdf_bytes(3)).json['document']['id']
    with app.app_context():
        run_job(claim_job())
        job = get_db().execute('SELECT * FROM processing_jobs WHERE document_id=?', (doc,)).fetchone()
        assert job['status'] == 'completed', dict(job)
        elements = get_db().execute('SELECT page_number,element_type,content FROM chunks ORDER BY page_number').fetchall()
        assert {row['page_number'] for row in elements} == {1, 2, 3}
        for page in (1, 2, 3):
            assert any(f'original page {page}' in row['content'] and row['page_number'] == page for row in elements)
        assert all(row['element_type'] for row in elements)


def test_empty_text_document_fails_safely_and_cannot_retry_without_new_source(app, client, headers):
    writer = PdfWriter(); writer.add_blank_page(width=612, height=792)
    stream = io.BytesIO(); writer.write(stream)
    doc = submit(client, headers(), data=stream.getvalue()).json['document']['id']
    with app.app_context():
        run_job(claim_job(), parser=lambda job, start, end: {'pages': [1], 'elements': []})
    state = client.get(f'/api/v1/documents/{doc}/status', headers=headers()).json
    assert state['job']['error_code'] == 'no_readable_content'
    assert not state['job']['retryable'] and state['document']['processed_pages'] == 1
    assert client.post(f'/api/v1/documents/{doc}/retry', headers=headers()).status_code == 409


def test_crash_orphans_are_reaped_but_owned_documents_are_preserved(app, client, headers):
    import os
    from chatpdf.storage import reap_abandoned_uploads
    doc = submit(client, headers()).json['document']['id']
    storage = app.extensions['document_storage']
    owned = storage.directory(doc)
    orphan = storage.directory(str(uuid4())); orphan.mkdir(); (orphan / 'original.pdf').write_bytes(b'orphan')
    old_part = storage.root / '.incoming' / 'old.part'; old_part.write_bytes(b'partial')
    new_part = storage.root / '.incoming' / 'new.part'; new_part.write_bytes(b'active')
    before = time.time() - 90000
    for entry in (owned, orphan, old_part): os.utime(entry, (before, before))
    with app.app_context():
        assert reap_abandoned_uploads() == 2
    assert owned.exists() and new_part.exists()
    assert not orphan.exists() and not old_part.exists()


def test_schema_migration_preserves_existing_documents(app, client, headers):
    from chatpdf.db import initialize
    doc = submit(client, headers()).json['document']['id']
    with app.app_context():
        # Version markers and repeated initialization do not rebuild/drop content.
        get_db().execute('PRAGMA user_version=1')
        get_db().commit()
        initialize(); initialize()
        assert get_db().execute('PRAGMA user_version').fetchone()[0] == 4
        assert get_db().execute('SELECT id FROM documents WHERE id=?', (doc,)).fetchone()[0] == doc
        assert get_db().execute('SELECT count(*) FROM upload_requests').fetchone()[0] == 1
