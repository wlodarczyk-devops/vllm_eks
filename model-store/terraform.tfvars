region         = "eu-central-1"
cluster_name   = "vllm-eks"
vpc_state_path = "../vpc/terraform.tfstate"
active_release = "qwen3-4b-2507"

releases = {
  qwen3-4b-2507 = {
    model_id  = "Qwen/Qwen3-4B-Instruct-2507"
    revision  = "cdbee75f17c01a7cc42f958dc650907174af0554"
    directory = "artifacts/qwen3-4b-2507"
  }
}

tags = {
  Project   = "vllm-eks"
  ManagedBy = "terraform"
}
