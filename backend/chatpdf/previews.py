"""Private bounded page previews; never expose storage paths or source files."""
import base64
import subprocess
import sys
import tempfile
from pathlib import Path
from threading import BoundedSemaphore

from flask import Blueprint, current_app, jsonify

from .auth import authenticated
from .documents import owned_document
from .errors import ApiError

bp = Blueprint('previews', __name__, url_prefix='/api/v1/documents')


@bp.get('/<document_id>/pages/<page_number>/preview')
@authenticated
def preview(document_id, page_number):
    document = owned_document(document_id)
    if document['status'] == 'deleting':
        raise ApiError(409, 'document_unavailable', 'This document is being deleted.')
    if (not page_number.isascii() or not page_number.isdecimal() or len(page_number) > 6 or
            not 1 <= int(page_number) <= (document['total_pages'] or 0)):
        raise ApiError(404, 'page_not_found', 'This PDF page is unavailable.')
    gate = current_app.extensions['preview_gate']
    if not gate.acquire(blocking=False):
        raise ApiError(503, 'preview_busy', 'Another preview is being rendered. Please retry.')
    try:
        source = current_app.extensions['document_storage'].directory(document_id) / 'original.pdf'
        if not source.is_file():
            raise ApiError(503, 'preview_unavailable', 'The page preview is unavailable. Read the cited text instead.')
        with tempfile.TemporaryDirectory(prefix='chatpdf-preview-') as temporary:
            target = Path(temporary) / 'page.png'
            try:
                process = subprocess.run([sys.executable, '-m', 'chatpdf.render_page', str(source), str(target),
                    page_number, str(current_app.config['PREVIEW_MAX_EDGE'])],
                    cwd=Path(__file__).resolve().parent.parent,
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                    timeout=current_app.config['PREVIEW_TIMEOUT'], check=False)
            except subprocess.TimeoutExpired:
                raise ApiError(504, 'preview_timeout', 'The page took too long to render. Read the cited text or retry.') from None
            if process.returncode or not target.is_file() or target.stat().st_size > 2 * 1024 * 1024:
                raise ApiError(503, 'preview_unavailable', 'The page preview is unavailable. Read the cited text instead.')
            # Deletion/ownership must still permit releasing bytes after rendering.
            if owned_document(document_id)['status'] == 'deleting':
                raise ApiError(409, 'document_unavailable', 'This document is being deleted.')
            return jsonify(page_number=int(page_number), mime_type='image/png',
                image_base64=base64.b64encode(target.read_bytes()).decode('ascii'))
    finally:
        gate.release()


def init_previews(app):
    app.extensions['preview_gate'] = BoundedSemaphore(1)
    app.register_blueprint(bp)
