"""Verify credential isolation and permission boundaries in the declared pod/IAM."""
from pathlib import Path
import unittest

import hcl2

ROOT = Path(__file__).resolve().parents[1]


def load(path):
    with (ROOT / path).open() as stream:
        return hcl2.load(stream)


def resource(document, kind, name):
    return next(block[kind][name] for block in document['resource'] if name in block.get(kind, {}))


class ModelStorageConfigTests(unittest.TestCase):
    def test_stack_syntax(self):
        for stack in ('vpc', 'model-store', 'vllm'):
            for file in (ROOT / stack).glob('*.tf*'):
                if file.suffix in ('.tf', '.tfvars'):
                    with self.subTest(file=file):
                        load(file)

    def test_only_downloader_mounts_aws_identity(self):
        deployment = resource(load('vllm/main.tf'), 'kubernetes_deployment_v1', 'vllm')
        pod = deployment['spec'][0]['template'][0]['spec'][0]
        self.assertFalse(pod['automount_service_account_token'])
        consumers = []
        for container in pod['init_container'] + pod['container']:
            mounts = {mount['name']: mount for mount in container.get('volume_mount', [])}
            if 'model-identity' in mounts:
                consumers.append(container['name'])
            if container['name'] != 'download-model':
                self.assertFalse(any(env['name'] in ('AWS_ROLE_ARN', 'AWS_WEB_IDENTITY_TOKEN_FILE') for env in container.get('env', [])))
                self.assertTrue(mounts['model']['read_only'])
        self.assertEqual(consumers, ['download-model'])
        identity = next(volume for volume in pod['volume'] if volume['name'] == 'model-identity')
        token = identity['projected'][0]['sources'][0]['service_account_token'][0]
        self.assertEqual(token['audience'], 'sts.amazonaws.com')

    def test_runtime_policy_is_read_only_and_endpoint_scoped(self):
        document = load('vllm/model-storage.tf')
        policy = next(block['aws_iam_policy_document']['model_reader'] for block in document['data'] if 'model_reader' in block.get('aws_iam_policy_document', {}))
        self.assertEqual({action for statement in policy['statement'] for action in statement['actions']}, {'s3:GetObject', 's3:ListBucket'})
        for statement in policy['statement']:
            self.assertTrue(any(condition['variable'] == 'aws:SourceVpce' for condition in statement['condition']))
            self.assertNotIn('*', statement['resources'])
        account = resource(document, 'kubernetes_service_account_v1', 'model_reader')
        self.assertFalse(account['automount_service_account_token'])
        self.assertNotIn('annotations', account['metadata'][0])

    def test_trust_requires_service_account_and_sts_audience(self):
        document = load('vllm/model-storage.tf')
        trust = next(block['aws_iam_policy_document']['model_reader_trust'] for block in document['data'] if 'model_reader_trust' in block.get('aws_iam_policy_document', {}))
        statement = trust['statement'][0]
        self.assertEqual(statement['actions'], ['sts:AssumeRoleWithWebIdentity'])
        self.assertEqual(statement['principals'][0]['type'], 'Federated')
        conditions = statement['condition']
        self.assertEqual(len(conditions), 2)
        self.assertTrue(all(condition['test'] == 'StringEquals' for condition in conditions))
        self.assertTrue(any(condition['values'] == ['sts.amazonaws.com'] for condition in conditions))
        self.assertTrue(any('system:serviceaccount:' in condition['values'][0] for condition in conditions))

    def test_selected_model_is_local_and_offline(self):
        document = load('vllm/main.tf')
        deployment = resource(document, 'kubernetes_deployment_v1', 'vllm')
        container = deployment['spec'][0]['template'][0]['spec'][0]['container'][0]
        self.assertIn('--served-model-name', container['args'])
        environment = {entry['name']: entry.get('value') for entry in container['env']}
        self.assertEqual(environment['HF_HUB_OFFLINE'], '1')
        self.assertEqual(environment['TRANSFORMERS_OFFLINE'], '1')
        self.assertEqual(document['locals'][0]['serve_env']['SERVE_MODEL'], '/models/model')


if __name__ == '__main__':
    unittest.main()
