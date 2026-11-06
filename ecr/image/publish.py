#!/usr/bin/env python3
"""Explicit build/push step; requires AWS CLI, Docker Buildx and publisher credentials.

No Terraform commands. AWS passwords are passed to Docker over stdin, never argv.
"""
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
    if not re.fullmatch(r'[0-9a-f]{40}', release['model_revision']):
        parser.error('Model revision must be a full commit hash')
    if not re.search(r'@sha256:[0-9a-f]{64}$', release['base_image']):
        parser.error('Base image must include an immutable SHA-256 digest')
    tag = release['image_tag']
    if tag == 'latest' or not re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}', tag):
        parser.error('Use a descriptive versioned image_tag')

    aws = ['aws', '--region', options.region, '--no-cli-pager', 'ecr']
    response = subprocess.check_output(aws + ['describe-repositories', '--repository-names', options.repository, '--output', 'json'], text=True)
    repository = json.loads(response)['repositories'][0]
    if repository['imageTagMutability'] != 'IMMUTABLE':
        parser.error('The target repository must use immutable tags')
    existing = subprocess.run(aws + ['describe-images', '--repository-name', options.repository,
                                    '--image-ids', f'imageTag={tag}', '--output', 'json'], capture_output=True, text=True)
    if existing.returncode == 0:
        parser.error('This release tag already exists. Deploy it or choose a NEW image_tag before building')
    if 'ImageNotFoundException' not in existing.stderr:
        raise RuntimeError(f'Cannot check release tag: {existing.stderr.strip()}')

    image = f"{repository['repositoryUri']}:{tag}"
    registry = repository['repositoryUri'].split('/', 1)[0]
    password = subprocess.check_output(aws + ['get-login-password'])
    subprocess.run(['docker', 'login', '--username', 'AWS', '--password-stdin', registry], input=password, check=True)
    del password
    # Existing GPU nodes are x86_64, including when the publisher is an Apple Silicon Mac.
    subprocess.run([
        'docker', 'buildx', 'build', '--platform', 'linux/amd64',
        '--file', str(IMAGE_DIRECTORY / 'Dockerfile'),
        '--build-arg', f"VLLM_BASE_IMAGE={release['base_image']}",
        '--build-arg', f"MODEL_ID={release['model_id']}",
        '--build-arg', f"MODEL_REVISION={release['model_revision']}",
        '--tag', image, '--push', str(IMAGE_DIRECTORY),
    ], check=True)
    response = subprocess.check_output(aws + ['describe-images', '--repository-name', options.repository,
                                            '--image-ids', f'imageTag={tag}', '--output', 'json'], text=True)
    digest = json.loads(response)['imageDetails'][0]['imageDigest']
    print(f"Published {repository['repositoryUri']}@{digest}")
    print('Review the ECR scan results before deploying the vLLM stack.')


if __name__ == '__main__':
    main()
