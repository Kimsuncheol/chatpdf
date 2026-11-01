"""Short-lived, bounded Docling conversion with structured source provenance."""
import json
import logging
import sys
import tempfile
from contextlib import contextmanager
from pathlib import Path


def warning(page, code, **detail):
    return {'page_number': page, 'code': code, 'detail': detail}



@contextmanager
def capture_warnings(warnings, start, end):
    class CaptureWarnings(logging.Handler):
        def emit(self, record):
            code = 'ocr_orientation_failed' if 'OSD failed' in record.getMessage() else 'docling_runtime_warning'
            warnings.append(warning(start, code, logger=record.name[:120], scope='batch', batch_end=end))
    collector = CaptureWarnings(level=logging.WARNING)
    logger = logging.getLogger('docling')
    logger.addHandler(collector)
    try:
        yield
    finally:
        logger.removeHandler(collector)

def parse_pages(source, start, end, settings):
    from pypdf import PdfReader, PdfWriter
    from docling.datamodel.base_models import ConversionStatus, InputFormat
    from docling.datamodel.pipeline_options import (
        NativePdfPipelineOptions, PdfPipelineOptions, OcrMode, OcrAutoOptions,
        TesseractCliOcrOptions, RapidOcrOptions, OcrMacOptions,
    )
    from docling.document_converter import DocumentConverter, NativePdfFormatOption, PdfFormatOption

    warnings = []
    with capture_warnings(warnings, start, end), tempfile.TemporaryDirectory(prefix='chatpdf-pages-') as temporary:
        batch = Path(temporary) / 'batch.pdf'
        with Path(source).open('rb') as stream:
            reader = PdfReader(stream, strict=True)
            if reader.is_encrypted:
                return {'error': 'encrypted_pdf', 'retryable': False}
            writer = PdfWriter()
            for number in range(start - 1, end):
                writer.add_page(reader.pages[number])
            with batch.open('wb') as destination:
                writer.write(destination)
            writer.close()
        if settings['pipeline'] == 'native':
            options = NativePdfPipelineOptions(generate_page_images=False,
                generate_picture_images=False, parser_threads=1, document_timeout=settings['timeout'])
            pdf_format = NativePdfFormatOption(pipeline_options=options)
            warnings.append(warning(0, 'native_structure_limited'))
            if settings['ocr']:
                warnings.append(warning(0, 'ocr_disabled_in_native_mode'))
        else:
            engines = {'auto': OcrAutoOptions, 'tesseract': TesseractCliOcrOptions,
                       'rapidocr': RapidOcrOptions, 'ocrmac': OcrMacOptions}
            ocr_options = {}
            if settings['ocr']:
                ocr_options['ocr_options'] = engines[settings['ocr_engine']](lang=settings['ocr_languages'],
                    mode=OcrMode.FULL_PAGE if settings['ocr_full_page'] else OcrMode.DEFAULT)
            options = PdfPipelineOptions(do_ocr=settings['ocr'], **ocr_options,
                do_table_structure=True, do_picture_description=False, do_picture_classification=False,
                generate_page_images=False, generate_picture_images=False,
                document_timeout=settings['timeout'], enable_remote_services=False,
                artifacts_path=settings.get('artifacts'))
            pdf_format = PdfFormatOption(pipeline_options=options)
        converter = DocumentConverter(allowed_formats=[InputFormat.PDF],
            format_options={InputFormat.PDF: pdf_format})
        result = converter.convert(batch, raises_on_error=False)
        for error in result.errors:
            # Keep categories/component names; never expose paths, text, or parser traces.
            category = getattr(getattr(error, 'category', None), 'value', 'unspecified')
            component = getattr(getattr(error, 'component_type', None), 'value', 'parser')
            warnings.append(warning(start, 'docling_warning', category=str(category)[:80],
                                    component=str(component)[:80], batch_end=end))
        if result.status not in (ConversionStatus.SUCCESS, ConversionStatus.PARTIAL_SUCCESS) or len(result.document.pages) != end-start+1:
            return {'error': 'parse_failed', 'retryable': True, 'warnings': warnings}
        if result.status == ConversionStatus.PARTIAL_SUCCESS:
            warnings.append(warning(start, 'partial_conversion', batch_end=end))
        items = [item for item, _ in result.document.iterate_items()]
        attached_captions = {reference.cref for item in items for reference in getattr(item, 'captions', [])}
        elements = []
        quality = {page: {'page_number': page, 'text_characters': 0, 'element_count': 0, 'image_count': 0}
                   for page in range(start, end + 1)}
        characters = 0
        for source_order, item in enumerate(items):
            provenance = getattr(item, 'prov', [])
            if not provenance or not hasattr(item, 'label'):
                continue
            label = item.label.value
            pages = sorted({start + p.page_no - 1 for p in provenance})
            if any(not start <= page <= end for page in pages):
                raise ValueError('Invalid Docling provenance')
            regions = [{'page_number': start+p.page_no-1, 'bbox': p.bbox.model_dump(mode='json'),
                        'charspan': list(p.charspan)} for p in provenance]
            metadata = {'docling_ref': item.self_ref, 'page_numbers': pages, 'regions': regions,
                        'batch_start': start, 'batch_end': end, 'visual_understanding': False,
                        'source_order': source_order, 'parent_ref': getattr(getattr(item, 'parent', None), 'cref', None),
                        'child_refs': [reference.cref for reference in getattr(item, 'children', [])]}
            if label == 'list_item':
                metadata['marker'] = getattr(item, 'marker', '')
                metadata['enumerated'] = bool(getattr(item, 'enumerated', False))
            text = getattr(item, 'text', '')
            if label in ('section_header', 'title'):
                metadata['heading_level'] = int(getattr(item, 'level', 0 if label == 'title' else 1))
            if item.self_ref in attached_captions:
                metadata['attached_caption'] = True
            if label == 'table':
                text = item.export_to_markdown(doc=result.document)
                metadata['caption'] = item.caption_text(result.document)
                metadata['table_data'] = item.data.model_dump(mode='json', exclude={'grid'})
                metadata['table_spans'] = [[cell.start_row_offset_idx, cell.end_row_offset_idx]
                    for cell in item.data.table_cells if cell.row_span > 1]
                rows = []
                for index, cells in enumerate(item.data.grid):
                    values = [cell.text.replace('|', '\\|').replace('\n', '<br>')
                        if cell.start_row_offset_idx == index and cell.start_col_offset_idx == column else ''
                        for column, cell in enumerate(cells)]
                    rows.append({'index': index, 'text': '| ' + ' | '.join(values) + ' |',
                                 'header': any(cell.column_header for cell in cells)})
                metadata['table_rows'] = rows
                if end in pages and end < settings.get('total_pages', end):
                    warnings.append(warning(end, 'table_at_batch_boundary'))
            elif label in ('picture', 'chart'):
                text = item.caption_text(result.document) if hasattr(item, 'caption_text') else ''
                metadata['figure'] = {'kind': 'pdf_region', 'page_numbers': pages, 'regions': regions,
                                      'caption': text, 'visual_understanding': False}
                for page in pages:
                    quality[page]['image_count'] += 1
                    warnings.append(warning(page, 'visual_content_not_interpreted'))
            if not isinstance(text, str): text = ''
            characters += len(text)
            if characters > 2_000_000:
                return {'error': 'batch_content_limit', 'retryable': False, 'warnings': warnings}
            for page in pages:
                quality[page]['element_count'] += 1
                if label not in ('picture', 'chart', 'page_header', 'page_footer'):
                    spans = {tuple(p.charspan) for p in provenance if start+p.page_no-1 == page and p.charspan[1] > p.charspan[0]}
                    if label != 'table' and spans and all(0 <= a < b <= len(text) for a,b in spans):
                        quality[page]['text_characters'] += sum(len(text[a:b].strip()) for a,b in spans)
                    else:
                        quality[page]['text_characters'] += len(text.strip()) // len(pages)
                        if len(pages) > 1: quality[page]['approximate_text_count'] = True
                # Persist per-page structure; the chunker deduplicates multi-page items.
                elements.append({'page_number': page, 'element_type': label, 'content': text, 'metadata': metadata})
        for local_page, page_item in result.document.pages.items():
            if hasattr(page_item, 'size'):
                quality[start+local_page-1]['page_size'] = page_item.size.model_dump(mode='json')
        for page, metrics in quality.items():
            metrics['ocr_configured'] = settings['ocr'] and settings['pipeline'] == 'standard'
            metrics['parser_mode'] = settings['pipeline']
            if metrics['text_characters'] < settings['low_text_characters']:
                warnings.append(warning(page, 'little_or_no_text', text_characters=metrics['text_characters']))
        return {'pages': list(range(start, end + 1)), 'elements': elements,
                'page_quality': list(quality.values()), 'warnings': warnings}


if __name__ == '__main__':
    try:
        output = parse_pages(sys.argv[1], int(sys.argv[3]), int(sys.argv[4]), json.loads(sys.argv[5]))
    except ImportError:
        output = {'error': 'worker_configuration', 'retryable': True}
    except Exception as error:
        output = {'error': 'parse_failed', 'retryable': True, 'exception_type': type(error).__name__}
    encoded = json.dumps(output)
    if len(encoded.encode()) > 16 * 1024 * 1024:
        encoded = json.dumps({'error': 'batch_content_limit', 'retryable': False})
    Path(sys.argv[2]).write_text(encoded, encoding='utf-8')
