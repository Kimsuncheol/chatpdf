"""SQLite durable queue, fenced leases, and atomic page-batch checkpoints."""
import json
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from uuid import uuid4
from concurrent.futures import ThreadPoolExecutor
from threading import Event

from flask import current_app

from .db import get_db, transaction
from .uploads import now
from .pipeline.contracts import IndexCompatibilityError


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


def save_warnings(job, warnings, connection=None):
    def persist(db):
        if active_job(job, db) is None:
            return
        grouped = {}
        for item in warnings:
            key = (item['page_number'], item['code'])
            detail = item.get('detail', {})
            if detail not in grouped.setdefault(key, []) and len(grouped[key]) < 64:
                grouped[key].append(detail)
        for (page, code), details in grouped.items():
            detail = details[0] if len(details) == 1 else {'occurrences': details}
            db.execute('INSERT INTO processing_warnings(document_id,page_number,code,detail_json) VALUES (?,?,?,?) '
                'ON CONFLICT(document_id,page_number,code) DO UPDATE SET detail_json=excluded.detail_json',
                (job['document_id'], page, code, json.dumps(detail)))
    if connection is None:
        with transaction() as db:
            persist(db)
    else:
        persist(connection)


def checkpoint(job, start, end, output, documents, vectors, context, services):
    if output.get('pages') != list(range(start, end + 1)):
        raise ValueError('Incomplete page batch')
    with transaction() as db:
        current = active_job(job, db)
        if current is None or current['next_page'] != start or current['pipeline_fingerprint'] != services.settings.fingerprint:
            return False
        owner = db.execute('SELECT owner_id FROM documents WHERE id=?', (job['document_id'],)).fetchone()[0]
        store = services.store(owner, job['document_id'])
        db.execute('DELETE FROM chunks WHERE document_id=? AND page_number BETWEEN ? AND ?',
                   (job['document_id'], start, end))
        db.execute('DELETE FROM extracted_elements WHERE document_id=? AND page_number BETWEEN ? AND ?',
                   (job['document_id'], start, end))
        db.execute('DELETE FROM processing_warnings WHERE document_id=? AND page_number BETWEEN ? AND ?',
                   (job['document_id'], start, end))
        for element in output['elements']:
            if not start <= element['page_number'] <= end:
                raise ValueError('Page outside current batch')
            db.execute('INSERT INTO extracted_elements VALUES (?,?,?,?,?,?,?)',
                (element['id'], job['document_id'], element['page_number'], element['position'],
                 element['element_type'], element['content'], json.dumps(element['metadata'])))
        for document in documents:
            db.execute('INSERT INTO chunks(id,document_id,page_number,element_type,content,metadata_json) VALUES (?,?,?,?,?,?)',
                (document.id, job['document_id'], document.metadata['page_number'],
                 document.metadata['element_type'], document.page_content, json.dumps(document.metadata)))
        # The default store shares this SQLite transaction. No vector is visible
        # without its canonical chunk, raw elements and completed-page checkpoint.
        store.publish(db, documents, vectors)
        quality = {item['page_number']: item for item in output.get('page_quality', [])}
        for page in range(start, end + 1):
            db.execute('INSERT INTO document_pages(document_id,page_number,completed_at,quality_json) VALUES (?,?,?,?) '
                'ON CONFLICT(document_id,page_number) DO UPDATE SET completed_at=excluded.completed_at,quality_json=excluded.quality_json',
                (job['document_id'], page, now(), json.dumps(quality.get(page, {}))))
        save_warnings(job, output.get('warnings', []), db)
        count = db.execute('SELECT count(*) FROM document_pages WHERE document_id=?', (job['document_id'],)).fetchone()[0]
        db.execute('UPDATE documents SET processed_pages=?, vector_store_factory=? WHERE id=?',
                   (count, services.settings.vector_factory, job['document_id']))
        db.execute("UPDATE processing_jobs SET next_page=?, stage='extracting', parser_context_json=?, lease_until=?, updated_at=? WHERE id=?",
            (end + 1, json.dumps(context), time.time() + current_app.config['INGESTION_LEASE_SECONDS'], now(), job['id']))
    return True


def finish_job(job, services):
    with transaction() as db:
        current = active_job(job, db)
        if current is None:
            return
        row = db.execute('SELECT owner_id,total_pages,processed_pages FROM documents WHERE id=?', (job['document_id'],)).fetchone()
        chunks = db.execute('SELECT count(*) FROM chunks WHERE document_id=?', (job['document_id'],)).fetchone()[0]
        indexed = services.store(row['owner_id'], job['document_id']).count_indexed(db)
        if row['processed_pages'] != row['total_pages'] or indexed != chunks:
            raise IndexCompatibilityError('Index/checkpoint is incomplete; reindex required')
        state = 'completed' if chunks else 'failed'
        db.execute('UPDATE processing_jobs SET status=?, stage=?, error_code=?, retryable=0, lease_owner=NULL, '
                   'lease_until=NULL, updated_at=? WHERE id=?',
                   (state, state, None if chunks else 'no_readable_content', now(), job['id']))
        db.execute('UPDATE documents SET status=?,index_profile=? WHERE id=?',
                   ('ready' if chunks else 'failed', services.settings.fingerprint if chunks else None, job['document_id']))


