import json
from uuid import uuid4
from unittest.mock import patch

import pytest
from langchain_core.documents import Document

from chatpdf.chat import INSUFFICIENT, answer_schema, is_overview_question, source_evidence, verified_answer
from chatpdf.db import get_db, transaction
from chatpdf.errors import ApiError


def add_elements(app, document, elements):
    identifiers = []
    with app.app_context(), transaction() as db:
        for position, (page, kind, text) in enumerate(elements):
            identifier = str(uuid4())
            identifiers.append(identifier)
            db.execute('INSERT INTO extracted_elements VALUES (?,?,?,?,?,?,?)',
                       (identifier, document, page, position, kind, text, '{}'))
    return identifiers


@pytest.mark.parametrize('question', [
    'find the point of this pdf file', 'analyse the pdf file', 'Analyze this document',
    'Summarize the key ideas in this PDF.', 'What are the most important takeaways?',
    'What is this document about?', 'What is the main point?', 'Give me an overview',
    '이 PDF의 핵심을 알려줘', '문서를 요약해줘', '전체 내용을 분석해줘',
])
def test_document_overview_intent(question):
    assert is_overview_question(question)


@pytest.mark.parametrize('question', ['What is the approved budget?', 'What happened in 1990?', 'hi'])
def test_focused_questions_keep_semantic_retrieval(question):
    assert not is_overview_question(question)


def test_overview_uses_prose_across_pages_not_caption_search(app, seed):
    document = seed()
    add_elements(app, document, [
        (1, 'section_header', 'A lecture about global threats'),
        (1, 'picture', 'https://example.com/a [An illustration of global threats]'),
        (1, 'text', '대멸종의 위협을 인식하고 인류의 공동생존을 준비해야 한다.'),
        (14, 'text', '인류가 함께 위험에 대비하고 지구를 보호해야 한다.'),
    ])
    with app.app_context(), patch('chatpdf.chat.retrieve', side_effect=AssertionError('No nearest-neighbour summary')):
        sources = source_evidence('alice', document, 'find the point of this pdf file')
        assert {s['page_number'] for s in sources.values()} == {1, 14}
        assert all(s['element_type'] == 'text' for s in sources.values())
        assert source_evidence('bob', document, 'Summarize this PDF') == {}


def test_large_overview_is_bounded_and_covers_start_middle_end(app, seed):
    document = seed()
    add_elements(app, document, [(page, 'text', f'Page {page}: ' + 'Canonical supporting prose. ' * 180) for page in range(1, 101)])
    with app.app_context():
        sources = source_evidence('alice', document, 'Summarize the PDF')
        pages = {s['page_number'] for s in sources.values()}
        assert 1 in pages and 100 in pages and len(pages) == 24
        assert sum(len(s['content']) for s in sources.values()) <= 9000
        assert len(sources) <= 64
        for source in sources.values():
            original = get_db().execute('SELECT content FROM extracted_elements WHERE id=?', (source['element_id'],)).fetchone()[0]
            assert source['content'] in original


def test_focused_search_oversamples_and_rechecks_canonical_membership(app, seed):
    document, foreign = seed(), seed(owner='bob')
    ids = add_elements(app, document, [(3, 'picture', 'A figure caption without an interpretation'), (4, 'text', 'The approved budget is forty-two thousand dollars.')])
    foreign_id = add_elements(app, foreign, [(9, 'text', 'Private evidence belonging to another account.')])[0]
    with app.app_context(), transaction() as db:
        db.execute('UPDATE chunks SET metadata_json=? WHERE document_id=?',
                   (json.dumps({'source_element_ids': [*ids, foreign_id]}), document))
    with app.app_context(), patch('chatpdf.chat.retrieve', return_value=[Document(id=f'chunk-{document}', page_content='untrusted')]) as retrieval:
        sources = source_evidence('alice', document, 'What is the approved budget?')
        retrieval.assert_called_once_with('alice', document, 'What is the approved budget?', k=12)
        assert [s['page_number'] for s in sources.values()] == [4]


SOURCE = {'S1': {'element_id': 'element-1', 'page_number': 3, 'element_type': 'text', 'content': 'This is an exact canonical supporting passage.'}}
CLAIM = {'text': 'A supported statement.', 'source_id': 'S1', 'quote': 'exact canonical supporting passage'}


@pytest.mark.parametrize('value', [
    'not JSON', '[]', '{}', json.dumps({'insufficient': False, 'claims': []}),
    json.dumps({'insufficient': False, 'claims': [CLAIM] * 7}),
    json.dumps({'insufficient': False, 'claims': [CLAIM | {'quote': 'Invented quote that is not in the PDF'}]}),
    json.dumps({'insufficient': False, 'claims': [CLAIM | {'source_id': 'S999'}]}),
    json.dumps({'insufficient': False, 'claims': [CLAIM | {'text': 'Claim [Page 999]'}]}),
])
def test_invalid_model_output_is_a_retryable_error_not_insufficient_evidence(value):
    with pytest.raises(ApiError) as error:
        verified_answer(value, SOURCE)
    assert error.value.status == 503
    assert error.value.code == 'model_response_invalid'


def test_verified_answer_and_genuine_insufficiency_remain_distinct():
    content, citations = verified_answer(json.dumps({'insufficient': False, 'claims': [CLAIM]}), SOURCE)
    assert '[Page 3]' in content and citations[0]['snippet'] == CLAIM['quote']
    assert verified_answer('{"insufficient":true,"claims":[]}', SOURCE) == (INSUFFICIENT, [])
    schema = answer_schema(SOURCE)
    assert schema['properties']['claims']['maxItems'] == 4
    assert schema['properties']['claims']['items']['properties']['source_id']['enum'] == ['S1']


