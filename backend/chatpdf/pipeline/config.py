import hashlib
import importlib
import json
from dataclasses import dataclass


@dataclass(frozen=True)
class PipelineSettings:
    fingerprint: str
    embedding_profile: str
    parser_factory: str
    vector_factory: str
    chunk_size: int
    chunk_overlap: int
    max_chunk_size: int
    embedding_batch_size: int

    @classmethod
    def from_config(cls, config):
        provider = config['EMBEDDING_PROVIDER']
        embedding = {key: config.get(key) for key in ('EMBEDDING_PROVIDER', 'EMBEDDING_MODEL',
            'EMBEDDING_REVISION', 'EMBEDDING_DIMENSIONS')}
        if provider == 'ollama': embedding['base_url'] = config.get('OLLAMA_BASE_URL')
        elif provider == 'openai': embedding['base_url'] = config.get('OPENAI_BASE_URL')
        elif provider == 'custom': embedding['factory'] = config.get('EMBEDDING_FACTORY')
        elif provider == 'hash-demo': embedding.pop('EMBEDDING_MODEL', None)
        parser = {key: config.get(key) for key in (
            'PARSER_FACTORY', 'PARSER_REVISION', 'DOCLING_PIPELINE', 'DOCLING_OCR',
            'DOCLING_OCR_ENGINE', 'DOCLING_OCR_LANGUAGES', 'DOCLING_OCR_FORCE_FULL_PAGE',
            'DOCLING_ARTIFACTS_PATH', 'INGESTION_BATCH_PAGES', 'CHUNK_SIZE', 'CHUNK_OVERLAP', 'MAX_CHUNK_SIZE',
            'LOW_TEXT_CHARACTERS', 'VECTOR_STORE_FACTORY', 'VECTOR_STORE_REVISION',
            'VECTOR_STORE_URL', 'VECTOR_STORE_NAMESPACE')}
        digest = lambda value: hashlib.sha256(json.dumps(value, sort_keys=True).encode()).hexdigest()
        return cls(digest({'parser': parser, 'embedding': embedding, 'implementation': 1}),
            digest(embedding), config['PARSER_FACTORY'], config['VECTOR_STORE_FACTORY'],
            config['CHUNK_SIZE'], config['CHUNK_OVERLAP'], config['MAX_CHUNK_SIZE'],
            config['EMBEDDING_BATCH_SIZE'])


def import_factory(spec):
    module, separator, name = spec.partition(':')
    if not separator or not module or not name:
        raise ValueError('Factory must be a server-configured module:callable')
    return getattr(importlib.import_module(module), name)
