#!/usr/bin/env python3
"""Publish one model archive, then record its S3 version and checksum for deployment."""
import argparse
import gzip
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile

RELEASE_PATH = Path(__file__).with_name('release.json')


def aws(region, *args):
    return subprocess.check_output(['aws', '--region', region, '--no-cli-pager', *args], text=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--region', required=True)
    parser.add_argument('--bucket', required=True)
    options = parser.parse_args()
    release = json.loads(RELEASE_PATH.read_text())
    if not re.fullmatch(r'[0-9a-f]{40}', release['model_revision']):
        parser.error('Use a full upstream model commit')
    if not re.fullmatch(r'models/[A-Za-z0-9._/-]+/model\.tar\.gz', release['key']) or '..' in release['key'].split('/'):
        parser.error('Use a safe models/.../model.tar.gz key')
    if release['version_id'] is not None or release['sha256'] is not None:
        parser.error('Release is already pinned. For a new release choose a new key and reset version_id/sha256 to null')
    status = json.loads(aws(options.region, 's3api', 'get-bucket-versioning', '--bucket', options.bucket))
    if status.get('Status') != 'Enabled':
        parser.error('Target bucket must have versioning enabled')
    existing = subprocess.run(['aws', '--region', options.region, '--no-cli-pager', 's3api', 'head-object',
                               '--bucket', options.bucket, '--key', release['key']], capture_output=True, text=True)
    if existing.returncode == 0:
        parser.error('Object key already exists. Select a new release key; do not overwrite published releases')
    if '(404)' not in existing.stderr and 'Not Found' not in existing.stderr:
        raise RuntimeError(f'Cannot check target object: {existing.stderr.strip()}')

    from huggingface_hub import snapshot_download
    with tempfile.TemporaryDirectory(prefix='vllm-model-') as temporary:
        work = Path(temporary).resolve()
        files = work / 'files'
        snapshot_download(repo_id=release['model_id'], revision=release['model_revision'], local_dir=files,
                          allow_patterns=['*.json', '*.safetensors', '*.txt', '*.model', '*.tiktoken', 'LICENSE*', 'README.md'])
        cache = files / '.cache'
        if cache.exists():
            shutil.rmtree(cache)
        for name in ('config.json', 'tokenizer_config.json', 'tokenizer.json'):
            if not (files / name).is_file():
                raise ValueError(f'Missing Qwen artifact: {name}')
        if not list(files.glob('*.safetensors')):
            raise ValueError('No safetensors weights found')
        index = files / 'model.safetensors.index.json'
        if index.exists():
            for shard in set(json.loads(index.read_text())['weight_map'].values()):
                path = files / shard
                if not path.resolve().is_relative_to(files) or not path.is_file():
                    raise ValueError(f'Missing or unsafe weight shard: {shard}')
        archive = work / 'model.tar.gz'
        # Archive only regular files; normalized metadata gives stable release bytes.
        with archive.open('wb') as output, gzip.GzipFile(filename='', fileobj=output, mode='wb', mtime=0, compresslevel=1) as compressed:
            with tarfile.open(fileobj=compressed, mode='w|', dereference=True) as package:
                for file in sorted(files.rglob('*')):
                    if file.is_symlink() or (not file.is_file() and not file.is_dir()):
                        raise ValueError(f'Unsupported artifact: {file}')
                    if file.is_dir():
                        continue
                    info = package.gettarinfo(str(file), arcname=file.relative_to(files).as_posix())
                    info.uid = info.gid = info.mtime = 0
                    info.uname = info.gname = ''
                    info.mode = 0o644
                    with file.open('rb') as content:
                        package.addfile(info, content)
        digest = hashlib.sha256()
        with archive.open('rb') as source:
            for chunk in iter(lambda: source.read(8 * 1024 * 1024), b''):
                digest.update(chunk)
        checksum = digest.hexdigest()
        # High-level cp uses multipart upload for archives larger than 5 GiB.
        aws(options.region, 's3', 'cp', str(archive), f"s3://{options.bucket}/{release['key']}",
            '--sse', 'AES256', '--checksum-algorithm', 'SHA256', '--only-show-errors',
            '--metadata', f"sha256={checksum},model-revision={release['model_revision']}")
        stored = json.loads(aws(options.region, 's3api', 'head-object', '--bucket', options.bucket, '--key', release['key']))
        if stored.get('Metadata', {}).get('sha256') != checksum or stored.get('VersionId') in (None, 'null'):
            raise RuntimeError('Uploaded object metadata/version mismatch; release configuration was not changed')
        release.update(version_id=stored['VersionId'], sha256=checksum)
        staged = RELEASE_PATH.with_suffix('.json.tmp')
        staged.write_text(json.dumps(release, indent=2) + '\n')
        staged.replace(RELEASE_PATH)
    print(f"Published s3://{options.bucket}/{release['key']} version {release['version_id']}")
    print('Review and commit models/release.json before deploying vLLM.')


if __name__ == '__main__':
    main()
