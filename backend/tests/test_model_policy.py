from datetime import datetime, timedelta, timezone

import pytest

from chatpdf.db import transaction
from chatpdf.errors import ApiError
from chatpdf.model_policy import ModelPolicy


def test_free_account_uses_llama_and_reports_llama_family(app):
    app.config['LLAMA_MODEL_TAG'] = 'llama3.1:8b'
    with app.app_context():
        policy = ModelPolicy()
        assert policy.select('alice') == 'llama3.1:8b'
        entitlements = policy.entitlements('alice').public()['entitlements']
        assert entitlements['model_family'] == 'llama'
        assert entitlements['allowed_models'] == ['llama3.1:8b']


def test_legacy_gemma_setting_cannot_silently_select_the_old_model(app):
    app.config.update(LLAMA_MODEL_TAG='', GEMMA_MODEL_TAG='gemma3:4b')
    with app.app_context():
        with pytest.raises(ApiError) as error:
            ModelPolicy().select('alice')
        assert error.value.code == 'model_not_configured'


def test_paid_account_keeps_its_kimi_model(app):
    app.config.update(LLAMA_MODEL_TAG='llama3.1:8b', KIMI_MODEL_TAG='kimi:test')
    expiry = (datetime.now(timezone.utc) + timedelta(days=1)).isoformat()
    with app.app_context(), transaction() as db:
        db.execute("UPDATE users SET subscription_tier='paid',subscription_expires_at=? WHERE id='alice'", (expiry,))
    with app.app_context():
        assert ModelPolicy().select('alice') == 'kimi:test'
