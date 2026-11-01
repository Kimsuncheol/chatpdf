from flask import Blueprint, current_app, g, jsonify, request

from ..auth import authenticated
from ..db import get_db, transaction
from ..documents import owned_document
from ..errors import ApiError
from ..uploads import now
from .config import import_factory
from .services import get_services

bp = Blueprint('retrieval', __name__, url_prefix='/api/v1/documents')
WARNING_MESSAGES = {
    'native_structure_limited': 'Native parsing does not identify headings, table structure or reading order.',
    'ocr_disabled_in_native_mode': 'OCR is unavailable in native mode.',
    'docling_warning': 'Docling reported a conversion warning; see its category and component.',
    'ocr_orientation_failed': 'OCR orientation detection was inconclusive in this batch; review extracted text.',
    'docling_runtime_warning': 'Docling logged a runtime warning in this batch.',
    'partial_conversion': 'Some conversion steps were incomplete in this batch.',
    'little_or_no_text': 'This page has little or no extractable text; it may need OCR or be mostly visual.',
    'visual_content_not_interpreted': 'Figure location/caption retained; visual or chart meaning was not interpreted.',
    'table_at_batch_boundary': 'A table touches a page-batch boundary; cross-batch table continuity is not inferred.',
    'table_chunked_by_rows': 'A large table was split between row groups, repeating available headers.',
    'oversized_atomic_chunk': 'An intact row or heading exceeded the configured chunk limit.',
}


def retrieve(owner_id, document_id, query, k=4):
    row = get_db().execute('SELECT * FROM documents WHERE id=? AND owner_id=?', (document_id, owner_id)).fetchone()
    if row is None: raise ApiError(404, 'not_found', 'Document not found.')
    if row['status'] != 'ready': raise ApiError(409, 'not_ready', 'Wait for processing to complete.')
    if not isinstance(query, str) or not query.strip() or len(query) > 2000 or type(k) is not int or not 1 <= k <= 20:
        raise ApiError(400, 'invalid_query', 'Supply a nonempty query (max 2000 characters) and k from 1 to 20.')
    services = get_services()
    if row['index_profile'] != services.settings.fingerprint:
        raise ApiError(409, 'reindex_required', 'Index configuration changed; reindex the document.')
    # This is a LangChain retriever, bounded to this authoritative owner/document.
    retriever = services.store(owner_id, document_id).as_retriever(search_kwargs={'k': k})
    return retriever.invoke(query.strip())


@bp.post('/<document_id>/search')
@authenticated
def search(document_id):
    owned_document(document_id)
    body = request.get_json(silent=True)
    if not isinstance(body, dict): raise ApiError(400, 'invalid_query', 'A query is required.')
    try:
        documents = retrieve(g.user['id'], document_id, body.get('query'), body.get('k', 4))
    except ApiError:
        raise
    except Exception as error:
        current_app.logger.error('Retrieval provider failed: %s', type(error).__name__)
        raise ApiError(503, 'retrieval_unavailable', 'The retrieval provider is unavailable. Please retry.') from None
    return jsonify(matches=[{'id': doc.id, 'content': doc.page_content, 'metadata': doc.metadata} for doc in documents],
        notice='Retrieved source evidence, not a generated answer. Figure/chart meaning has not been interpreted.')


@bp.get('/<document_id>/processing-report')
@authenticated
def processing_report(document_id):
    import json
    owned_document(document_id)
    raw_after, raw_limit = request.args.get('after_page', '0'), request.args.get('limit', '50')
    if (not raw_after.isascii() or not raw_after.isdecimal() or len(raw_after) > 6 or
        not raw_limit.isascii() or not raw_limit.isdecimal() or len(raw_limit) > 3 or not 1 <= int(raw_limit) <= 100):
        raise ApiError(400, 'invalid_pagination', 'Invalid report page parameters.')
    rows = get_db().execute('SELECT candidate.page_number,p.quality_json,p.completed_at FROM '
        '(SELECT page_number FROM document_pages WHERE document_id=? UNION '
        'SELECT page_number FROM processing_warnings WHERE document_id=? AND page_number>0) candidate '
        'LEFT JOIN document_pages p ON p.document_id=? AND p.page_number=candidate.page_number '
        'WHERE candidate.page_number>? ORDER BY candidate.page_number LIMIT ?',
        (document_id, document_id, document_id, int(raw_after), int(raw_limit)+1)).fetchall()
    selected = rows[:int(raw_limit)]
    pages = []
    for row in selected:
        warnings = get_db().execute('SELECT code,detail_json FROM processing_warnings WHERE document_id=? AND page_number=?',
            (document_id, row['page_number'])).fetchall()
        pages.append(json.loads(row['quality_json'] or '{}') | {'page_number': row['page_number'],
            'completed': row['completed_at'] is not None, 'warnings': [
            {'code': item['code'], 'message': WARNING_MESSAGES.get(item['code'], 'Parser warning'),
             'detail': json.loads(item['detail_json'])} for item in warnings]})
    summary = get_db().execute('SELECT code,count(*) AS count FROM processing_warnings WHERE document_id=? GROUP BY code',
                               (document_id,)).fetchall()
    global_warnings = get_db().execute('SELECT code,detail_json FROM processing_warnings WHERE document_id=? AND page_number=0',
                                      (document_id,)).fetchall()
    return jsonify(pages=pages, document_warnings=[{'code': item['code'],
        'message': WARNING_MESSAGES.get(item['code'], 'Parser warning'), 'detail': json.loads(item['detail_json'])}
        for item in global_warnings], warning_summary=[{'code': row['code'], 'count': row['count'],
        'message': WARNING_MESSAGES.get(row['code'], 'Parser warning')} for row in summary],
        next_page=selected[-1]['page_number'] if len(rows)>int(raw_limit) else None)


def queue_reindex(owner_id, document_id):
    """Explicitly regenerate derived data while retaining PDF and conversations."""
    from uuid import uuid4
    with transaction() as db:
        doc = db.execute('SELECT * FROM documents WHERE id=? AND owner_id=?', (document_id, owner_id)).fetchone()
        if doc is None: raise ApiError(404, 'not_found', 'Document not found.')
        if doc['status'] == 'deleting': raise ApiError(409, 'document_unavailable', 'Document is being deleted.')
        if doc['vector_store_factory']:
            old_store = import_factory(doc['vector_store_factory'])(dict(current_app.config),
                owner_id=owner_id, document_id=document_id, embedding=None, profile=doc['index_profile'])
            old_store.delete_document(db)
        # Invalidate the lease so old parse/embedding results cannot publish.
        db.execute("UPDATE processing_jobs SET status='queued',stage='queued',next_page=1,error_code=NULL,retryable=1, "
            "lease_owner=NULL,lease_until=NULL,pipeline_fingerprint=NULL,parser_context_json='{}',updated_at=? WHERE document_id=?",
            (now(), document_id))
        if db.execute('SELECT 1 FROM processing_jobs WHERE document_id=?', (document_id,)).fetchone() is None:
            db.execute('INSERT INTO processing_jobs(id,document_id,status,stage,updated_at) VALUES (?,?,?,?,?)',
                       (str(uuid4()), document_id, 'queued', 'queued', now()))
        db.execute('DELETE FROM document_pages WHERE document_id=?', (document_id,))
        db.execute('DELETE FROM processing_warnings WHERE document_id=?', (document_id,))
        db.execute("UPDATE documents SET status='queued',processed_pages=0,index_profile=NULL WHERE id=?", (document_id,))
