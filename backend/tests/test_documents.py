from datetime import datetime, timedelta, timezone
from pathlib import Path
from unittest.mock import patch

import jwt
import pytest

from chatpdf.db import get_db, transaction
from chatpdf.errors import ApiError
from chatpdf.storage import writable_document


def test_authentication_required_for_every_document_route(client, seed):
    doc = seed()
    for method, path in [('get', '/api/v1/documents'), ('get', f'/api/v1/documents/{doc}'),
                         ('delete', f'/api/v1/documents/{doc}')]:
        response = getattr(client, method)(path, headers={'X-User-ID': 'alice', 'X-Subscription-Tier': 'paid'})
        assert response.status_code == 401
        assert response.headers['WWW-Authenticate'] == 'Bearer'


@pytest.mark.parametrize('mode', ['expired', 'wrong_secret', 'wrong_audience', 'missing_exp', 'unknown_user', 'none'])
def test_untrusted_tokens_are_rejected(app, client, mode):
    now = datetime.now(timezone.utc)
    claims = dict(sub='alice', exp=now + timedelta(minutes=1), iat=now,
                  iss=app.config['JWT_ISSUER'], aud=app.config['JWT_AUDIENCE'])
    secret, algorithm = app.config['JWT_SECRET_KEY'], 'HS256'
    if mode == 'expired': claims['exp'] = now - timedelta(seconds=10)
    if mode == 'wrong_secret': secret = 'different-test-secret-with-sufficient-length'
    if mode == 'wrong_audience': claims['aud'] = 'other-service'
    if mode == 'missing_exp': del claims['exp']
    if mode == 'unknown_user': claims['sub'] = 'nobody'
    if mode == 'none': secret, algorithm = '', 'none'
    token = jwt.encode(claims, secret, algorithm=algorithm)
    assert client.get('/api/v1/documents', headers={'Authorization': f'Bearer {token}'}).status_code == 401


def test_login_me_and_deactivated_account(app, client):
    assert client.post('/api/v1/auth/login', json={'email': 'alice@example.com', 'password': 'wrong'}).status_code == 401
    response = client.post('/api/v1/auth/login', json={
        'email': 'alice@example.com', 'password': 'a-test-password', 'subscription_tier': 'paid'})
    assert response.status_code == 200
    auth = {'Authorization': f'Bearer {response.json["access_token"]}'}
    assert client.get('/api/v1/auth/me', headers=auth).json['subscription_tier'] == 'free'
    with app.app_context(), transaction() as db:
        db.execute("UPDATE users SET active = 0 WHERE id = 'alice'")
    assert client.get('/api/v1/documents', headers=auth).status_code == 401


def test_owner_isolation_and_private_metadata(client, headers, seed, app):
    alice, bob = seed(), seed(owner='bob')
    auth = headers()
    listed = client.get('/api/v1/documents?owner_id=bob', headers=auth)
    assert [doc['id'] for doc in listed.json['items']] == [alice]
    assert listed.headers['Cache-Control'] == 'no-store'
    for method in ['get', 'delete']:
        forbidden = getattr(client, method)(f'/api/v1/documents/{bob}', headers=auth)
        missing = getattr(client, method)('/api/v1/documents/not-an-id', headers=auth)
        assert forbidden.status_code == missing.status_code == 404
        assert forbidden.json == missing.json
    own = client.get(f'/api/v1/documents/{alice}', headers=auth)
    assert own.status_code == 200
    assert set(own.json) == {'id', 'name', 'uploaded_at', 'status', 'processed_pages', 'total_pages'}
    assert own.json['total_pages'] == 8
    assert app.extensions['document_storage'].directory(bob).exists()


def test_keyset_pagination_has_no_duplicates_and_handles_deleted_cursor_row(client, headers, seed):
    ids = {seed(uploaded_at='2026-10-25T10:00:00+00:00') for _ in range(5)}
    auth = headers()
    first = client.get('/api/v1/documents?limit=2', headers=auth).json
    assert len(first['items']) == 2 and first['next_cursor']
    # A deleted boundary row does not invalidate a keyset cursor.
    assert client.delete(f'/api/v1/documents/{first["items"][-1]["id"]}', headers=auth).status_code == 204
    seen = [doc['id'] for doc in first['items']]
    cursor = first['next_cursor']
    while cursor:
        page = client.get('/api/v1/documents', query_string={'limit': 2, 'cursor': cursor}, headers=auth)
        assert page.status_code == 200
        seen.extend(doc['id'] for doc in page.json['items'])
        cursor = page.json['next_cursor']
    assert set(seen) == ids and len(seen) == len(ids)


