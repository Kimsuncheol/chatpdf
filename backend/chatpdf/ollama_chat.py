"""Server-only chat transport. Call with authenticated identity and trusted messages."""
from urllib.parse import urlsplit

import httpx
from flask import current_app
from ollama import Client, ResponseError

from .errors import ApiError
from .model_policy import ModelPolicy, configured_model


class OllamaChatService:
    def __init__(self, client_factory=Client):
        self.client_factory = client_factory
        self.policy = ModelPolicy()

    def _client(self):
        host = current_app.config.get('OLLAMA_BASE_URL')
        try:
            url = urlsplit(host or '')
            valid = url.scheme in ('http', 'https') and url.hostname and not url.username and not url.password
            valid = valid and not url.query and not url.fragment
            _ = url.port
        except ValueError:
            valid = False
        if not valid:
            raise ApiError(503, 'model_not_configured', 'The chat service host is not configured. Contact the server administrator.')
        headers = {}
        if current_app.config.get('OLLAMA_API_KEY'):
            headers['Authorization'] = 'Bearer ' + current_app.config['OLLAMA_API_KEY']
        return self.client_factory(host=host, headers=headers,
            timeout=httpx.Timeout(current_app.config['OLLAMA_CHAT_TIMEOUT'], connect=5),
            follow_redirects=False, trust_env=False)

    def _call(self, operation):
        try:
            with self._client() as client:
                return operation(client)
        except ApiError:
            raise
        except httpx.TimeoutException:
            raise ApiError(504, 'model_timeout', 'The chat model took too long. Retry with a shorter question or contact support.') from None
        except ResponseError as error:
            if error.status_code == 404:
                raise ApiError(503, 'model_missing', 'The configured chat model is missing. Ask the server administrator to install and verify it.') from None
            if error.status_code in (408, 504):
                raise ApiError(504, 'model_timeout', 'The chat model timed out. Retry shortly or contact support.') from None
            raise ApiError(503, 'ollama_unavailable', 'The chat service could not complete the request. Retry shortly; contact support if it continues.') from None
        except (ConnectionError, httpx.TransportError):
            raise ApiError(503, 'ollama_unavailable', 'The chat service is unavailable. Retry shortly or contact support.') from None
        except Exception:
            # Never include provider bodies, request URLs, prompts or tracebacks.
            raise ApiError(503, 'model_response_invalid', 'The chat model returned an unusable response. Retry or contact support.') from None

    def chat(self, user_id, messages, *, response_format='json'):
        """No model/tier/options argument. The caller supplies server-built RAG messages.

        The caller must authorize the selected document and build cited PDF context.
        This low-level service does not assert grounding or persist conversations.
        """
        model = self.policy.select(user_id)
        if (not isinstance(messages, list) or not 1 <= len(messages) <= 100 or
                any(not isinstance(item, dict) or set(item) != {'role', 'content'} or
                    item['role'] not in ('system', 'user', 'assistant') or
                    not isinstance(item['content'], str) for item in messages)):
            raise ApiError(400, 'invalid_messages', 'Supply text chat messages with valid roles.')
        if sum(len(item['content']) for item in messages) > current_app.config['OLLAMA_CHAT_MAX_INPUT_CHARS']:
            raise ApiError(400, 'chat_input_too_large', 'The chat context is too large. Use a shorter question or less context.')
        response = self._call(lambda client: client.chat(model=model, messages=messages, stream=False, format=response_format,
            options={'temperature': 0, 'num_predict': current_app.config['OLLAMA_CHAT_MAX_TOKENS']}))
        # Recheck expiry, disablement and plan changes before releasing an answer.
        if self.policy.select(user_id) != model:
            raise ApiError(409, 'entitlements_changed', 'Your plan changed during this request. Please retry.')
        if (not response.done or response.model != model or response.message.role != 'assistant' or
                not isinstance(response.message.content, str) or not response.message.content.strip()):
            raise ApiError(503, 'model_response_invalid', 'The chat model returned an unusable response. Retry or contact support.')
        return response.message.content

    def verify_models(self, generate=False):
        """Administrative check only; never exposed as a user model-list endpoint."""
        result = []
        for tier in ('free', 'paid'):
            model = configured_model(tier)
            def verify(client):
                if model not in {item.model for item in client.list().models}:
                    raise ApiError(503, 'model_missing', 'An exact configured model tag is missing. Install that tag and retry verification.')
                info = client.show(model)
                if 'completion' not in (info.capabilities or []):
                    raise ApiError(503, 'model_incompatible', 'The configured model does not advertise chat completion. Choose a chat-capable model tag.')
                if generate:
                    reply = client.chat(model=model, messages=[{'role': 'user', 'content': 'Reply with OK.'}],
                        stream=False, options={'num_predict': current_app.config['OLLAMA_CHAT_MAX_TOKENS']})
                    if not reply.done or reply.model != model or not reply.message.content:
                        raise ApiError(503, 'model_response_invalid', 'The model failed the generation check. Review its configuration.')
                return {'tier': tier, 'model': model, 'generation_checked': generate}
            result.append(self._call(verify))
        return result
