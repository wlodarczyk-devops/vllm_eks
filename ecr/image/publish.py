#!/usr/bin/env python3
"""Publish engine/downloader images independently of model releases. No Terraform."""
import argparse
import json
from pathlib import Path
import re
import subprocess

IMAGE_DIRECTORY = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--region', required=True)
    parser.add_argument('--repository', required=True)
    options = parser.parse_args()
    release = json.loads((IMAGE_DIRECTORY / 'release.json').read_text())
    images = [
        ('Dockerfile', 'VLLM_BASE_IMAGE', release['base_image'], release['image_tag']),
        ('Dockerfile.downloader', 'DOWNLOADER_BASE_IMAGE', release['downloader_base_image'], release['downloader_tag']),
    ]
    if release['image_tag'] == release['downloader_tag']:
        parser.error('Engine and downloader require different release tags')
    for _, _, base, tag in images:
        if not re.search(r'@sha256:[0-9a-f]{64}$', base):
            parser.error('Base images must include SHA-256 digests')
        if tag == 'latest' or not re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}', tag):
            parser.error('Use versioned image tags')

    aws = ['aws', '--region', options.region, '--no-cli-pager', 'ecr']
    repository = json.loads(subprocess.check_output(aws + ['describe-repositories', '--repository-names', options.repository, '--output', 'json'], text=True))['repositories'][0]
    if repository['imageTagMutability'] != 'IMMUTABLE':
        parser.error('Target repository must use immutable tags')
    registry = repository['repositoryUri'].split('/', 1)[0]
    password = subprocess.check_output(aws + ['get-login-password'])
    subprocess.run(['docker', 'login', '--username', 'AWS', '--password-stdin', registry], input=password, check=True)
    del password
    for dockerfile, argument, base, tag in images:
        existing = subprocess.run(aws + ['describe-images', '--repository-name', options.repository,
                                        '--image-ids', f'imageTag={tag}', '--output', 'json'], capture_output=True, text=True)
        if existing.returncode == 0:
            print(f'Reusing immutable image {repository["repositoryUri"]}:{tag}')
            continue
        if 'ImageNotFoundException' not in existing.stderr:
            raise RuntimeError(f'Cannot check release tag: {existing.stderr.strip()}')
        subprocess.run([
            'docker', 'buildx', 'build', '--platform', 'linux/amd64',
            '--file', str(IMAGE_DIRECTORY / dockerfile), '--build-arg', f'{argument}={base}',
            '--tag', f'{repository["repositoryUri"]}:{tag}', '--push', str(IMAGE_DIRECTORY),
        ], check=True)
        print(f'Published {repository["repositoryUri"]}:{tag}')
    print('Review ECR scan results before deployment. Model publishing is a separate step.')


if __name__ == '__main__':
    main()
