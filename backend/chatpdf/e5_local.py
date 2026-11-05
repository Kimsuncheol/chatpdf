"""Pinned local E5 inference in a disposable CPU subprocess."""
import json
import sys
from pathlib import Path
MODEL = 'intfloat/multilingual-e5-small'
REVISION = '614241f622f53c4eeff9890bdc4f31cfecc418b3'
FILES = ['onnx/model_qint8_avx512_vnni.onnx', 'tokenizer.json']


def download(directory):
    from huggingface_hub import hf_hub_download
    for filename in FILES:
        hf_hub_download(MODEL, filename, revision=REVISION, local_dir=directory)


def infer(directory, payload):
    import fcntl
    import numpy as np
    import onnxruntime as ort
    from tokenizers import Tokenizer
    with open('/tmp/chatpdf-e5-inference.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        tokenizer = Tokenizer.from_file(str(Path(directory)/'tokenizer.json'))
        tokenizer.no_truncation(); tokenizer.no_padding()
        options = ort.SessionOptions()
        options.intra_op_num_threads = options.inter_op_num_threads = 1
        options.enable_cpu_mem_arena = options.enable_mem_pattern = False
        options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_DISABLE_ALL
        session = ort.InferenceSession(str(Path(directory)/FILES[0]), sess_options=options, providers=['CPUExecutionProvider'])
        names = {item.name for item in session.get_inputs()}
        vectors = []
        for text in payload['texts']:
            ids = tokenizer.encode(payload['prefix']+text, add_special_tokens=False).ids
            total = np.zeros(384, dtype=np.float64); weight = 0
            for offset in range(0, max(1,len(ids)),510):
                tokens = [tokenizer.token_to_id('<s>'), *ids[offset:offset+510], tokenizer.token_to_id('</s>')]
                array = np.asarray([tokens], dtype=np.int64)
                inputs = {'input_ids':array,'attention_mask':np.ones_like(array),'token_type_ids':np.zeros_like(array)}
                hidden = session.run(None,{name:inputs[name] for name in names})[0][0]
                total += hidden.sum(axis=0); weight += len(tokens)
            vector = total/weight; norm = np.linalg.norm(vector)
            if not np.isfinite(norm) or norm == 0: raise ValueError('Invalid local vector')
            vectors.append((vector/norm).tolist())
        return vectors


if __name__ == '__main__':
    if sys.argv[1] == 'download': download(sys.argv[2])
    else:
        try: Path(sys.argv[4]).write_text(json.dumps(infer(sys.argv[2],json.loads(Path(sys.argv[3]).read_text()))))
        except Exception: raise SystemExit(1) from None
