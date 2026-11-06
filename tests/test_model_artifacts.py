"""Small synthetic artifacts exercise integrity checks without AWS or model downloads."""
import json
from pathlib import Path
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'model-store'))
from manifest import build_manifest, sha256_file, verify


class ModelArtifactTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.files = self.root / 'files'
        self.files.mkdir()
        for name, content in {'config.json': '{}', 'tokenizer_config.json': '{}',
                              'tokenizer.json': '{}', 'weights.safetensors': 'synthetic weights'}.items():
            (self.files / name).write_text(content)
        self.model_id = 'Qwen/Qwen3-4B-Instruct-2507'
        self.revision = 'a' * 40
        self.manifest = build_manifest(self.files, self.model_id, self.revision)
        self.path = self.root / 'manifest.json'
        self.save()

    def save(self):
        self.path.write_text(json.dumps(self.manifest, sort_keys=True) + '\n')
        self.digest = sha256_file(self.path)

    def test_complete_release_verifies_deterministically(self):
        self.assertEqual(self.manifest, build_manifest(self.files, self.model_id, self.revision))
        self.assertEqual(verify(self.files, self.path, self.digest)['model_id'], self.model_id)

    def test_corrupted_weights_are_rejected(self):
        (self.files / 'weights.safetensors').write_text('tampered weights!')
        with self.assertRaisesRegex(ValueError, 'checksum/size mismatch'):
            verify(self.files, self.path, self.digest)

    def test_replaced_manifest_is_rejected(self):
        self.path.write_text('{}')
        with self.assertRaisesRegex(ValueError, 'manifest checksum'):
            verify(self.files, self.path, self.digest)

    def test_unexpected_files_are_rejected(self):
        (self.files / 'injected.py').write_text('untrusted')
        with self.assertRaisesRegex(ValueError, 'inventory differs'):
            verify(self.files, self.path, self.digest)

    def test_traversal_and_absolute_paths_are_rejected(self):
        for path in ('../outside', '/etc/passwd', 'a/../../outside', 'a\\outside'):
            with self.subTest(path=path):
                self.manifest['files'][0]['path'] = path
                self.save()
                with self.assertRaisesRegex(ValueError, 'Unsafe manifest path'):
                    verify(self.files, self.path, self.digest)

    def test_symlinked_files_are_rejected(self):
        file = self.files / 'weights.safetensors'
        file.unlink()
        file.symlink_to(self.path)
        with self.assertRaisesRegex(ValueError, 'symlinked'):
            verify(self.files, self.path, self.digest)

    def test_duplicate_entries_are_rejected(self):
        self.manifest['files'].append(self.manifest['files'][0].copy())
        self.save()
        with self.assertRaisesRegex(ValueError, 'Duplicate'):
            verify(self.files, self.path, self.digest)

    def test_missing_shards_fail_before_publishing(self):
        (self.files / 'model.safetensors.index.json').write_text(json.dumps({'weight_map': {'layer': 'missing.safetensors'}}))
        with self.assertRaisesRegex(ValueError, 'Missing weight shards'):
            build_manifest(self.files, self.model_id, self.revision)

    def test_unpinned_revision_is_rejected(self):
        with self.assertRaisesRegex(ValueError, 'full Hugging Face commit'):
            build_manifest(self.files, self.model_id, 'main')


if __name__ == '__main__':
    unittest.main()
