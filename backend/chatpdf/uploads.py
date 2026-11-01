import hashlib
import json
import os
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import unquote
from uuid import uuid4

from flask import Blueprint, current_app, g, jsonify, request
from werkzeug.exceptions import ClientDisconnected

from .auth import authenticated
from .db import get_db, transaction
from .documents import owned_document, public_document
from .errors import ApiError
from .storage import canonical_id

bp = Blueprint('uploads', __name__, url_prefix='/api/v1')
PDF_ERRORS = {
    'unsupported_pdf': 'Choose a file with a .pdf extension and PDF content type.',
    'corrupt_pdf': 'This PDF is corrupt or cannot be read. Export a new copy and try again.',
    'encrypted_pdf': 'Password-protected PDFs are not supported. Upload an unencrypted copy.',
    'oversized_pdf': 'This PDF exceeds the upload size limit.',
    'too_many_pages': 'This PDF exceeds the server page limit.',
    'validation_timeout': 'PDF validation took too long. Try a smaller PDF.',
}


def now():
    return datetime.now(timezone.utc).isoformat()


def job_payload(document_id):
    job = get_db().execute('SELECT * FROM processing_jobs WHERE document_id = ? ORDER BY rowid DESC LIMIT 1',
                           (document_id,)).fetchone()
    if job is None:
        return None
    payload = {key: job[key] for key in (
        'id', 'document_id', 'status', 'stage', 'next_page', 'error_code', 'retryable', 'attempts', 'updated_at')}
    payload['warning_count'] = get_db().execute('SELECT count(*) FROM processing_warnings WHERE document_id=?',
                                               (document_id,)).fetchone()[0]
    payload['low_text_pages'] = get_db().execute("SELECT count(*) FROM processing_warnings WHERE document_id=? AND code='little_or_no_text'",
                                                (document_id,)).fetchone()[0]
    return payload


def receipt(document):
    return {'document': public_document(document), 'job': job_payload(document['id'])}


def accepted_upload(key):
    return get_db().execute('SELECT d.* FROM upload_requests u JOIN documents d ON d.id = u.document_id '
                            'WHERE u.owner_id = ? AND u.upload_key = ?', (g.user['id'], key)).fetchone()


@bp.get('/uploads/limits')
@authenticated
def limits():
    return jsonify(max_bytes=current_app.config['MAX_PDF_BYTES'], max_pages=current_app.config['MAX_PDF_PAGES'])


@bp.get('/uploads/<upload_key>')
@authenticated
def lookup(upload_key):
    if not canonical_id(upload_key):
        raise ApiError(404, 'not_found', 'Upload not found.')
    document = accepted_upload(upload_key)
    if document is None:
        raise ApiError(404, 'not_found', 'Upload not found.')
    return jsonify(receipt(document))