def set_stage(job, stage):
    with transaction() as db:
        if active_job(job, db) is None:
            return False
        db.execute('UPDATE processing_jobs SET stage=?, lease_until=?, updated_at=? WHERE id=?',
            (stage, time.time() + current_app.config['INGESTION_LEASE_SECONDS'], now(), job['id']))
    return True


def embed_with_lease(job, services, documents):
    if not documents:
        return []
    stop = Event()
    executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix='embedding-batch')
    future = executor.submit(services.embed, documents, stop)
    began = last_heartbeat = time.monotonic()
    try:
        while not future.done():
            if active_job(job) is None:
                return None
            if time.monotonic() - began > current_app.config['EMBEDDING_TASK_TIMEOUT']:
                raise TimeoutError('Embedding task exceeded timeout')
            if time.monotonic() - last_heartbeat > min(5, current_app.config['INGESTION_LEASE_SECONDS'] / 3):
                if not heartbeat(job): return None
                last_heartbeat = time.monotonic()
            time.sleep(0.2)
        return future.result()
    finally:
        stop.set()
        executor.shutdown(wait=False, cancel_futures=True)


def parse_in_process(job, start, end):
    settings = {'pipeline': current_app.config['DOCLING_PIPELINE'], 'ocr': current_app.config['DOCLING_OCR'],
        'timeout': current_app.config['INGESTION_BATCH_TIMEOUT'], 'artifacts': current_app.config['DOCLING_ARTIFACTS_PATH'],
        'ocr_engine': current_app.config['DOCLING_OCR_ENGINE'],
        'ocr_languages': current_app.config['DOCLING_OCR_LANGUAGES'],
        'ocr_full_page': current_app.config['DOCLING_OCR_FORCE_FULL_PAGE'],
        'low_text_characters': current_app.config['LOW_TEXT_CHARACTERS'], 'total_pages': job['total_pages']}
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


def run_job(job, parser=None):
    from .pipeline.services import get_services
    from .pipeline.chunking import ChunkLimitError, materialize_elements
    try:
        services = get_services()
    except Exception as error:
        current_app.logger.error('Pipeline configuration failed: %s', type(error).__name__)
        fail_job(job, 'worker_configuration', True)
        return
    with transaction() as db:
        current = active_job(job, db)
        if current is None: return
        previous = current['pipeline_fingerprint']
        incompatible = (previous is not None and previous != services.settings.fingerprint) or (previous is None and current['next_page'] > 1)
        if not incompatible:
            db.execute('UPDATE processing_jobs SET pipeline_fingerprint=? WHERE id=?', (services.settings.fingerprint, job['id']))
    if incompatible:
        fail_job(job, 'reindex_required', False)
        return
    total = job['total_pages']
    if not total:
        fail_job(job, 'source_missing', False)
        return
    try:
        while current := active_job(job):
            start = current['next_page']
            if start > total:
                finish_job(job, services)
                return
            end = min(start + current_app.config['INGESTION_BATCH_PAGES'] - 1, total)
            output = (parser or services.parser.parse)(job | dict(current), start, end)
            if output is None: return
            save_warnings(job, output.get('warnings', []))
            if output.get('error'):
                current_app.logger.warning('Batch failed for job %s: %s (%s)', job['id'],
                    output['error'], output.get('exception_type', 'conversion failure'))
                fail_job(job, output['error'], output.get('retryable', True))
                return
            output['elements'] = materialize_elements(job['document_id'], output['elements'])
            documents, context, warnings = services.chunker.split(job['document_id'], output['elements'],
                json.loads(current['parser_context_json']))
            output.setdefault('warnings', []).extend(warnings)
            if not set_stage(job, 'embedding'): return
            try:
                vectors = embed_with_lease(job, services, documents)
            except Exception as error:
                current_app.logger.error('Embedding failed for job %s: %s', job['id'], type(error).__name__)
                save_warnings(job, output['warnings'])
                fail_job(job, 'embedding_failed', True)
                return
            if vectors is None or not set_stage(job, 'saving'): return
            if not checkpoint(job, start, end, output, documents, vectors, context, services): return
    except IndexCompatibilityError:
        fail_job(job, 'reindex_required', False)
    except ChunkLimitError:
        save_warnings(job, [{'page_number': start, 'code': 'oversized_atomic_chunk'}])
        fail_job(job, 'chunk_too_large', False)
    except Exception as error:
        current_app.logger.error('Ingestion failed for job %s: %s', job['id'], type(error).__name__)
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
