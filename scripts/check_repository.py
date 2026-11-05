#!/usr/bin/env python3
"""Offline syntax and policy-contract checks. Does not run Terraform or contact AWS."""
from pathlib import Path
import ipaddress
import re
import unittest

import hcl2
import yaml

ROOT = Path(__file__).resolve().parents[1]
STACKS = ("vpc", "eks", "vllm", "llm-d")


def load_hcl(path):
    with path.open() as stream:
        return hcl2.load(stream)


def resources(stack, resource_type):
    result = {}
    for path in (ROOT / stack).glob("*.tf"):
        for resource in load_hcl(path).get("resource", []):
            result.update(resource.get(resource_type, {}))
    return result


class RepositoryContracts(unittest.TestCase):
    def test_configuration_parses(self):
        for stack in STACKS:
            for path in (ROOT / stack).iterdir():
                if path.suffix in (".tf", ".tfvars"):
                    with self.subTest(path=path.relative_to(ROOT)):
                        load_hcl(path)
        for path in (ROOT / "examples").rglob("*.example"):
            with self.subTest(path=path.relative_to(ROOT)):
                load_hcl(path)
        for parent in (ROOT / "monitoring", ROOT / "llm-d/values", ROOT / ".github"):
            for path in parent.rglob("*"):
                if path.suffix in (".yaml", ".yml"):
                    with self.subTest(path=path.relative_to(ROOT)):
                        list(yaml.safe_load_all(path.read_text()))

    def test_namespace_starts_with_default_deny(self):
        spec = resources("vllm", "kubernetes_network_policy_v1")["default_deny"]["spec"][0]
        self.assertEqual(spec["pod_selector"], [{}])
        self.assertEqual(set(spec["policy_types"]), {"Ingress", "Egress"})
        self.assertNotIn("ingress", spec)
        self.assertNotIn("egress", spec)

    def test_download_egress_excludes_private_and_metadata_addresses(self):
        policy = resources("vllm", "kubernetes_network_policy_v1")["vllm"]["spec"][0]
        rule = policy["egress"][0]
        excluded = [ipaddress.ip_network(c) for c in rule["to"][0]["ip_block"][0]["except"]]
        for address in ("10.0.1.1", "172.20.0.1", "192.168.1.1", "169.254.169.254", "127.0.0.1"):
            self.assertTrue(any(ipaddress.ip_address(address) in network for network in excluded), address)
        self.assertEqual(rule["ports"], [{"port": "443", "protocol": "TCP"}])

    def test_gateway_clients_require_namespace_and_pod_identity(self):
        policy = resources("vllm", "kubernetes_network_policy_v1")["gateway"]["spec"][0]
        peers = policy["ingress"][0]["from"]
        self.assertEqual(len(peers), 1, "Separate peers would OR namespace and pod selectors")
        self.assertIn("namespace_selector", peers[0])
        self.assertIn("pod_selector", peers[0])
        self.assertEqual(policy["ingress"][0]["ports"][0]["port"], "8443")

    def test_router_ingress_only_accepts_gateway(self):
        policy = resources("llm-d", "kubernetes_network_policy_v1")["router"]["spec"][0]
        self.assertEqual(policy["ingress"][0]["from"], [{"pod_selector": [{"match_labels": {"app": "inference-gateway"}}]}])
        self.assertEqual(policy["ingress"][0]["ports"][0]["port"], "8081")

    def test_no_terraform_managed_authentication_secret(self):
        for stack in STACKS:
            self.assertFalse(resources(stack, "kubernetes_secret_v1"))
            self.assertFalse(resources(stack, "kubernetes_secret"))

    def test_gateway_exposes_only_reviewed_api_routes(self):
        config = (ROOT / "vllm/templates/gateway.conf.tftpl").read_text()
        routes = set(re.findall(r"location = (/v1/[^ ]+)", config))
        self.assertEqual(routes, {"/v1/models", "/v1/chat/completions", "/v1/completions"})
        self.assertIn('location / { return 404; }', config)
        self.assertIn('proxy_set_header Authorization "";', config)
        self.assertIn('proxy_next_upstream off;', config, "Do not replay inference POSTs")

    def test_ci_actions_are_immutable(self):
        for path in (ROOT / ".github/workflows").glob("*.yml"):
            for action in re.findall(r"uses:\s*([^\s]+)", path.read_text()):
                self.assertRegex(action, r"@[a-f0-9]{40}$", str(path))


if __name__ == "__main__":
    unittest.main(verbosity=2)
