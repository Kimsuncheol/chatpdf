"""Supervise independent WSGI/ingestion processes sharing one persistent volume.

Render disks cannot be mounted by separate services. Keep exactly one instance
of this service until storage/queue/database have been migrated to shared services.
"""
import os
import signal
import subprocess
import sys
import time

from . import create_app


def main():
    os.umask(0o077)
    port = int(os.environ.get('PORT', '10000'))
    if not 1 <= port <= 65535:
        raise ValueError('PORT must be between 1 and 65535')
    # Fail before binding a public socket if paths/secrets/schema are invalid.
    create_app()
    stopping = False
    children = []

    def stop(_number, _frame):
        nonlocal stopping
        stopping = True

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    try:
        for command in [
            [sys.executable, '-m', 'flask', '--app', 'chatpdf:create_app', 'ingestion-worker'],
            [sys.executable, '-m', 'gunicorn', 'chatpdf:create_app()',
             '--bind', f'0.0.0.0:{port}', '--workers', '1', '--threads', '4',
             '--timeout', '180', '--graceful-timeout', '15',
             '--max-requests', '500', '--max-requests-jitter', '50'],
        ]:
            children.append(subprocess.Popen(command, start_new_session=True))
        while not stopping:
            if any(child.poll() is not None for child in children):
                # Let Render restart the complete service after either child fails.
                print('A required service process stopped; shutting down.', file=sys.stderr)
                return 1
            time.sleep(0.25)
        return 0
    finally:
        for child in children:
            if child.poll() is None:
                try:
                    os.killpg(child.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
        deadline = time.monotonic() + 20
        for child in children:
            try:
                child.wait(timeout=max(0, deadline - time.monotonic()))
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                child.wait()


if __name__ == '__main__':
    raise SystemExit(main())
