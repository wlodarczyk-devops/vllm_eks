#!/usr/bin/env python3
"""Open a PR changing only models/release.json. This job does not need AWS access."""
import argparse
import base64
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
from urllib.parse import urlencode


def api(method, endpoint, body=None):
    command = ['gh', 'api', '--method', method, endpoint]
    if body is not None:
        command += ['--input', '-']
    result = subprocess.check_output(command, input=None if body is None else json.dumps(body), text=True)
    return json.loads(result)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--release', type=Path, required=True)
    options = parser.parse_args()
    release = json.loads(options.release.read_text())
    if not re.fullmatch(r'[0-9a-f]{40}', release.get('model_revision', '')):
        parser.error('Artifact must contain an upstream commit')
    if not re.fullmatch(r'[0-9a-f]{64}', release.get('sha256') or ''):
        parser.error('Artifact must contain a SHA-256 checksum')
    if not isinstance(release.get('version_id'), str) or release['version_id'] in ('', 'null'):
        parser.error('Artifact must contain a non-null S3 version ID')
    if not re.fullmatch(r'models/[A-Za-z0-9._/-]+/model\.tar\.gz', release.get('key', '')) or '..' in release['key'].split('/'):
        parser.error('Artifact must use a safe model key')
    repository = os.environ['GITHUB_REPOSITORY']
    run_id = os.environ['GITHUB_RUN_ID']
    attempt = os.environ['GITHUB_RUN_ATTEMPT']
    branch = f'model-release/{run_id}-{attempt}'
    prefix = f'repos/{repository}'
    base = api('GET', f'{prefix}/git/ref/heads/main')['object']['sha']
    selected = api('GET', f'{prefix}/contents/models/release.json?{urlencode({"ref": base})}')
    if release['model_id'] != json.loads(base64.b64decode(selected['content']))['model_id']:
        parser.error('Workflow publishes revisions of the reviewed model; changing model identity needs a code review first')
    api('POST', f'{prefix}/git/refs', {'ref': f'refs/heads/{branch}', 'sha': base})
    # Fetch the blob at the branch's pinned base, avoiding a moving-main race.
    current = api('GET', f'{prefix}/contents/models/release.json?{urlencode({"ref": branch})}')
    content = json.dumps(release, indent=2) + '\n'
    api('PUT', f'{prefix}/contents/models/release.json', {
        'message': f'Publish model revision {release["model_revision"][:12]}',
        'content': base64.b64encode(content.encode()).decode(),
        'sha': current['sha'], 'branch': branch,
    })
    body = f'''## Summary

Select the published model revision `{release['model_revision']}`.

```text
S3 archive version → checksum-verified init download → vLLM
```

## Evidence

- The publisher uploaded `{release['key']}` and recorded a non-null S3 version ID.
- Archive SHA-256: `{release['sha256']}`.
- This PR changes only the model release metadata. Live GPU inference remains to be verified.

## Merge Danger

**Door:** Two-way

Restore the previous release file to select an older retained model version.

**Blast Radius:** Serving

Merge selects a release for the next deployment; the publishing workflow does not deploy or auto-merge.
Review artifact provenance, capacity and rollout requirements before deploying.
'''
    with tempfile.TemporaryDirectory() as directory:
        path = Path(directory) / 'pr.md'
        path.write_text(body)
        result = subprocess.check_output(['gh', 'pr', 'create', '--repo', repository,
            '--base', 'main', '--head', branch, '--title', f'Publish model revision {release["model_revision"][:12]}',
            '--body-file', str(path)], text=True)
    print(result.strip())
    with Path(os.environ['GITHUB_STEP_SUMMARY']).open('a') as summary:
        summary.write(f'Model release PR: {result.strip()}\n')


if __name__ == '__main__':
    main()
