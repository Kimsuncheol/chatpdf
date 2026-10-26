"""Run PDF metadata validation in a short-lived subprocess, not a Flask worker."""
import json
import sys
from pathlib import Path


def inspect_pdf(path, max_pages):
    from pypdf import PdfReader
    try:
        with Path(path).open('rb') as stream:
            if stream.read(5) != b'%PDF-':
                return {'error': 'corrupt_pdf'}
            stream.seek(0)
            # Passing an open seekable file avoids pypdf's filename-to-BytesIO copy.
            reader = PdfReader(stream, strict=True)
            if reader.is_encrypted:
                return {'error': 'encrypted_pdf'}
            count = len(reader.pages)
            if count < 1:
                return {'error': 'corrupt_pdf'}
            if count > max_pages:
                return {'error': 'too_many_pages'}
            return {'total_pages': count}
    except Exception:
        return {'error': 'corrupt_pdf'}


if __name__ == '__main__':
    print(json.dumps(inspect_pdf(sys.argv[1], int(sys.argv[2]))))
