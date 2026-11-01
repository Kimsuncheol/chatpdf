"""Local ingest/retrieve demonstration. No test framework or public server is involved."""
import argparse
import json
import secrets
from pathlib import Path
from urllib.parse import quote
from uuid import uuid4

from werkzeug.security import generate_password_hash
from dotenv import load_dotenv

from . import create_app
from .auth import issue_token
from .db import get_db, transaction
from .errors import ApiError
from .ingestion import claim_job, run_job
from .pipeline.retrieval import queue_reindex, retrieve


def create_sample(path):
    from PIL import Image, ImageDraw, ImageFont
    from reportlab.lib import colors
    from reportlab.lib.utils import ImageReader
    from reportlab.pdfgen.canvas import Canvas
    from reportlab.platypus import Table, TableStyle
    canvas = Canvas(str(path))
    canvas.setFont('Helvetica-Bold', 22); canvas.drawString(60, 770, 'Project funding review')
    canvas.setFont('Helvetica', 12)
    canvas.drawString(60, 735, 'The following table records approved and proposed project funding.')
    table = Table([['Project', 'Budget USD', 'Status'], ['Aurora', '42000', 'Approved'],
                   ['Boreal', '17000', 'Proposed'], ['Cedar', '9000', 'Approved']], colWidths=[150, 120, 120])
    table.setStyle(TableStyle([('GRID', (0,0), (-1,-1), 1, colors.black),
        ('BACKGROUND', (0,0), (-1,0), colors.lightgrey), ('FONTNAME', (0,0), (-1,0), 'Helvetica-Bold')]))
    table.wrapOn(canvas, 450, 300); table.drawOn(canvas, 60, 570)
    canvas.drawString(60, 540, 'Table 1. Project budgets; amounts are in US dollars.')
    canvas.showPage()
    canvas.setFont('Helvetica-Bold', 20); canvas.drawString(60, 770, 'Illustrative figure')
    figure = Image.new('RGB', (700, 350), 'white'); drawing = ImageDraw.Draw(figure)
    for index, height in enumerate([70, 170, 110]):
        drawing.rectangle((80+index*180, 300-height, 180+index*180, 300), fill=['blue','green','orange'][index])
    canvas.drawImage(ImageReader(figure), 60, 460, width=450, height=225)
    canvas.setFont('Helvetica', 12)
    canvas.drawString(60, 430, 'Figure 1. Illustrative chart. Its visual meaning is not supplied as text.')
    canvas.showPage()
    scan = Image.new('RGB', (1100, 400), 'white'); drawing = ImageDraw.Draw(scan)
    drawing.text((40, 70), 'Scanned appendix', fill='black', font=ImageFont.load_default(size=48))
    drawing.text((40, 170), 'Reserve funding is 8000 USD.', fill='black', font=ImageFont.load_default(size=38))
    canvas.drawImage(ImageReader(scan), 50, 440, width=500, height=182)
    canvas.save()


def main():
    load_dotenv(Path(__file__).resolve().parent.parent / '.env')
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory', type=Path, default=Path('var/pipeline-demo'))
    parser.add_argument('--pdf', type=Path, help='Use your own PDF in a new demo directory')
    parser.add_argument('--question', default='What is the proposed budget for Boreal?')
    parser.add_argument('--native', action='store_true', help='Fast text-only parsing, without table/layout recognition')
    parser.add_argument('--offline', action='store_true', help='Use lexical hash embeddings, NOT semantic embeddings')
    parser.add_argument('--ocr', action='store_true', help='Enable configured OCR with the standard pipeline')
    parser.add_argument('--reindex', action='store_true', help='Regenerate derived chunks/index with current settings')
    args = parser.parse_args()
    root = args.directory.resolve(); root.mkdir(parents=True, exist_ok=True, mode=0o700)
    config = {'DATABASE_PATH': str(root/'demo.sqlite3'), 'DOCUMENT_STORAGE_ROOT': str(root/'documents'),
              'JWT_SECRET_KEY': secrets.token_urlsafe(48)}
    if args.native: config['DOCLING_PIPELINE'] = 'native'
    if args.ocr: config['DOCLING_OCR'] = True
    if args.offline: config.update(EMBEDDING_PROVIDER='hash-demo', EMBEDDING_DIMENSIONS=256)
    app = create_app(config)
    state_path = root/'document.json'
    with app.app_context():
        if state_path.exists():
            state = json.loads(state_path.read_text())
            if args.pdf and str(args.pdf.resolve()) != state.get('source'):
                raise SystemExit('Use a new --directory to demonstrate another PDF.')
            document_id = state['document_id']
        else:
            source = args.pdf.resolve() if args.pdf else root/'sample.pdf'
            if not args.pdf: create_sample(source)
            with transaction() as db:
                db.execute('INSERT OR IGNORE INTO users(id,email,password_hash) VALUES (?,?,?)',
                    ('demo-user', 'demo@localhost.invalid', generate_password_hash(secrets.token_urlsafe(32))))
            with source.open('rb') as stream:
                response = app.test_client().post('/api/v1/documents/upload', input_stream=stream,
                    content_type='application/pdf', content_length=source.stat().st_size, headers={
                    'Authorization': f"Bearer {issue_token('demo-user')}", 'Idempotency-Key': str(uuid4()),
                    'X-Filename': quote(source.name)})
            if response.status_code != 202:
                raise SystemExit(response.json)
            document_id = response.json['document']['id']
            state_path.write_text(json.dumps({'document_id': document_id, 'source': str(source)}))
        if args.reindex:
            queue_reindex('demo-user', document_id)
        else:
            previous = get_db().execute('SELECT status,retryable FROM processing_jobs WHERE document_id=?', (document_id,)).fetchone()
            if previous and previous['status'] == 'failed' and previous['retryable']:
                response = app.test_client().post(f'/api/v1/documents/{document_id}/retry',
                    headers={'Authorization': f"Bearer {issue_token('demo-user')}"})
                if response.status_code != 200: raise SystemExit(response.json)
        job = claim_job()
        if job: run_job(job)
        job = get_db().execute('SELECT status,error_code,next_page FROM processing_jobs WHERE document_id=?', (document_id,)).fetchone()
        print(json.dumps({'document_id': document_id, 'job': dict(job)}, indent=2))
        if job['status'] != 'completed':
            raise SystemExit('Processing did not finish. Configure providers/models; rerun after the lease expires or use --reindex.')
        try:
            result = retrieve('demo-user', document_id, args.question)
        except ApiError as error:
            raise SystemExit(error.message + (' Use --reindex.' if error.code == 'reindex_required' else '')) from None
        print(json.dumps({'matches': [{'content': item.page_content, 'metadata': item.metadata} for item in result]}, indent=2))
        print('Persistent demo database and PDF:', root)
        print('Figure references/captions do not imply chart understanding.')
        if args.offline: print('hash-demo is lexical feature hashing; it is not a semantic model.')


if __name__ == '__main__':
    main()
