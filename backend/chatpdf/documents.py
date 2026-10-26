import sqlite3

from flask import Blueprint, current_app, g, jsonify, request
from itsdangerous import BadSignature, URLSafeTimedSerializer

from .auth import authenticated
from .db import get_db, transaction
from .errors import ApiError
from .storage import canonical_id

bp = Blueprint('documents', __name__, url_prefix='/api/v1/documents')
FIELDS = ('id', 'name', 'uploaded_at', 'status', 'processed_pages', 'total_pages')


def public_document(row):
    return {field: row[field] for field in FIELDS}


def owned_document(document_id):
    if not canonical_id(document_id):
        raise ApiError(404, 'not_found', 'Document not found.')
    row = get_db().execute('SELECT * FROM documents WHERE id = ? AND owner_id = ?',
                           (document_id, g.user['id'])).fetchone()
    if row is None:
        # Do not reveal whether another account owns this ID.
        raise ApiError(404, 'not_found', 'Document not found.')
    return row


def cursor_serializer():
    return URLSafeTimedSerializer(current_app.config['JWT_SECRET_KEY'], salt='document-list-v1')


@bp.get('')
@authenticated
def list_documents():
    raw_limit = request.args.get('limit', '20')
    if len(raw_limit) > 3 or not raw_limit.isascii() or not raw_limit.isdecimal() or not 1 <= int(raw_limit) <= 100:
        raise ApiError(400, 'invalid_pagination', 'Limit must be an integer between 1 and 100.')
    limit = int(raw_limit)
    query = request.args.get('q', '').strip().casefold()
    if len(query) > 200:
        raise ApiError(400, 'invalid_search', 'Search must be at most 200 characters.')
    clauses, params = ['owner_id = ?'], [g.user['id']]
    if query:
        # Literal Unicode-aware substring search: % and _ are not wildcards.
        clauses.append('instr(casefold(name), ?) > 0')
        params.append(query)
    cursor = request.args.get('cursor')
    if cursor is not None:
        try:
            if len(cursor) > 2048:
                raise ValueError()
            position = cursor_serializer().loads(cursor, max_age=86400)
            if (not isinstance(position, dict) or position.get('owner') != g.user['id'] or
                    position.get('q') != query or not isinstance(position.get('date'), str) or
                    not canonical_id(position.get('id'))):
                raise ValueError()
        except (BadSignature, ValueError, TypeError):
            raise ApiError(400, 'invalid_cursor', 'Pagination expired or is invalid. Refresh the library.') from None
        clauses.append('(uploaded_at < ? OR (uploaded_at = ? AND id < ?))')
        params.extend([position['date'], position['date'], position['id']])
    rows = get_db().execute(
        f"SELECT * FROM documents WHERE {' AND '.join(clauses)} ORDER BY uploaded_at DESC, id DESC LIMIT ?",
        [*params, limit + 1],
    ).fetchall()
    more = len(rows) > limit
    items = rows[:limit]
    next_cursor = None
    if more:
        last = items[-1]
        next_cursor = cursor_serializer().dumps({
            'owner': g.user['id'], 'q': query, 'date': last['uploaded_at'], 'id': last['id'],
        })
    return jsonify(items=[public_document(item) for item in items], next_cursor=next_cursor)


@bp.get('/<document_id>')
@authenticated
def retrieve_document(document_id):
    return jsonify(public_document(owned_document(document_id)))


@bp.delete('/<document_id>')
@authenticated
def delete_document(document_id):
    owned_document(document_id)
    try:
        # Persist the tombstone before touching files. Workers cannot publish any
        # further page batches; retries can finish after a crash/partial failure.
        with transaction() as db:
            changed = db.execute("UPDATE documents SET status = 'deleting' WHERE id = ? AND owner_id = ?",
                                 (document_id, g.user['id'])).rowcount
            if not changed:
                return '', 204  # A concurrent owned request already completed.
            db.execute("UPDATE processing_jobs SET status = 'cancelled' WHERE document_id = ?", (document_id,))
        current_app.extensions['document_storage'].delete(document_id)
        with transaction() as db:
            db.execute('DELETE FROM documents WHERE id = ? AND owner_id = ?', (document_id, g.user['id']))
            # SQLite foreign keys cascade chunks, embeddings, conversations,
            # messages, and processing jobs. All file/index artifacts are gone.
    except (OSError, sqlite3.Error):
        current_app.logger.exception('Document cleanup failed for %s', document_id)
        raise ApiError(503, 'cleanup_pending', 'Deletion is incomplete. Retry deleting this document.') from None
    return '', 204
