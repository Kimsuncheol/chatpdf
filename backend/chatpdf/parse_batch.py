"""Short-lived Docling process. Only a small page subset reaches the converter."""
import json
import sys
import tempfile
from pathlib import Path


def parse_pages(source, start, end, settings):
    from pypdf import PdfReader, PdfWriter
    from docling.datamodel.base_models import ConversionStatus, InputFormat
    from docling.datamodel.pipeline_options import NativePdfPipelineOptions, PdfPipelineOptions
    from docling.document_converter import DocumentConverter, NativePdfFormatOption, PdfFormatOption

    with tempfile.TemporaryDirectory(prefix='chatpdf-pages-') as temporary:
        batch = Path(temporary) / 'batch.pdf'
        with Path(source).open('rb') as stream:
            reader = PdfReader(stream, strict=True)
            if reader.is_encrypted:
                return {'error': 'encrypted_pdf', 'retryable': False}
            writer = PdfWriter()
            # No slice of the whole document and no rasterization of other pages.
            for number in range(start - 1, end):
                writer.add_page(reader.pages[number])
            with batch.open('wb') as destination:
                writer.write(destination)
            writer.close()
        if settings['pipeline'] == 'native':
            options = NativePdfPipelineOptions(generate_page_images=False,
                generate_picture_images=False, parser_threads=1,
                document_timeout=settings['timeout'])
            pdf_format = NativePdfFormatOption(pipeline_options=options)
        else:
            options = PdfPipelineOptions(do_ocr=settings['ocr'],
                generate_page_images=False, generate_picture_images=False,
                document_timeout=settings['timeout'], enable_remote_services=False,
                artifacts_path=settings.get('artifacts'))
            pdf_format = PdfFormatOption(pipeline_options=options)
        converter = DocumentConverter(allowed_formats=[InputFormat.PDF],
            format_options={InputFormat.PDF: pdf_format})
        result = converter.convert(batch, raises_on_error=False)
        if result.status != ConversionStatus.SUCCESS or len(result.document.pages) != end - start + 1:
            return {'error': 'parse_failed', 'retryable': True}
        elements = []
        characters = 0
        for item, _ in result.document.iterate_items():
            provenance = getattr(item, 'prov', [])
            if not provenance or not hasattr(item, 'label'):
                continue
            text = getattr(item, 'text', '')
            if item.label.value == 'table':
                text = item.export_to_markdown(doc=result.document)
            if not isinstance(text, str):
                text = ''
            characters += len(text)
            if characters > 2_000_000:
                return {'error': 'batch_content_limit', 'retryable': False}
            for page in sorted({p.page_no for p in provenance}):
                if not 1 <= page <= end - start + 1:
                    raise ValueError('Invalid Docling provenance')
                # Keep even non-text elements as metadata; never retain images.
                for offset in range(0, max(1, len(text)), 2000):
                    elements.append({'page_number': start + page - 1,
                        'element_type': item.label.value, 'content': text[offset:offset + 2000]})
        return {'pages': list(range(start, end + 1)), 'elements': elements}


if __name__ == '__main__':
    try:
        output = parse_pages(sys.argv[1], int(sys.argv[3]), int(sys.argv[4]), json.loads(sys.argv[5]))
    except ImportError:
        output = {'error': 'worker_configuration', 'retryable': True}
    except Exception as error:
        output = {'error': 'parse_failed', 'retryable': True, 'exception_type': type(error).__name__}
    Path(sys.argv[2]).write_text(json.dumps(output), encoding='utf-8')