def test_overview_endpoint_persists_cited_exchange_and_blocks_other_owner(app, client, headers, seed):
    document = seed()
    app.config['LLAMA_MODEL_TAG'] = 'llama3.1:8b'
    add_elements(app, document, [(1, 'text', 'The central point is to prepare together for global threats.'), (14, 'text', 'Cooperation is essential to protect humanity and Earth.')])
    def generate(user, messages, *, response_format):
        payload = json.loads(messages[-1]['content'])
        assert {s['page_number'] for s in payload['passages'].values()} == {1, 14}
        assert response_format['properties']['passage_ids']['maxItems'] == 4
        return json.dumps({'passage_ids': ['P1']})
    with patch('chatpdf.chat.OllamaChatService.chat', side_effect=generate) as model:
        response = client.post(f'/api/v1/documents/{document}/chat', headers=headers(), json={'question': 'find the point of this pdf file'})
        assert response.status_code == 200
        assert response.json['message']['citations'][0]['page_number'] == 1
        assert INSUFFICIENT not in response.json['message']['content']
        assert client.post(f'/api/v1/documents/{document}/chat', headers=headers('bob'), json={'question': 'Summarize the PDF'}).status_code == 404
        assert model.call_count == 1
    with app.app_context():
        assert get_db().execute('SELECT count(*) FROM messages WHERE conversation_id=?', (response.json['conversation_id'],)).fetchone()[0] == 2


def test_invalid_generation_does_not_save_a_false_insufficient_answer(app, client, headers, seed):
    document = seed()
    app.config['LLAMA_MODEL_TAG'] = 'llama3.1:8b'
    add_elements(app, document, [(1, 'text', 'Substantive prose that supports a document summary.')])
    with app.app_context():
        before = get_db().execute('SELECT count(*) FROM messages').fetchone()[0]
    with patch('chatpdf.chat.OllamaChatService.chat', return_value='broken JSON'):
        response = client.post(f'/api/v1/documents/{document}/chat', headers=headers(), json={'question': 'Summarize the PDF'})
    assert response.status_code == 503
    assert response.json['error']['code'] == 'model_response_invalid'
    with app.app_context():
        assert get_db().execute('SELECT count(*) FROM messages').fetchone()[0] == before


def test_one_bad_quote_does_not_discard_other_independently_verified_claims():
    bad = CLAIM | {'text': 'Unsupported statement.', 'quote': 'Invented quote that must never appear'}
    content, citations = verified_answer(json.dumps({'insufficient': False, 'claims': [bad, CLAIM]}), SOURCE)
    assert content == 'A supported statement. [Page 3]'
    assert len(citations) == 1
    assert 'Unsupported' not in content

@pytest.mark.parametrize('raw', ['broken JSON', '{}', '{"passage_ids":[]}', '{"passage_ids":["P999"]}', '{"passage_ids":"P1"}', '{"passage_ids":[null]}'])
def test_overview_selection_cannot_invent_or_omit_passages(app, raw):
    from chatpdf.chat import overview_answer
    with app.app_context(), patch('chatpdf.chat.OllamaChatService.chat', return_value=raw):
        with pytest.raises(ApiError) as error:
            overview_answer('alice', 'Summarize the PDF', SOURCE)
        assert error.value.code == 'model_response_invalid'


def test_overview_displays_only_the_selected_canonical_words(app):
    from chatpdf.chat import overview_answer, overview_passages
    sources = SOURCE | {'S2': {'element_id': 'element-2', 'page_number': 14, 'element_type': 'text', 'content': 'The conclusion is that humanity must work together to survive.'}}
    passages = overview_passages(sources)
    with app.app_context(), patch('chatpdf.chat.OllamaChatService.chat', return_value='{"passage_ids":["P2","P1","P2"]}'):
        content, citations = overview_answer('alice', 'Summarize this PDF', sources)
        assert content.startswith('Key passages from this PDF:')
        assert len(citations) == 2
        assert citations[0]['page_number'] == 14
        for citation in citations:
            assert citation['snippet'] in sources[citation['source_id']]['content']
            assert citation['snippet'] in content
        assert passages['P2']['quote'] in content


def test_empty_extraction_keeps_real_insufficiency_without_calling_model(app, client, headers, seed):
    document = seed()
    app.config['LLAMA_MODEL_TAG'] = 'llama3.1:8b'
    with patch('chatpdf.chat.OllamaChatService.chat') as model:
        response = client.post(f'/api/v1/documents/{document}/chat', headers=headers(), json={'question': 'Summarize the PDF'})
        assert response.status_code == 200
        assert response.json['message']['content'] == INSUFFICIENT
        assert response.json['message']['citations'] == []
        model.assert_not_called()


def test_chat_transport_passes_server_schema_to_ollama(app):
    from types import SimpleNamespace
    from unittest.mock import MagicMock
    from chatpdf.ollama_chat import OllamaChatService
    app.config.update(LLAMA_MODEL_TAG='llama3.1:8b', OLLAMA_BASE_URL='http://127.0.0.1:11434')
    fake = MagicMock()
    fake.__enter__.return_value = fake
    fake.chat.return_value = SimpleNamespace(done=True, model='llama3.1:8b', message=SimpleNamespace(role='assistant', content='{"passage_ids":["P1"]}'))
    schema = {'type': 'object', 'properties': {'passage_ids': {'type': 'array'}}}
    with app.app_context():
        result = OllamaChatService(client_factory=lambda **_: fake).chat('alice', [{'role': 'user', 'content': 'test'}], response_format=schema)
        assert result == '{"passage_ids":["P1"]}'
        assert fake.chat.call_args.kwargs['format'] == schema
        assert fake.chat.call_args.kwargs['model'] == 'llama3.1:8b'
