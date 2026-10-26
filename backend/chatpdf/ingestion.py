"""SQLite durable queue, fenced leases, and atomic page-batch checkpoints."""
import json
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from uuid import NAMESPACE_URL, uuid4, uuid5

from flask import current_app

from .db import get_db, transaction
from .uploads import now


def claim_job():
    with transaction() as db:
        job = db.execute("SELECT j.*, d.total_pages FROM processing_jobs j JOIN documents d ON d.id=j.document_id "
            "WHERE d.status != 'deleting' AND (j.status='queued' OR (j.status='running' AND "
            '(j.lease_until IS NULL OR j.lease_until < ?))) ORDER BY j.rowid LIMIT 1', (time.time(),)).fetchone()
        if job is None:
            return None
        owner = str(uuid4())
        db.execute("UPDATE processing_jobs SET status='running', stage='extracting', lease_owner=?, "
            'lease_until=?, attempts=attempts+1, error_code=NULL, updated_at=? WHERE id=?',
            (owner, time.time() + current_app.config['INGESTION_LEASE_SECONDS'], now(), job['id']))
        db.execute("UPDATE documents SET status='processing' WHERE id=?", (job['document_id'],))
        return dict(job) | {'lease_owner': owner}


def active_job(job, db=None):
    db = db or get_db()
    return db.execute("SELECT j.* FROM processing_jobs j JOIN documents d ON d.id=j.document_id "
        "WHERE j.id=? AND j.status='running' AND j.lease_owner=? AND d.status != 'deleting'",
        (job['id'], job['lease_owner'])).fetchone()


def heartbeat(job):
    with transaction() as db:
        if active_job(job, db) is None:
            return False
        db.execute('UPDATE processing_jobs SET lease_until=?, updated_at=? WHERE id=? AND lease_owner=?',
            (time.time() + current_app.config['INGESTION_LEASE_SECONDS'], now(), job['id'], job['lease_owner']))
    return True


def fail_job(job, code, retryable=True):
    with transaction() as db:
        if active_job(job, db) is None:
            return
        db.execute("UPDATE processing_jobs SET status='failed', stage='failed', error_code=?, retryable=?, "
            'lease_owner=NULL, lease_until=NULL, updated_at=? WHERE id=?',
            (code, int(retryable), now(), job['id']))
        db.execute("UPDATE documents SET status='failed' WHERE id=?", (job['document_id'],))


def checkpoint(job, start, end, output):
    if output.get('pages') != list(range(start, end + 1)) or not isinstance(output.get('elements'), list):
        raise ValueError('Incomplete page batch')
    with transaction() as db:
        current = active_job(job, db)
        if current is None or current['next_page'] != start:
            return False
        db.execute("UPDATE processing_jobs SET stage='saving' WHERE id=?", (job['id'],))
        # Replace exactly this batch in the same transaction as its progress.
        # Deterministic IDs make a replay incapable of duplicating chunks.
        db.execute('DELETE FROM chunks WHERE document_id=? AND page_number BETWEEN ? AND ?',
                   (job['document_id'], start, end))
        positions = {}
        for element in output['elements']:
            page = element['page_number']
            if not isinstance(page, int) or not start <= page <= end:
                raise ValueError('Page outside current batch')
            position = positions.get(page, 0)
            positions[page] = position + 1
            chunk_id = str(uuid5(NAMESPACE_URL, f"{job['document_id']}:{page}:{position}"))
            db.execute('INSERT INTO chunks(id,document_id,page_number,element_type,content) VALUES (?,?,?,?,?)',
                (chunk_id, job['document_id'], page, element['element_type'], element['content']))
        db.executemany('INSERT INTO document_pages VALUES (?,?,?) ON CONFLICT(document_id,page_number) '
                       'DO UPDATE SET completed_at=excluded.completed_at',
                       [(job['document_id'], page, now()) for page in range(start, end + 1)])
        count = db.execute('SELECT count(*) FROM document_pages WHERE document_id=?', (job['document_id'],)).fetchone()[0]
        db.execute('UPDATE documents SET processed_pages=? WHERE id=?', (count, job['document_id']))
        db.execute("UPDATE processing_jobs SET next_page=?, stage='extracting', lease_until=?, updated_at=? WHERE id=?",
            (end + 1, time.time() + current_app.config['INGESTION_LEASE_SECONDS'], now(), job['id']))
    return True


