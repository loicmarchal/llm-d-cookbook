# llm-d Cookbook

Guides, scripts, and documentation for deploying, configuring, and testing model serving with [llm-d](https://github.com/llm-d).

## What's in this repo

This repository is a collection of practical resources for working with llm-d clusters. It covers deployment workflows, feature validation, and operational recipes that go beyond the core project documentation.

### Scripts

Test and validation scripts for llm-d features.

| Script | Description |
|--------|-------------|
| [test-priority-holdback.sh](scripts/test-priority-holdback.sh) | Validates the priority holdback flow control feature against a live cluster. Creates InferenceObjectives at different priorities, drives load, and verifies that lower-priority traffic is gated before higher-priority traffic. |

## Prerequisites

- `kubectl` configured and pointing at a Kubernetes cluster with llm-d installed
- `curl` and `jq` for HTTP and JSON operations
- A running llm-d deployment (EPP, gateway, model servers)

## Getting Started

Clone the repo:

```bash
git clone https://github.com/llm-d/llm-d-cookbook.git
cd llm-d-cookbook
```

Run a script:

```bash
./scripts/test-priority-holdback.sh <NAMESPACE> [GATEWAY_URL] [METRICS_URL] [INFERENCE_POOL]
```

## Contributing

Contributions are welcome. Each addition should be self-contained with clear prerequisites and usage instructions.
