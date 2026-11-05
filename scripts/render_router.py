#!/usr/bin/env python3
"""Render the actual pinned chart with repository values, then check pod contracts.

Usage: python scripts/render_router.py PATH_TO_DOWNLOADED_CHART
This resolves only the simple variable/local references used in local.overrides;
it is not a Terraform evaluator or provider-schema validation.
"""
from pathlib import Path
import copy
import re
import subprocess
import sys
import tempfile

import hcl2
import yaml

ROOT = Path(__file__).resolve().parents[1]


def read_hcl(path):
    with path.open() as stream:
        return hcl2.load(stream)


def main(chart):
    variables = read_hcl(ROOT / "llm-d/terraform.tfvars")
    variables["router_replicas"] = 2  # Exercise HA, not only the one-replica lab.
    variables["release_name"] = "review-router"  # Detect hard-coded policy selectors.
    local_values = read_hcl(ROOT / "llm-d/main.tf")["locals"][0]

    def resolve(value):
        if isinstance(value, dict):
            return {k: resolve(v) for k, v in value.items()}
        if isinstance(value, list):
            return [resolve(v) for v in value]
        if not isinstance(value, str):
            return value

        def expression(text):
            if text.startswith("var."):
                return variables[text[4:]]
            if text.startswith("local."):
                return resolve(local_values[text[6:]])
            if text.startswith("tostring(") and text.endswith(")"):
                return str(expression(text[9:-1]))
            raise ValueError(f"Unsupported expression; extend the renderer deliberately: {text}")

        match = re.fullmatch(r"\$\{([^{}]+)\}", value)
        if match:
            return expression(match.group(1))
        return re.sub(r"\$\{([^{}]+)\}", lambda m: str(expression(m.group(1))), value)

    baseline = yaml.safe_load((ROOT / "llm-d/values/optimized-baseline.values.yaml").read_text())
    baseline["router"]["modelServers"].pop("matchLabels", None)
    overrides = resolve(copy.deepcopy(local_values["overrides"]))
    with tempfile.TemporaryDirectory() as directory:
        files = [ROOT / "llm-d/values/base.values.yaml"]
        for name, values in (("baseline", baseline), ("overrides", overrides)):
            path = Path(directory) / f"{name}.yaml"
            path.write_text(yaml.safe_dump(values))
            files.append(path)
        command = ["helm", "template", variables["release_name"], str(chart), "--namespace", variables["namespace"], "--kube-version", "1.37.0"]
        for path in files:
            command += ["--values", str(path)]
        rendered = subprocess.check_output(command, text=True)
    docs = [doc for doc in yaml.safe_load_all(rendered) if doc]
    deployment = next(doc for doc in docs if doc["kind"] == "Deployment")
    pod = deployment["spec"]["template"]
    expected = {"llm-d-router-gateway": "review-router-epp"}
    assert all(pod["metadata"]["labels"].get(k) == v for k, v in expected.items()), pod["metadata"]
    assert deployment["spec"]["replicas"] == 2
    assert deployment["spec"]["strategy"]["rollingUpdate"]["maxUnavailable"] == 0
    assert pod["spec"]["securityContext"]["runAsNonRoot"]
    for container in pod["spec"]["containers"]:
        security = container["securityContext"]
        assert security["readOnlyRootFilesystem"]
        assert security["allowPrivilegeEscalation"] is False
        assert security["capabilities"]["drop"] == ["ALL"]
    epp = next(c for c in pod["spec"]["containers"] if c["name"] == "epp")
    assert "--ha-enable-leader-election=false" in epp["args"], epp["args"]
    assert not any(env["name"].startswith("OTEL_") for env in epp.get("env", []))
    pool = next(doc for doc in docs if doc["kind"] == "InferencePool")
    assert pool["spec"]["selector"]["matchLabels"] == variables["model_server_labels"]
    print(f"Rendered {len(docs)} resources; HA, selectors, security contexts and tracing checks passed")


if __name__ == "__main__":
    main(Path(sys.argv[1]))
