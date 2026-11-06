"""Authoritative account entitlements; no client tier/model inputs or policy cache."""
from dataclasses import dataclass
from datetime import datetime, timezone

from flask import current_app

from .db import get_db
from .errors import ApiError


def parse_expiry(value):
    """Require an explicit timezone; store and compare all expirations in UTC."""
    parsed = datetime.fromisoformat(value)
    if parsed.tzinfo is None:
        raise ValueError('Subscription expiry must include a timezone')
    return parsed.astimezone(timezone.utc)


def configured_model(tier):
    key = 'LLAMA_MODEL_TAG' if tier == 'free' else 'KIMI_MODEL_TAG'
    tag = current_app.config.get(key, '')
    if (not isinstance(tag, str) or not tag or len(tag) > 200 or
            ':' not in tag or not tag.rsplit(':', 1)[-1] or
            any(character.isspace() or ord(character) < 32 for character in tag)):
        raise ApiError(503, 'model_not_configured', 'The chat model is not configured. Contact the server administrator.')
    return tag


@dataclass(frozen=True)
class Entitlements:
    tier: str
    subscription_status: str
    expires_at: str | None

    def require_chat(self):
        if self.subscription_status != 'active':
            raise ApiError(403, 'subscription_expired',
                'Paid access has expired or has no valid expiry. Contact support to renew or switch to the free plan.')
        return configured_model(self.tier)

    def public(self):
        # Configuration can be incomplete while accounts/library remain usable.
        model = None
        if self.subscription_status == 'active':
            try:
                model = configured_model(self.tier)
            except ApiError:
                pass
        return {'tier': self.tier, 'subscription_status': self.subscription_status,
                'subscription_expires_at': self.expires_at,
                'entitlements': {'chat': model is not None,
                    'model_family': ('llama' if self.tier == 'free' else 'kimi') if model else None,
                    'allowed_models': [model] if model else [],
                    'unavailable_reason': ('subscription_expired' if self.subscription_status != 'active'
                                           else 'model_not_configured' if model is None else None)}}


class ModelPolicy:
    def entitlements(self, user_id):
        account = get_db().execute('SELECT subscription_tier,subscription_expires_at FROM users '
            'WHERE id=? AND active=1', (user_id,)).fetchone()
        if account is None:
            raise ApiError(401, 'unauthorized', 'Sign in to continue.')
        tier, expires_at = account['subscription_tier'], account['subscription_expires_at']
        if tier not in ('free', 'paid'):
            raise ApiError(403, 'account_unavailable', 'Account access needs review. Contact support.')
        if tier == 'free':
            return Entitlements(tier, 'active', None)
        try:
            expiry = parse_expiry(expires_at)
        except (ValueError, TypeError, OverflowError):
            return Entitlements(tier, 'expired', None)
        return Entitlements(tier, 'active' if expiry > datetime.now(timezone.utc) else 'expired', expiry.isoformat())

    def select(self, user_id):
        return self.entitlements(user_id).require_chat()
