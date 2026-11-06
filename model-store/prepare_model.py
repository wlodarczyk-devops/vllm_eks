#!/usr/bin/env python3
"""Stage an exact Hugging Face snapshot locally. Does not access AWS or upload."""
import argparse
import json
import re
from pathlib import Path
import shutil

from manifest import build_manifest


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--model', default='Qwen/Qwen3-4B-Instruct-2507')
    parser.add_argument('--revision', default='cdbee75f17c01a7cc42f958dc650907174af0554')
    parser.add_argument('--output', type=Path, default=Path(__file__).parent / 'artifacts/qwen3-4b-2507')
    options = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", options.revision):
        parser.error("Revision must be a full 40-character commit")
    if options.output.exists():
        parser.error('Output already exists: use a new release directory to avoid stale files')
    # Import only for actual preparation; manifest verification has no dependencies.
    from huggingface_hub import snapshot_download

    model_directory = options.output / 'files'
    snapshot_download(repo_id=options.model, revision=options.revision, local_dir=model_directory,
                      allow_patterns=['*.json', '*.safetensors', '*.txt', '*.model', '*.tiktoken', 'LICENSE*', 'README.md'])
    # Hub metadata is not a model artifact. Remove only the generated download cache.
    cache = model_directory / '.cache'
    if cache.exists():
        shutil.rmtree(cache)
    manifest = build_manifest(model_directory, options.model, options.revision)
    destination = options.output / 'manifest.json'
    destination.write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
    print(f'Staged {len(manifest["files"])} model files in {options.output}')
    print('Review the manifest, then deploy the model-store stack to upload the release.')


if __name__ == '__main__':
    main()
