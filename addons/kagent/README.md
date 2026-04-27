# SPDX-FileCopyrightText: © 2026 Siemens Healthineers AG
#
# SPDX-License-Identifier: MIT

# Kagent Addon

## What is Kagent?

[Kagent](https://github.com/kagent-dev/kagent) is a Kubernetes-native framework for building AI agents.
It is a [CNCF](https://www.cncf.io/) project that makes it easy to build, deploy, and manage AI agents in Kubernetes.

Kagent provides:
- **Agents** as Kubernetes custom resources (CRDs)
- **Multi-provider LLM support** (OpenAI, Anthropic, Ollama)
- **MCP tool servers** for Kubernetes, Helm, Prometheus, and more
- **Web UI** for managing agents and tools
- **OpenTelemetry tracing** for observability

## Enable

Enable the kagent addon **without a built-in LLM provider** (for BYO agents or MCP clients only):

```console
k2s addons enable kagent
```

Enable with an OpenAI API key:

```console
k2s addons enable kagent --provider openAI --api-key <your-openai-key>
```

Enable with Anthropic:

```console
k2s addons enable kagent --provider anthropic --api-key <your-anthropic-key>
```

Enable with a local Ollama instance (no API key required):

```console
k2s addons enable kagent --provider ollama
```

Enable with **Copilot CLI as a BYO agent** (auto-deployed into Kagent):

```console
kubectl create secret generic copilot-github-token -n kagent \
  --from-literal=GITHUB_TOKEN=<your-fine-grained-pat>
k2s addons enable kagent --byo-copilot
```

> **Tip:** Use `--provider none` (the default) when you only plan to use BYO agents
> or connect MCP clients like Copilot CLI. No API key is needed in this mode.
>
> The `--byo-copilot` flag can be combined with any provider, e.g.:
> ```console
> k2s addons enable kagent --provider openAI --api-key <key> --byo-copilot
> ```

## Disable

```console
k2s addons disable kagent
```

> **Note:** Disabling kagent removes the main workloads but leaves the CRDs in place
> to avoid deleting all kagent custom resources. To fully remove CRDs:
> `helm uninstall kagent-crds -n kagent`

## Accessing the Kagent UI

After enabling, use port-forwarding to access the Kagent web UI:

```console
kubectl port-forward svc/kagent-ui -n kagent 8080:8080
```

Then open [http://localhost:8080](http://localhost:8080) in your browser.

## Using Kagent Agents from MCP Clients (e.g., Copilot CLI, Cursor, Claude Code)

Kagent exposes all running agents via a **Model Context Protocol (MCP)** server.
Any MCP-compatible client — such as GitHub Copilot CLI, Cursor, or Claude Code — can discover
and invoke Kagent agents as tools.

### Step 1: Port-forward the Kagent controller

```console
kubectl port-forward svc/kagent-controller -n kagent 8083:8083
```

The MCP endpoint is available at `http://localhost:8083/mcp` (Streamable HTTP transport).

### Step 2: Configure your MCP client

**GitHub Copilot CLI:**

Add the Kagent MCP server to your Copilot CLI configuration (e.g., in `.github/copilot/mcp.json`):

```json
{
  "mcpServers": {
    "kagent-agents": {
      "type": "http",
      "url": "http://localhost:8083/mcp"
    }
  }
}
```

**Cursor:**

Add to your Cursor MCP settings:

```json
{
  "mcpServers": {
    "kagent-agents": {
      "url": "http://localhost:8083/mcp"
    }
  }
}
```

**Claude Code:**

```console
claude mcp add --transport http kagent http://localhost:8083/mcp
```

### Available MCP tools

The MCP server exposes two tools:

- `list_agents` — lists all available Kagent agents
- `invoke_agent` — runs a specific agent by name with a given input (supports `sessionID` for conversation continuity)

This allows your MCP client to discover and orchestrate Kagent agents as sub-agents,
delegating specialized Kubernetes tasks securely.

> **Note:** SSE (Server-Sent Events) is currently not supported. Use Streamable HTTP transport.

## Bring Your Own (BYO) Agent

You can run any custom agent as a container image in Kagent. BYO agents give you full control
over the agent logic — Kagent manages the lifecycle and invokes them via the **A2A protocol**.

This is useful for integrating existing agents (e.g., a custom Copilot CLI wrapper, a CrewAI
agent, or any other framework) into the Kagent ecosystem.

### Step 1: Package your agent as a container image

Build a container image with your agent logic. The agent must implement the
[A2A protocol](https://a2a.guide/protocol/agent-card.html) for communication with Kagent.

### Step 2: Create a BYO Agent resource

```yaml
apiVersion: kagent.dev/v1alpha2
kind: Agent
metadata:
  name: my-custom-agent
  namespace: kagent
spec:
  description: My custom agent
  type: BYO
  byo:
    deployment:
      image: my-registry/my-agent:latest
      env:
        - name: MY_API_KEY
          valueFrom:
            secretKeyRef:
              name: my-agent-secret
              key: API_KEY
```

Apply it:

```console
kubectl apply -f my-agent.yaml
```

### Step 3: Invoke the agent

Use the Kagent UI, the kagent CLI, or any A2A/MCP client:

```console
kagent invoke --agent my-custom-agent --task "Do something useful"
```

For more details, see the [BYO Agent documentation](https://kagent.dev/docs/kagent/examples/a2a-byo).

## Copilot CLI as a BYO Agent (Auto-deploy)

The `--byo-copilot` flag automatically deploys a pre-built A2A wrapper image
(`shsk2s.azurecr.io/copilot-cli-a2a-wrapper`) that runs GitHub Copilot CLI
as a BYO agent inside Kagent. Kagent manages the pod lifecycle.

### Prerequisites

- **Fine-grained GitHub PAT** with the **"Copilot Requests"** permission.
- Your GitHub organization must have **Copilot enabled** for the user.
- The wrapper image (`shsk2s.azurecr.io/copilot-cli-a2a-wrapper:1.0.0`) must
  be accessible from the cluster. Build and push it from the
  `k2sServices/copilot-cli-a2a-wrapper` directory.

#### Creating the GitHub PAT

A fine-grained Personal Access Token (PAT) is required to authenticate the
Copilot CLI running inside the cluster. Existing credentials (e.g., in
Windows Credential Manager or `~/.gitconfig`) cannot be reused — you must
generate a dedicated PAT with the correct permission scope.

1. Go to https://github.com/settings/personal-access-tokens/new
2. Set a descriptive name (e.g., **"K2s Copilot CLI Agent"**)
3. Choose an expiration period
4. Under **Permissions**, click **"Add permissions"** and enable
   **"Copilot Requests"**
5. Click **Generate token**
6. Copy the token (starts with `github_pat_...`)

Then store it as a Kubernetes Secret:

```console
kubectl create namespace kagent          # if not already present
kubectl create secret generic copilot-github-token -n kagent \
  --from-literal=GITHUB_TOKEN=github_pat_xxxxx
```

> **Note:** The PAT is stored securely in the cluster as a Kubernetes Secret.
> It is never passed via CLI arguments or shell history.

### Enable

Once the secret exists, enable the addon:

```console
k2s addons enable kagent --byo-copilot
```

This will:
1. Install the Kagent framework (CRDs, controller, UI)
2. Validate that the Secret `copilot-github-token` exists in namespace `kagent`
3. Apply the `Agent` CR (`copilot-cli`, type: BYO) — Kagent starts the wrapper pod

### What happens under the hood

The Agent CR in `manifests/copilot-cli-agent.yaml` tells Kagent to deploy the
wrapper container. The wrapper:
- Exposes an **A2A** endpoint on port 9999
- Receives tasks from Kagent
- Invokes `copilot --prompt <task> --allow-all --allow-all-paths`
- Returns the Copilot CLI output as an A2A text artifact

### Verify

```console
kubectl -n kagent get agents
kubectl -n kagent get pods -l kagent.dev/agent-name=copilot-cli
```

### Disable

When you disable the kagent addon, the Copilot CLI BYO agent is automatically
removed along with its secret:

```console
k2s addons disable kagent
```

## More Information

- [Kagent Documentation](https://kagent.dev/docs/kagent/getting-started/quickstart)
- [Kagent GitHub Repository](https://github.com/kagent-dev/kagent)
- [Using Kagent Agents via MCP](https://kagent.dev/docs/kagent/examples/agents-mcp)
- [Bring Your Own Agent (A2A)](https://kagent.dev/docs/kagent/examples/a2a-byo)
