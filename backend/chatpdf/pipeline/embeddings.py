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
        headers = {}
        if config.get('OLLAMA_API_KEY'):
            headers['Authorization'] = 'Bearer ' + config['OLLAMA_API_KEY']
        self.client = Client(host=config['OLLAMA_BASE_URL'], timeout=config['EMBEDDING_TIMEOUT'],
                             headers=headers, follow_redirects=False, trust_env=False)
        self.model = config['EMBEDDING_MODEL']
        self.dimensions = config['EMBEDDING_DIMENSIONS'] or None

    def embed_documents(self, texts):
        return self.client.embed(model=self.model, input=texts,
            dimensions=self.dimensions, truncate=False)['embeddings']

    def embed_query(self, text):
        return self.embed_documents([text])[0]


class JinaEmbeddings(Embeddings):
    """Hosted multilingual embeddings; document/query tasks remain consistent."""
    def __init__(self, config):
        if not config.get('JINA_API_KEY') or not config.get('EMBEDDING_MODEL'):
            raise ValueError('Set JINA_API_KEY and EMBEDDING_MODEL on the server')
        self.key = config['JINA_API_KEY']
        self.model = config['EMBEDDING_MODEL']
        self.timeout = config['EMBEDDING_TIMEOUT']
        self.dimensions = config['EMBEDDING_DIMENSIONS']

    def _embed(self, texts, task):
        import httpx
        body = {'model': self.model, 'input': texts, 'task': task,
                'normalized': True, 'embedding_type': 'float', 'truncate': False}
        if self.dimensions:
            body['dimensions'] = self.dimensions
        with httpx.Client(timeout=self.timeout, follow_redirects=False, trust_env=False) as client:
            response = client.post('https://api.jina.ai/v1/embeddings', json=body,
                headers={'Authorization': 'Bearer ' + self.key})
            # Do not include private request data or provider response bodies in errors.
            if response.status_code != 200:
                raise ValueError('Embedding provider rejected the request')
            rows = response.json()['data']
        if sorted(item['index'] for item in rows) != list(range(len(texts))):
            raise ValueError('Invalid embedding response indices')
        vectors = [item['embedding'] for item in sorted(rows, key=lambda item: item['index'])]
        validate_vectors(vectors, len(texts))
        return vectors

    def embed_documents(self, texts):
        return self._embed(texts, 'retrieval.passage')

    def embed_query(self, text):
        return self._embed([text], 'retrieval.query')[0]


class LocalE5Embeddings(Embeddings):
    def __init__(self, config):
        from pathlib import Path
        from ..e5_local import MODEL, FILES
        if config['EMBEDDING_MODEL'] != MODEL or config['EMBEDDING_DIMENSIONS'] not in (0, 384):
            raise ValueError('Local E5 requires intfloat/multilingual-e5-small and 384 dimensions')
        self.directory = str(Path(config['E5_MODEL_PATH']).resolve())
        if not all((Path(self.directory)/filename).is_file() for filename in FILES):
            raise ValueError('Download pinned local E5 artifacts before starting')
        self.timeout = config['EMBEDDING_TIMEOUT']

    def _embed(self, texts, prefix):
        import json, subprocess, sys, tempfile
        from pathlib import Path
        if not texts: return []
        with tempfile.TemporaryDirectory(prefix='chatpdf-e5-') as temporary:
            source, target = Path(temporary)/'input.json', Path(temporary)/'output.json'
            source.write_text(json.dumps({'texts':texts,'prefix':prefix})); source.chmod(0o600)
            result = subprocess.run([sys.executable,'-m','chatpdf.e5_local','infer',self.directory,str(source),str(target)],
                cwd=Path(__file__).resolve().parents[2],timeout=self.timeout,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
            if result.returncode or not target.is_file(): raise ValueError('Local E5 inference failed')
            vectors = json.loads(target.read_text())
        validate_vectors(vectors,len(texts))
        return vectors

    def embed_documents(self,texts): return self._embed(texts,'passage: ')
    def embed_query(self,text): return self._embed([text],'query: ')[0]


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
        case 'local-e5':
            return LocalE5Embeddings(config)
        case 'jina':
            return JinaEmbeddings(config)
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
