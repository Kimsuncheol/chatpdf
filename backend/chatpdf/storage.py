import os
import shutil
import stat
from contextlib import contextmanager
from pathlib import Path
from uuid import UUID

from flask import current_app

from .db import transaction
from .errors import ApiError


def canonical_id(value):
    try:
        return str(UUID(value)) == value
    except (ValueError, TypeError, AttributeError):
        return False


class DocumentStorage:
    """Only server-generated canonical UUIDs select a directory; never filenames from requests."""
    def __init__(self, root):
        self.root = Path(root).resolve()
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        if not shutil.rmtree.avoids_symlink_attacks:
            raise RuntimeError('Document storage requires symlink-safe recursive deletion')

    def directory(self, document_id):
        if not canonical_id(document_id):
            raise ValueError('Invalid document storage identifier')
        return self.root / document_id

    def delete(self, document_id):
        self.directory(document_id)  # Validate before opening or unlinking anything.
        # Operate relative to a pinned directory descriptor. Symlink artifacts
        # and even a replaced document-directory symlink are unlinked, not followed.
        fd = os.open(self.root, os.O_RDONLY | os.O_DIRECTORY)
        try:
            try:
                entry = os.stat(document_id, dir_fd=fd, follow_symlinks=False)
            except FileNotFoundError:
                return
            if stat.S_ISDIR(entry.st_mode):
                try:
                    shutil.rmtree(document_id, dir_fd=fd)
                except FileNotFoundError:
                    pass  # Concurrent retry already removed it.
            else:
                try:
                    os.unlink(document_id, dir_fd=fd)
                except FileNotFoundError:
                    pass
        finally:
            os.close(fd)


@contextmanager
def writable_document(document_id):
    """All future processing workers must hold this guard for each small page batch.

    The SQLite write lock serializes publication with deletion; workers must not
    write document files, index files, or extracted rows outside this guard.
    """
    with transaction() as db:
        document = db.execute('SELECT * FROM documents WHERE id = ?', (document_id,)).fetchone()
        if document is None or document['status'] == 'deleting':
            raise ApiError(409, 'document_unavailable', 'Document is no longer writable.')
        directory = current_app.extensions['document_storage'].directory(document_id)
        if directory.is_symlink():
            raise OSError('Invalid document directory')
        directory.mkdir(exist_ok=True, mode=0o700)
        yield db, directory


def reap_abandoned_uploads(age_seconds=86400, limit=100):
    """Remove old orphan upload artifacts only, while holding the publication lock.

    Existing document directories are never touched. Partial files are private,
    server-named and older than the maximum supported transfer duration.
    """
    import time
    storage = current_app.extensions['document_storage']
    cutoff = time.time() - age_seconds
    removed = 0
    with transaction() as db:
        incoming = storage.root / '.incoming'
        if incoming.is_dir() and not incoming.is_symlink():
            for entry in incoming.iterdir():
                if removed >= limit:
                    return removed
                try:
                    if entry.suffix == '.part' and entry.lstat().st_mtime < cutoff:
                        entry.unlink(missing_ok=True)
                        removed += 1
                except FileNotFoundError:
                    pass
        for entry in storage.root.iterdir():
            if removed >= limit:
                break
            if not canonical_id(entry.name):
                continue
            if db.execute('SELECT 1 FROM documents WHERE id=?', (entry.name,)).fetchone() is not None:
                continue
            try:
                if entry.lstat().st_mtime < cutoff:
                    storage.delete(entry.name)
                    removed += 1
            except FileNotFoundError:
                pass
    return removed
