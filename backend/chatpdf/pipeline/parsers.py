class DoclingParser:
    def __init__(self, config):
        self.config = config

    def parse(self, job, start, end):
        # Keep heavy Docling/native libraries confined to the existing subprocess boundary.
        from ..ingestion import parse_in_process
        return parse_in_process(job, start, end)
