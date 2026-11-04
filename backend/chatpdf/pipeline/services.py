from dataclasses import dataclass

from flask import current_app
from langchain_core.embeddings import Embeddings

from .chunking import StructureChunker
from .config import PipelineSettings, import_factory
from .contracts import BatchParser, TransactionalVectorStore
from .embeddings import build_embeddings, validate_vectors


@dataclass
class PipelineServices:
    config: dict
    settings: PipelineSettings
    parser: BatchParser
    chunker: StructureChunker
    embeddings: Embeddings

    def store(self, owner_id: str, document_id: str) -> TransactionalVectorStore:
        store = import_factory(self.settings.vector_factory)(self.config,
            owner_id=owner_id, document_id=document_id, embedding=self.embeddings,
            profile=self.settings.fingerprint)
        if not isinstance(store, TransactionalVectorStore):
            raise TypeError('Vector factory must return TransactionalVectorStore')
        return store

    def embed(self, documents, stop=None):
        vectors = []
        step = self.settings.embedding_batch_size
        for offset in range(0, len(documents), step):
            if stop is not None and stop.is_set():
                raise InterruptedError("Embedding cancelled between sub-batches")
            group = documents[offset:offset + step]
            result = self.embeddings.embed_documents([document.page_content for document in group])
            validate_vectors(result, len(group))
            vectors.extend(result)
        validate_vectors(vectors, len(documents))
        return vectors


def get_services():
    config = dict(current_app.config)
    settings = PipelineSettings.from_config(config)
    cached = current_app.extensions.get('pipeline_services')
    if cached is None or cached.settings.fingerprint != settings.fingerprint:
        cached = PipelineServices(config, settings, import_factory(settings.parser_factory)(config),
                                  StructureChunker(settings), build_embeddings(config))
        if not isinstance(cached.embeddings, Embeddings):
            raise TypeError('Embedding factory must return LangChain Embeddings')
        current_app.extensions['pipeline_services'] = cached
    return cached