@bp.post('/documents/upload')
@authenticated
def upload():
    key = request.headers.get('Idempotency-Key', '')
    if not canonical_id(key):
        raise ApiError(400, 'invalid_upload_key', 'A UUID idempotency key is required.')
    existing = accepted_upload(key)
    if existing is not None:
        if existing['status'] == 'deleting':
            raise ApiError(409, 'document_unavailable', 'This document is being deleted.')
        return jsonify(receipt(existing)), 200
    encoded_name = request.headers.get('X-Filename', '')
    if len(encoded_name) > 2048:
        raise ApiError(415, 'unsupported_pdf', PDF_ERRORS['unsupported_pdf'])
    name = unquote(encoded_name).replace('\\', '/').rsplit('/', 1)[-1].strip()
    if (request.mimetype != 'application/pdf' or not name.lower().endswith('.pdf') or
            not name or len(name) > 255 or any(ord(char) < 32 for char in name)):
        raise ApiError(415, 'unsupported_pdf', PDF_ERRORS['unsupported_pdf'])
    maximum = current_app.config['MAX_PDF_BYTES']
    if request.content_length is not None and request.content_length > maximum:
        raise ApiError(413, 'oversized_pdf', PDF_ERRORS['oversized_pdf'])
    storage = current_app.extensions['document_storage']
    staging = storage.root / '.incoming'
    staging.mkdir(exist_ok=True, mode=0o700)
    document_id = str(uuid4())
    published = False
    directory_created = False
    try:
        with tempfile.NamedTemporaryFile(dir=staging, suffix='.part', delete=False) as stream:
            temporary = Path(stream.name)
            size = 0
            digest = hashlib.sha256()
            while block := request.stream.read(64 * 1024):
                size += len(block)
                if size > maximum:
                    raise ApiError(413, 'oversized_pdf', PDF_ERRORS['oversized_pdf'])
                digest.update(block)
                stream.write(block)
            stream.flush()
            os.fsync(stream.fileno())
        try:
            result = subprocess.run(
                [sys.executable, '-m', 'chatpdf.pdf_validation', str(temporary), str(current_app.config['MAX_PDF_PAGES'])],
                cwd=Path(__file__).resolve().parent.parent,
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                timeout=current_app.config['PDF_VALIDATION_TIMEOUT'], check=True,
            )
            validation = json.loads(result.stdout)
        except subprocess.TimeoutExpired:
            raise ApiError(422, 'validation_timeout', PDF_ERRORS['validation_timeout']) from None
        except (subprocess.SubprocessError, ValueError):
            raise ApiError(422, 'corrupt_pdf', PDF_ERRORS['corrupt_pdf']) from None
        if validation.get('error'):
            code = validation['error']
            raise ApiError(413 if code == 'too_many_pages' else 422, code, PDF_ERRORS[code])
        with transaction() as db:
            # Serialize duplicate concurrent submissions after streaming/validation.
            existing = accepted_upload(key)
            if existing is not None:
                return jsonify(receipt(existing)), 200
            directory = storage.directory(document_id)
            directory.mkdir(mode=0o700)
            directory_created = True
            os.replace(temporary, directory / 'original.pdf')
            db.execute('INSERT INTO documents(id, owner_id, name, uploaded_at, total_pages) VALUES (?,?,?,?,?)',
                       (document_id, g.user['id'], name, now(), validation['total_pages']))
            db.execute('INSERT INTO processing_jobs(id, document_id, status, stage, updated_at) VALUES (?,?,?,?,?)',
                       (str(uuid4()), document_id, 'queued', 'queued', now()))
            db.execute('INSERT INTO upload_requests VALUES (?,?,?,?,?)',
                       (g.user['id'], key, document_id, size, digest.hexdigest()))
        published = True
        return jsonify(receipt(owned_document(document_id))), 202
    except ClientDisconnected:
        raise ApiError(400, 'upload_interrupted', 'Upload stopped before all bytes arrived. Retry the same file.') from None
    finally:
        if 'temporary' in locals():
            temporary.unlink(missing_ok=True)
        if not published and directory_created and storage.directory(document_id).exists():
            storage.delete(document_id)


@bp.get('/documents/<document_id>/status')
@authenticated
def status(document_id):
    return jsonify(receipt(owned_document(document_id)))


def owned_job(document_id):
    document = owned_document(document_id)
    job = get_db().execute('SELECT * FROM processing_jobs WHERE document_id = ? ORDER BY rowid DESC LIMIT 1',
                           (document_id,)).fetchone()
    if document['status'] == 'deleting' or job is None:
        raise ApiError(409, 'document_unavailable', 'Document cannot be processed.')
    return document, job


@bp.post('/documents/<document_id>/cancel')
@authenticated
def cancel(document_id):
    with transaction() as db:
        _, job = owned_job(document_id)
        if job['status'] in ('queued', 'running'):
            db.execute("UPDATE processing_jobs SET status='cancelled', stage='cancelled', lease_owner=NULL, "
                       "lease_until=NULL, retryable=1, updated_at=? WHERE id=?", (now(), job['id']))
            # Preserve original schema CHECK and all completed page batches.
            db.execute("UPDATE documents SET status='failed' WHERE id=?", (document_id,))
    return jsonify(receipt(owned_document(document_id)))


@bp.post('/documents/<document_id>/retry')
@authenticated
def retry(document_id):
    with transaction() as db:
        _, job = owned_job(document_id)
        if job['status'] in ('failed', 'cancelled'):
            if not job['retryable']:
                raise ApiError(409, 'not_retryable', 'Choose another PDF; this failure cannot be retried.')
            db.execute("UPDATE processing_jobs SET status='queued', stage='queued', error_code=NULL, "
                       "lease_owner=NULL, lease_until=NULL, updated_at=? WHERE id=?", (now(), job['id']))
            db.execute("UPDATE documents SET status='queued' WHERE id=?", (document_id,))
    return jsonify(receipt(owned_document(document_id)))


@bp.get('/jobs/<job_id>')
@authenticated
def job_status(job_id):
    if not canonical_id(job_id):
        raise ApiError(404, 'not_found', 'Job not found.')
    job = get_db().execute('SELECT j.document_id FROM processing_jobs j JOIN documents d ON d.id=j.document_id '
                           'WHERE j.id=? AND d.owner_id=?', (job_id, g.user['id'])).fetchone()
    if job is None:
        raise ApiError(404, 'not_found', 'Job not found.')
    return jsonify(receipt(owned_document(job['document_id'])))
