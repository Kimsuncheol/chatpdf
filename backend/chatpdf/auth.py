from datetime import datetime, timedelta, timezone
from functools import wraps

import jwt
from flask import Blueprint, current_app, g, jsonify, request
from werkzeug.security import check_password_hash, generate_password_hash

from .db import get_db
from .errors import ApiError

bp = Blueprint('auth', __name__, url_prefix='/api/v1/auth')
# Equalize unknown-account password checks without retaining a real password.
DUMMY_HASH = generate_password_hash('unused-placeholder')


def issue_token(user_id):
    now = datetime.now(timezone.utc)
    return jwt.encode({
        'sub': user_id, 'iat': now, 'exp': now + timedelta(minutes=30),
        'iss': current_app.config['JWT_ISSUER'], 'aud': current_app.config['JWT_AUDIENCE'],
    }, current_app.config['JWT_SECRET_KEY'], algorithm='HS256')


def authenticated(view):
    @wraps(view)
    def wrapped(*args, **kwargs):
        scheme, _, token = request.headers.get('Authorization', '').partition(' ')
        if scheme.lower() != 'bearer' or not token or len(token) > 8192:
            raise ApiError(401, 'unauthorized', 'Sign in to continue.')
        try:
            claims = jwt.decode(
                token, current_app.config['JWT_SECRET_KEY'], algorithms=['HS256'],
                issuer=current_app.config['JWT_ISSUER'], audience=current_app.config['JWT_AUDIENCE'],
                options={'require': ['sub', 'exp', 'iat', 'iss', 'aud']},
            )
        except jwt.InvalidTokenError:
            raise ApiError(401, 'unauthorized', 'Sign in to continue.') from None
        user = get_db().execute('SELECT * FROM users WHERE id = ? AND active = 1', (claims['sub'],)).fetchone()
        if user is None:
            raise ApiError(401, 'unauthorized', 'Sign in to continue.')
        # Ownership and tier come from persistent server records, never headers or token tier claims.
        g.user = user
        return view(*args, **kwargs)
    return wrapped


@bp.post('/login')
def login():
    body = request.get_json(silent=True)
    if not isinstance(body, dict) or not isinstance(body.get('email'), str) or not isinstance(body.get('password'), str):
        raise ApiError(400, 'invalid_input', 'Email and password are required.')
    email, password = body['email'].strip(), body['password']
    if len(email) > 320 or not 1 <= len(password) <= 1024:
        raise ApiError(400, 'invalid_input', 'Invalid credentials.')
    user = get_db().execute('SELECT * FROM users WHERE email = ? COLLATE NOCASE', (email,)).fetchone()
    valid = check_password_hash(user['password_hash'] if user else DUMMY_HASH, password)
    if not valid or user is None or not user['active']:
        raise ApiError(401, 'unauthorized', 'Invalid credentials.')
    return jsonify(access_token=issue_token(user['id']))


@bp.get('/me')
@authenticated
def me():
    return jsonify(id=g.user['id'], email=g.user['email'], subscription_tier=g.user['subscription_tier'])
