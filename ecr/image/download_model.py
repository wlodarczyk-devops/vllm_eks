"""Build-time download only; never runs in a serving pod."""
import json
import os
from pathlib import Path
import re
import shutil

from huggingface_hub import snapshot_download

model_id = os.environ['MODEL_ID']
revision = os.environ['MODEL_REVISION']
if not re.fullmatch(r'[0-9a-f]{40}', revision):
    raise ValueError('MODEL_REVISION must be a full commit hash')

root = Path('/opt/model')
snapshot_download(
    repo_id=model_id,
    revision=revision,
    local_dir=root,
    allow_patterns=['*.json', '*.safetensors', '*.txt', '*.model', '*.tiktoken', 'LICENSE*', 'README.md'],
)
cache = root / '.cache'
if cache.exists():
    shutil.rmtree(cache)
for name in ('config.json', 'tokenizer_config.json', 'tokenizer.json'):
    if not (root / name).is_file():
        raise ValueError(f'Missing required Qwen artifact: {name}')
if not list(root.glob('*.safetensors')):
    raise ValueError('Snapshot contains no safetensors weights')
index = root / 'model.safetensors.index.json'
if index.exists():
    for shard in set(json.loads(index.read_text())['weight_map'].values()):
        path = root / shard
        if not path.resolve().is_relative_to(root) or not path.is_file():
            raise ValueError(f'Missing or unsafe weight shard: {shard}')
# Final image files are root-owned and readable by the unprivileged serving user.
for path in root.rglob('*'):
    if path.is_symlink():
        raise ValueError(f'Unexpected symlink: {path}')
    path.chmod(0o755 if path.is_dir() else 0o644)
root.chmod(0o755)
print(f'Included {model_id}@{revision} at /opt/model')
