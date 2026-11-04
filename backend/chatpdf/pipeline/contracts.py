from typing import Protocol

from langchain_core.documents import Document
from langchain_core.embeddings import Embeddings
from langchain_core.vectorstores import VectorStore


class IndexCompatibilityError(ValueError):
    pass


class BatchParser(Protocol):
    def parse(self, job: dict, start: int, end: int) -> dict | None:
        """Return original-page elements, quality and warnings; None means cancelled."""
        ...


class TransactionalVectorStore(VectorStore):
    """LangChain vector store with a publication contract for the durable worker.

    publish/count/delete_document participate in the caller's fenced transaction.
    A replacement must persist its own manifest here, or implement a transactional
    outbox plus visibility fencing. Uncommitted remote vectors must never be visible.
    """
    def publish(self, connection, documents: list[Document], vectors: list[list[float]]) -> None:
        raise NotImplementedError

    def count_indexed(self, connection) -> int:
        raise NotImplementedError

    def delete_document(self, connection) -> None:
        raise NotImplementedError


class EmbeddingFactory(Protocol):
    def __call__(self, config: dict) -> Embeddings: ...


class VectorStoreFactory(Protocol):
    def __call__(self, config: dict, *, owner_id: str, document_id: str,
                 embedding: Embeddings | None, profile: str | None) -> TransactionalVectorStore: ...
