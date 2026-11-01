import heapq
import json
import math
import struct

from langchain_core.documents import Document

from ..db import get_db
from ..errors import ApiError
from .contracts import TransactionalVectorStore, IndexCompatibilityError
from .embeddings import validate_vectors


class SQLiteVectorStore(TransactionalVectorStore):
    """Persistent exact cosine search, streamed per owned document (not an ANN index)."""
    def __init__(self, config, *, owner_id, document_id, embedding=None, profile=None):
        self.owner_id = owner_id
        self.document_id = document_id
        self._embedding = embedding
        self.profile = profile

    @property
    def embeddings(self):
        return self._embedding

    @classmethod
    def from_texts(cls, texts, embedding, metadatas=None, **kwargs):
        raise NotImplementedError('Publish via the ingestion checkpoint so data and progress stay atomic')

    def publish(self, connection, documents, vectors):
        dimensions = validate_vectors(vectors, len(documents))
        existing = connection.execute('SELECT DISTINCT e.dimensions FROM embeddings e JOIN chunks c ON c.id=e.chunk_id '
            'WHERE c.document_id=? AND e.profile=?', (self.document_id, self.profile)).fetchall()
        if vectors and any(row[0] != dimensions for row in existing):
            raise IndexCompatibilityError('Embedding dimensions changed within one profile; reindex required')
        for document, vector in zip(documents, vectors, strict=True):
            norm = math.hypot(*vector)
            vector = [value/norm for value in vector]
            connection.execute('INSERT INTO embeddings(chunk_id,vector,profile,dimensions) VALUES (?,?,?,?)',
                (document.id, struct.pack(f'<{dimensions}f', *vector), self.profile, dimensions))

    def count_indexed(self, connection):
        return connection.execute('SELECT count(*) FROM embeddings e JOIN chunks c ON c.id=e.chunk_id '
            'WHERE c.document_id=? AND e.profile=?', (self.document_id, self.profile)).fetchone()[0]

    def delete_document(self, connection):
        connection.execute('DELETE FROM embeddings WHERE chunk_id IN '
                           '(SELECT id FROM chunks WHERE document_id=?)', (self.document_id,))

    def similarity_search(self, query, k=4, **kwargs):
        return [document for document, _ in self.similarity_search_with_score(query, k=k)]

    def similarity_search_with_score(self, query, k=4, **kwargs):
        if type(k) is not int or not 1 <= k <= 20:
            raise ValueError('k must be between 1 and 20')
        if self.embeddings is None:
            raise ValueError('Query embeddings are not configured')
        vector = self.embeddings.embed_query(query)
        validate_vectors([vector], 1)
        norm = math.hypot(*vector)
        # Authorization is rechecked AFTER the embedding call, including deletion/readiness.
        cursor = get_db().execute('SELECT c.id,c.content,c.metadata_json,e.vector,e.dimensions FROM chunks c '
            'JOIN documents d ON d.id=c.document_id JOIN embeddings e ON e.chunk_id=c.id '
            "WHERE d.id=? AND d.owner_id=? AND d.status='ready' AND d.index_profile=? AND e.profile=?",
            (self.document_id, self.owner_id, self.profile, self.profile))
        best = []
        for row in cursor:
            if row['dimensions'] != len(vector) or len(row['vector']) != 4 * row['dimensions']:
                raise ApiError(409, 'reindex_required', 'Embedding dimensions changed; reindex this document.')
            candidate = struct.unpack(f'<{row["dimensions"]}f', row['vector'])
            denominator = norm * math.sqrt(sum(value * value for value in candidate))
            score = sum(a*b for a, b in zip(vector, candidate, strict=True)) / denominator if denominator else 0
            item = (score, row['id'], row['content'], row['metadata_json'])
            if len(best) < k: heapq.heappush(best, item)
            elif item[:2] > best[0][:2]: heapq.heapreplace(best, item)
        return [(Document(id=identifier, page_content=content, metadata=json.loads(metadata)), score)
                for score, identifier, content, metadata in sorted(best, reverse=True)]