def finish_job(job):
    with transaction() as db:
        if active_job(job, db) is None:
            return
        readable = db.execute("SELECT 1 FROM chunks WHERE document_id=? AND length(trim(content)) > 0 LIMIT 1",
                              (job['document_id'],)).fetchone()
        state = 'completed' if readable else 'failed'
        db.execute('UPDATE processing_jobs SET status=?, stage=?, error_code=?, retryable=0, lease_owner=NULL, '
                   'lease_until=NULL, updated_at=? WHERE id=?',
                   (state, state, None if readable else 'no_readable_content', now(), job['id']))
        db.execute('UPDATE documents SET status=? WHERE id=?', ('ready' if readable else 'failed', job['document_id']))


def parse_in_process(job, start, end):
    settings = {'pipeline': current_app.config['DOCLING_PIPELINE'], 'ocr': current_app.config['DOCLING_OCR'],
        'timeout': current_app.config['INGESTION_BATCH_TIMEOUT'], 'artifacts': current_app.config['DOCLING_ARTIFACTS_PATH']}
    source = current_app.extensions['document_storage'].directory(job['document_id']) / 'original.pdf'
    if not source.is_file():
        return {'error': 'source_missing', 'retryable': False}
    with tempfile.TemporaryDirectory(prefix='chatpdf-result-') as temporary:
        output = Path(temporary) / 'result.json'
        process = subprocess.Popen([sys.executable, '-m', 'chatpdf.parse_batch', str(source), str(output),
            str(start), str(end), json.dumps(settings)], cwd=Path(__file__).resolve().parent.parent,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        began = time.monotonic()
        last_heartbeat = began
        try:
            while process.poll() is None:
                # Frequent cancellation checks; only small heartbeat writes.
                if active_job(job) is None:
                    return None
                elapsed = time.monotonic() - began
                if elapsed > settings['timeout']:
                    return {'error': 'batch_timeout', 'retryable': True}
                if time.monotonic() - last_heartbeat > min(5, current_app.config['INGESTION_LEASE_SECONDS'] / 3):
                    if not heartbeat(job):
                        return None
                    last_heartbeat = time.monotonic()
                time.sleep(0.2)
            if process.returncode or not output.exists() or output.stat().st_size > 16 * 1024 * 1024:
                return {'error': 'parse_failed', 'retryable': True}
            return json.loads(output.read_text(encoding='utf-8'))
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    process.kill()
            process.wait()


def run_job(job, parser=parse_in_process):
    total = job['total_pages']
    if not total:
        fail_job(job, 'source_missing', False)
        return
    try:
        while current := active_job(job):
            start = current['next_page']
            if start > total:
                finish_job(job)
                return
            end = min(start + current_app.config['INGESTION_BATCH_PAGES'] - 1, total)
            output = parser(job, start, end)
            if output is None:
                return
            if output.get('error'):
                current_app.logger.warning('Batch failed for job %s: %s (%s)', job['id'],
                    output['error'], output.get('exception_type', 'conversion failure'))
                fail_job(job, output['error'], output.get('retryable', True))
                return
            if not checkpoint(job, start, end, output):
                return
    except Exception:
        current_app.logger.exception('Ingestion batch failed for job %s', job['id'])
        fail_job(job, 'processing_failed', True)


def run_worker(app, once=False):
    last_cleanup = 0
    while True:
        with app.app_context():
            job = claim_job()
            if job:
                run_job(job)
            elif time.monotonic() - last_cleanup > 60:
                from .storage import reap_abandoned_uploads
                reap_abandoned_uploads()
                last_cleanup = time.monotonic()
        if once:
            return
        if job is None:
            time.sleep(1)
