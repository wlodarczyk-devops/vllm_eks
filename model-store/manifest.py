"""Build and verify deterministic, path-safe model release manifests (stdlib only)."""
import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import re


def sha256_file(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(8 * 1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def safe_file(directory, relative):
    path = PurePosixPath(relative)
    if not relative or path.is_absolute() or '..' in path.parts or '\\' in relative or str(path) != relative:
        raise ValueError(f'Unsafe manifest path: {relative!r}')
    root = directory.resolve()
    file = root.joinpath(*path.parts)
    if file.is_symlink() or not file.resolve().is_relative_to(root) or not file.is_file():
        raise ValueError(f'Missing, escaping or symlinked model file: {relative}')
    return file


def build_manifest(directory, model_id, revision):
    if not re.fullmatch(r'[0-9a-f]{40}', revision):
        raise ValueError('Use a full Hugging Face commit, not a branch or tag')
    files = []
    for file in sorted(directory.rglob('*')):
        relative = file.relative_to(directory).as_posix()
        if relative.startswith('.cache/') or file.is_dir():
            continue
        file = safe_file(directory, relative)
        files.append({'path': relative, 'size': file.stat().st_size, 'sha256': sha256_file(file)})
    paths = {file['path'] for file in files}
    if not {'config.json', 'tokenizer_config.json', 'tokenizer.json'} <= paths:
        raise ValueError('Snapshot lacks required Qwen configuration/tokenizer files')
    if not any(path.endswith('.safetensors') for path in paths):
        raise ValueError('Snapshot has no safetensors weights')
    index = directory / 'model.safetensors.index.json'
    if index.exists():
        referenced = set(json.loads(index.read_text())['weight_map'].values())
        if not referenced <= paths:
            raise ValueError(f'Missing weight shards: {referenced - paths}')
    return {'schema_version': 1, 'model_id': model_id, 'revision': revision, 'files': files}


def verify(directory, manifest_path, expected_sha256):
    # Bind downloaded bytes to the manifest selected by the infrastructure state.
    if sha256_file(manifest_path) != expected_sha256:
        raise ValueError('Model manifest checksum does not match the selected release')
    manifest = json.loads(manifest_path.read_text())
    if manifest['schema_version'] != 1 or not manifest['files']:
        raise ValueError('Unsupported or empty model manifest')
    expected = set()
    for entry in manifest['files']:
        relative = entry['path']
        if relative in expected:
            raise ValueError(f'Duplicate model file: {relative}')
        expected.add(relative)
        file = safe_file(directory, relative)
        if file.stat().st_size != entry['size'] or sha256_file(file) != entry['sha256']:
            raise ValueError(f'Model file checksum/size mismatch: {relative}')
    actual = {file.relative_to(directory).as_posix() for file in directory.rglob('*') if not file.is_dir()}
    if actual != expected:
        raise ValueError(f'Model file inventory differs: unexpected={actual - expected}, missing={expected - actual}')
    return manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--manifest', type=Path, required=True)
    parser.add_argument('--manifest-sha256', required=True)
    options = parser.parse_args()
    verified = verify(options.directory, options.manifest, options.manifest_sha256)
    print(f"Verified {len(verified['files'])} files for {verified['model_id']}@{verified['revision']}")
