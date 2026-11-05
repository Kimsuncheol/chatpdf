"""Isolated one-page rendering; stdout never contains source text or errors."""
import sys


def render(source, target, page_number, edge):
    import pypdfium2 as pdfium
    with pdfium.PdfDocument(source) as document:
        if not 1 <= page_number <= len(document):
            return 2
        page = document[page_number - 1]
        try:
            width, height = page.get_size()
            if min(width, height) <= 0:
                return 1
            scale = min(edge / width, edge / height, 2)
            bitmap = page.render(scale=scale)
            try:
                bitmap.to_pil().save(target, format='PNG')
            finally:
                bitmap.close()
        finally:
            page.close()
    return 0


if __name__ == '__main__':
    try:
        if sys.platform == 'linux':
            import resource
            resource.setrlimit(resource.RLIMIT_AS, (384 * 1024 * 1024, 384 * 1024 * 1024))
            resource.setrlimit(resource.RLIMIT_CPU, (20, 20))
        result = render(sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4]))
    except Exception:
        result = 1
    raise SystemExit(result)
