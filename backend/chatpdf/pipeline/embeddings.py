import hashlib
import math
import re

from langchain_core.embeddings import Embeddings

from .config import import_factory


class StrictOllamaEmbeddings(Embeddings):
    """LangChain embedding interface; reject input overflow rather than truncate rows."""
    def __init__(self, config):
        from ollama import Client
        if not config.get('OLLAMA_BASE_URL') or not config.get('EMBEDDING_MODEL'):
            raise ValueError('Set OLLAMA_BASE_URL and EMBEDDING_MODEL on the server')
        self.client = Client(host=config['OLLAMA_BASE_URL'], timeout=config['EMBEDDING_TIMEOUT'])
        self.model = config['EMBEDDING_MODEL']
        self.dimensions = config['EMBEDDING_DIMENSIONS'] or None

    def embed_documents(self, texts):
        return self.client.embed(model=self.model, input=texts,
            dimensions=self.dimensions, truncate=False)['embeddings']

    def embed_query(self, text):
        return self.embed_documents([text])[0]


class DemoHashEmbeddings(Embeddings):
    """Offline lexical feature hashing. A demonstration aid, NOT semantic embeddings."""
    def __init__(self, dimensions=256):
        self.dimensions = dimensions

    def embed_query(self, text):
        vector = [0.0] * self.dimensions
        words = re.findall(r'\w+', text.casefold())
        for word in words:
            value = int.from_bytes(hashlib.sha256(word.encode()).digest()[:8], 'big')
            vector[value % self.dimensions] += 1.0
        norm = math.sqrt(sum(value * value for value in vector)) or 1
        return [value / norm for value in vector]

    def embed_documents(self, texts):
        return [self.embed_query(text) for text in texts]


def build_embeddings(config):
    match config['EMBEDDING_PROVIDER']:
        case 'ollama':
            return StrictOllamaEmbeddings(config)
        case 'openai':
            from langchain_openai import OpenAIEmbeddings
            if not all(config.get(key) for key in ('OPENAI_API_KEY', 'OPENAI_BASE_URL', 'EMBEDDING_MODEL')):
                raise ValueError('Set OPENAI_API_KEY, OPENAI_BASE_URL and EMBEDDING_MODEL on the server')
            return OpenAIEmbeddings(model=config['EMBEDDING_MODEL'], api_key=config['OPENAI_API_KEY'],
                base_url=config.get('OPENAI_BASE_URL') or None,
                dimensions=config['EMBEDDING_DIMENSIONS'] or None,
                request_timeout=config['EMBEDDING_TIMEOUT'], max_retries=0)
        case 'hash-demo':
            return DemoHashEmbeddings(config['EMBEDDING_DIMENSIONS'] or 256)
        case 'custom':
            return import_factory(config['EMBEDDING_FACTORY'])(config)
        case _:
            raise ValueError('Unsupported embedding provider')


def validate_vectors(vectors, count):
    if len(vectors) != count:
        raise ValueError('Embedding provider returned the wrong vector count')
    dimensions = len(vectors[0]) if vectors else 0
    for vector in vectors:
        if not 1 <= dimensions <= 32768 or len(vector) != dimensions or not all(math.isfinite(value) for value in vector):
            raise ValueError('Embedding provider returned an invalid vector')
        if not any(vector) or not math.isfinite(math.hypot(*vector)):
            raise ValueError('Embedding provider returned an empty vector')
    return dimensions
