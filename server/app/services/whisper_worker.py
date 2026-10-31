"""Standalone CTranslate2 worker. Reuse the app's validated shard protocol."""
import json
import os
from pathlib import Path
import sys

def main(request_path, device):
    handles=[]
    if device=='cuda' and os.name=='nt':
        import torch
        libraries=Path(torch.__file__).parent/'lib'
        handles.append(os.add_dll_directory(str(libraries)))
        os.environ['PATH']=str(libraries)+os.pathsep+os.environ.get('PATH','')
        torch.backends.cudnn.version()
    from faster_whisper import WhisperModel
    request=json.loads(Path(request_path).read_text('utf-8'))
    model=WhisperModel(request['model_path'],device=device,device_index=request.get('gpu_index',0),
                       compute_type='int8_float16' if device=='cuda' else 'int8',local_files_only=True)
    phase=request.get('progress_phase','transcribing')
    def progress(done):
        if request.get('progress_path'):
            path=Path(request['progress_path']); temp=path.with_suffix('.worker.tmp')
            try:
                temp.write_text(json.dumps(dict(generation=request.get('generation'),phase=phase,
                    completed_chunks=done if phase!='tail' else None,total_chunks=len(request['chunks']) if phase!='tail' else None)),'utf-8')
                temp.replace(path)
            except OSError: pass
    for index,chunk in enumerate(request['chunks']):
        progress(index)
        output=Path(chunk['output'])
        if output.exists(): continue
        values,info=model.transcribe(chunk['audio'],language='zh',task='transcribe',beam_size=5,
                                     vad_filter=True,word_timestamps=True,condition_on_previous_text=False)
        segments=[dict(s=float(v.start)+chunk['offset'],e=float(v.end)+chunk['offset'],t=v.text.strip()) for v in values if v.text.strip()]
        value=dict(segments=segments,aligned=bool(segments),device=device,peak_vram_mb=None if device=='cuda' else 0)
        temp=output.with_suffix('.tmp');temp.write_text(json.dumps(value,ensure_ascii=False),'utf-8');temp.replace(output)
        progress(index+1)

if __name__=='__main__': main(sys.argv[1],sys.argv[2])
