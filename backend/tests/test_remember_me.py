import hashlib
from chatpdf.db import get_db, transaction


def test_remembered_session_is_hashed_and_revocable(app, client):
    response = client.post('/api/v1/auth/login', json={
        'email': 'alice@example.com', 'password': 'a-test-password', 'remember_me': True,
    })
    token = response.json['access_token']
    assert token.startswith('remember_')
    headers = {'Authorization': f'Bearer {token}'}
    with app.app_context():
        row = get_db().execute('SELECT * FROM remembered_sessions').fetchone()
        assert row['token_hash'] == hashlib.sha256(token.encode()).hexdigest()
        assert row['user_id'] == 'alice'
    assert client.get('/api/v1/auth/me', headers=headers).status_code == 200
    assert client.post('/api/v1/auth/logout', headers=headers).status_code == 204
    assert client.get('/api/v1/auth/me', headers=headers).status_code == 401


def test_remembered_session_checks_active_account(app, client):
    token = client.post('/api/v1/auth/login', json={
        'email': 'alice@example.com', 'password': 'a-test-password', 'remember_me': True,
    }).json['access_token']
    with app.app_context(), transaction() as db:
        db.execute("UPDATE users SET active = 0 WHERE id = 'alice'")
    assert client.get('/api/v1/auth/me', headers={'Authorization': f'Bearer {token}'}).status_code == 401


def test_remember_me_requires_boolean(client):
    assert client.post('/api/v1/auth/login', json={
        'email': 'alice@example.com', 'password': 'a-test-password', 'remember_me': 'true',
    }).status_code == 400
