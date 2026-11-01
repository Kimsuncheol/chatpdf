import copy
from collections import defaultdict
from uuid import NAMESPACE_URL, uuid5

from langchain_core.documents import Document
from langchain_text_splitters import RecursiveCharacterTextSplitter


class ChunkLimitError(ValueError):
    pass


def materialize_elements(document_id, elements):
    positions = defaultdict(int)
    result = []
    for original in elements:
        element = copy.deepcopy(original)
        page = element['page_number']
        ordinal = positions[page]
        positions[page] += 1
        element['id'] = str(uuid5(NAMESPACE_URL, f'{document_id}:element:{page}:{ordinal}'))
        element['position'] = ordinal
        element.setdefault('metadata', {})
        element['metadata'].setdefault('page_numbers', [page])
        result.append(element)
    return result


class StructureChunker:
    """Pack paragraphs, repeat heading context, and split tables only between row groups."""
    def __init__(self, settings):
        self.settings = settings

    def split(self, document_id, elements, context=None):
        context = copy.deepcopy(context or {})
        headings = context.get('headings', [])
        output, warnings = [], []
        pending, pending_size = [], 0
        ordinals = defaultdict(int)
        seen = set()

        def emit(text, sources, kind, extra=None):
            if not text.strip():
                return
            prefix = '\n'.join(heading['text'] for heading in headings)
            content = f'{prefix}\n\n{text}' if prefix else text
            page = sources[0]['page_number']
            if len(content) > self.settings.max_chunk_size:
                raise ChunkLimitError('An atomic row or heading exceeds MAX_CHUNK_SIZE')
            metadata = {
                'document_id': document_id, 'page_number': page,
                'page_numbers': sorted({p for element in sources for p in element['metadata']['page_numbers']} |
                                       {heading['page_number'] for heading in headings}),
                'element_types': sorted({element['element_type'] for element in sources} |
                                        {heading.get('element_type', 'section_header') for heading in headings}),
                'element_type': kind, 'source_element_ids': [element['id'] for element in sources],
                'heading_context': copy.deepcopy(headings), 'visual_understanding': False,
                'figures': [element['metadata']['figure'] | {'document_id': document_id}
                            for element in sources if 'figure' in element['metadata']],
            }
            if extra: metadata.update(extra)
            identifier = str(uuid5(NAMESPACE_URL, f'{document_id}:chunk:{page}:{ordinals[page]}'))
            ordinals[page] += 1
            output.append(Document(id=identifier, page_content=content, metadata=metadata))

        def flush():
            nonlocal pending, pending_size
            if pending:
                emit('\n\n'.join(element['content'] for element in pending), pending, 'text')
            pending, pending_size = [], 0

        for element in elements:
            label, text = element['element_type'], element['content']
            metadata = element['metadata']
            # A multi-page Docling item is represented on every source page, but
            # indexed only once, with all supporting page numbers retained.
            key = (metadata.get('docling_ref'), tuple(metadata['page_numbers']), label)
            if metadata.get('docling_ref') and key in seen:
                continue
            seen.add(key)
            if pending and pending[0]['page_number'] != element['page_number']:
                flush()
            if label in ('title', 'section_header'):
                flush()
                level = 0 if label == 'title' else int(metadata.get('heading_level', 1))
                headings = [heading for heading in headings if heading['level'] < level]
                headings.append({'level': level, 'element_type': label, 'text': text, 'page_number': element['page_number'], 'element_id': element['id']})
                if len(str(headings)) > 16000:
                    raise ChunkLimitError('Heading context is too large')
                continue
            if label in ('page_header', 'page_footer') or metadata.get('attached_caption'):
                continue
            if label in ('picture', 'chart') or 'figure' in metadata:
                flush()
                # Caption text is explicit source evidence; image meaning is not inferred.
                if text.strip():
                    emit('Figure reference (visual content not interpreted). Caption: ' + text,
                         [element], label, {'evidence_kind': 'figure_caption'})
                continue
            if label == 'table' and metadata.get('table_rows'):
                flush()
                rows = metadata['table_rows']
                headers = [row['text'] for row in rows if row['header']]
                caption = metadata.get('caption', '')
                introduction = '\n'.join(filter(None, [caption, *headers]))
                cells = metadata.get('table_spans', [])
                body = [row for row in rows if not row['header']]
                groups = []
                index = 0
                while index < len(body):
                    group = [body[index]]
                    end = body[index]['index'] + 1
                    changed = True
                    while changed:
                        changed = False
                        for start_row, end_row in cells:
                            if group[0]['index'] <= start_row < end and end_row > end:
                                end = end_row; changed = True
                    index += 1
                    while index < len(body) and body[index]['index'] < end:
                        group.append(body[index]); index += 1
                    groups.append(group)
                packed, row_indexes = [], []
                for group in groups:
                    block = '\n'.join(row['text'] for row in group)
                    if packed and len(introduction) + sum(len(part) for part in packed) + len(block) > self.settings.chunk_size:
                        emit('\n'.join(filter(None, [introduction, *packed])), [element], 'table', {'table_rows': row_indexes})
                        packed, row_indexes = [], []
                    packed.append(block)
                    row_indexes.extend(row['index'] for row in group)
                if packed or introduction:
                    emit('\n'.join(filter(None, [introduction, *packed])), [element], 'table', {'table_rows': row_indexes})
                if len(text) > self.settings.chunk_size:
                    warnings.append({'page_number': element['page_number'], 'code': 'table_chunked_by_rows'})
                continue
            if not text.strip():
                continue
            prefix_size = sum(len(heading['text']) + 1 for heading in headings)
            budget = max(128, self.settings.chunk_size - prefix_size)
            if len(text) > budget:
                flush()
                splitter = RecursiveCharacterTextSplitter(chunk_size=budget,
                    chunk_overlap=min(self.settings.chunk_overlap, budget // 4),
                    separators=['\n\n', '\n', '. ', ' ', ''])
                for fragment in splitter.split_text(text):
                    emit(fragment, [element], label)
            else:
                if pending and pending_size + len(text) + prefix_size > self.settings.chunk_size:
                    flush()
                pending.append(element)
                pending_size += len(text) + 2
        flush()
        return output, {'headings': headings}, warnings