def test_search_is_literal_unicode_and_owner_scoped(client, headers, seed):
    wanted = seed(name='Straße 100%_Report.pdf')
    seed(name='Other report.pdf')
    seed(owner='bob', name='Straße 100%_Report.pdf')
    for query in ['STRASSE', '%_', '100%_']:
        response = client.get('/api/v1/documents', query_string={'q': query}, headers=headers())
        assert [item['id'] for item in response.json['items']] == [wanted]
    assert client.get('/api/v1/documents?q=absent', headers=headers()).json == {'items': [], 'next_cursor': None}


def test_cursor_is_bound_to_owner_and_search(client, headers, seed):
    seed(name='report one'); seed(name='report two')
    cursor = client.get('/api/v1/documents?q=report&limit=1', headers=headers()).json['next_cursor']
    for user, query, value in [('bob', 'report', cursor), ('alice', 'other', cursor), ('alice', 'report', cursor + 'broken')]:
        response = client.get('/api/v1/documents', query_string={'q': query, 'cursor': value}, headers=headers(user))
        assert response.status_code == 400


@pytest.mark.parametrize('query', ['limit=0', 'limit=-1', 'limit=101', 'limit=abc', 'limit=1.5', 'cursor=', 'q=' + 'x'*201])
def test_invalid_pagination_and_search(client, headers, query):
    assert client.get('/api/v1/documents?' + query, headers=headers()).status_code == 400


def test_delete_cleans_all_artifacts_and_cascades_only_owned_records(app, client, headers, seed):
    doc, other = seed(), seed(owner='bob')
    response = client.delete(f'/api/v1/documents/{doc}', headers=headers())
    assert response.status_code == 204
    assert not app.extensions['document_storage'].directory(doc).exists()
    assert app.extensions['document_storage'].directory(other).exists()
    with app.app_context():
        for table in ['documents', 'chunks', 'embeddings', 'conversations', 'messages', 'processing_jobs']:
            assert get_db().execute(f'SELECT count(*) FROM {table}').fetchone()[0] == 1
    assert client.get(f'/api/v1/documents/{doc}', headers=headers()).status_code == 404
    assert client.delete(f'/api/v1/documents/{doc}', headers=headers()).status_code == 404


def test_cleanup_failure_keeps_tombstone_blocks_workers_and_can_retry(app, client, headers, seed):
    doc = seed(status='processing')
    storage = app.extensions['document_storage']
    with patch.object(storage, 'delete', side_effect=OSError('Disk unavailable')):
        response = client.delete(f'/api/v1/documents/{doc}', headers=headers())
    assert response.status_code == 503
    assert response.json['error']['code'] == 'cleanup_pending'
    assert client.get(f'/api/v1/documents/{doc}', headers=headers()).json['status'] == 'deleting'
    with app.app_context():
        assert get_db().execute('SELECT status FROM processing_jobs WHERE document_id = ?', (doc,)).fetchone()[0] == 'cancelled'
        with pytest.raises(ApiError):
            with writable_document(doc):
                pytest.fail('A deleting document cannot publish a page batch')
    assert client.delete(f'/api/v1/documents/{doc}', headers=headers()).status_code == 204
    assert not storage.directory(doc).exists()


def test_missing_files_are_safe_and_symlinks_never_followed(app, client, headers, seed, tmp_path):
    storage = app.extensions['document_storage']
    missing = seed()
    storage.delete(missing)
    assert client.delete(f'/api/v1/documents/{missing}', headers=headers()).status_code == 204
    outside = tmp_path / 'outside'
    outside.mkdir()
    valuable = outside / 'keep.txt'
    valuable.write_text('untouched')
    doc = seed()
    (storage.directory(doc) / 'index' / 'external-link').symlink_to(outside, target_is_directory=True)
    assert client.delete(f'/api/v1/documents/{doc}', headers=headers()).status_code == 204
    assert valuable.read_text() == 'untouched'
    replaced = seed()
    storage.delete(replaced)
    storage.directory(replaced).symlink_to(outside, target_is_directory=True)
    assert client.delete(f'/api/v1/documents/{replaced}', headers=headers()).status_code == 204
    assert valuable.exists()


def test_failed_database_finalization_can_retry_without_files(app, client, headers, seed):
    doc = seed()
    with app.app_context():
        get_db().execute("CREATE TRIGGER fail_deletion BEFORE DELETE ON documents BEGIN SELECT RAISE(FAIL, 'test failure'); END")
        get_db().commit()
    assert client.delete(f'/api/v1/documents/{doc}', headers=headers()).status_code == 503
    assert not app.extensions['document_storage'].directory(doc).exists()
    assert client.get(f'/api/v1/documents/{doc}', headers=headers()).json['status'] == 'deleting'
    with app.app_context():
        get_db().execute('DROP TRIGGER fail_deletion')
        get_db().commit()
    assert client.delete(f'/api/v1/documents/{doc}', headers=headers()).status_code == 204
