# codex-lb provider for OpenCode V2: rebuild guide

Self-contained instructions for reproducing the `codex-lb` model provider on
another computer. Verified against OpenCode `v2.2.5` on 2026-11-10.

The provider exposes the OpenAI Codex backend (Responses API) through the
`lb.llm.lumi.com.vn` gateway so the same three models available in Codex CLI are
selectable in OpenCode, with all reasoning-effort variants.

---

## 1. Source of truth

The settings below were derived from `~/.codex/config.toml` on the original
machine:

```toml
model = "gpt-6.1-sol"
model_provider = "codex-lb"
model_reasoning_effort = "high"

[model_providers.codex-lb]
name = "OpenAI"
base_url = "https://lb.llm.lumi.com.vn/backend-api/codex"
wire_api = "responses"
supports_websockets = true
requires_openai_auth = true   # required for codex app
```

Mapping to OpenCode V2:

| Codex field | OpenCode field | Value |
| --- | --- | --- |
| provider table name `codex-lb` | `providers.codex-lb` | same id, used as `codex-lb/<model>` |
| `name` | `name` | `OpenAI (codex-lb)` (display only) |
| `base_url` | `settings.baseURL` | `https://lb.llm.lumi.com.vn/backend-api/codex` |
| `wire_api = "responses"` | `package` | `@opencode/ai/providers/openai-compatible/responses` |
| `requires_openai_auth` | `env` / saved account | `CODEX_LB_API_KEY`, or `opencode auth login` |
| `model_reasoning_effort` | variant suffix `#high` | per session, see §7 |
| `supports_websockets` | (not set) | HTTP by default; opt in only if needed, see §9 |

Important: the package must be the `/responses` variant. The plain
`openai-compatible` package speaks Chat Completions (`/chat/completions`), which
this gateway does not serve. The Codex backend appends `/responses` to
`base_url`, so `baseURL` must end at `.../backend-api/codex` and must not include
`/v1`.

---

## 2. Prerequisites on the new machine

- OpenCode V2 (`opencode --version` should report `v2.x`). V1 config shapes are
  different; do not follow this guide for V1.
- Network access to `https://lb.llm.lumi.com.vn`.
- An API key for the gateway (obtain separately; never commit it).

Config location used by V2:

```text
~/.config/opencode/opencode.jsonc     # global, all projects
opencode.jsonc                        # optional per-project override
```

---

## 3. Merge the provider block

Edit `~/.config/opencode/opencode.jsonc` and merge the `providers` object below
into the existing top-level object. Do not replace unrelated keys.

If the file contains the deprecated V1 key `"provider": {}` (an empty object),
delete that line; V2 uses `"providers"`.

```jsonc
{
  "$schema": "https://opencode.ai/config.json",
  "providers": {
    "codex-lb": {
      "name": "OpenAI (codex-lb)",
      "env": ["CODEX_LB_API_KEY"],
      "package": "@opencode/ai/providers/openai-compatible/responses",
      "settings": {
        "baseURL": "https://lb.llm.lumi.com.vn/backend-api/codex",
      },
      "models": {
        "gpt-6.1-sol": {
          "name": "GPT-6.1 Sol",
          "family": "gpt-sol",
          "releaseDate": "2026-09-29",
          "limit": { "context": 1050000, "input": 922000, "output": 128000 },
          "capabilities": {
            "tools": true,
            "input": ["text", "image", "pdf"],
            "output": ["text"],
            "temperature": false,
            "reasoning": {
              "supported": true,
              "effort": ["low", "medium", "high", "xhigh", "max"],
            },
          },
          "cost": {
            "input": 2,
            "output": 10,
            "cache": { "read": 0.1, "write": 2.5 },
          },
        },
        "gpt-6-astra": {
          "name": "GPT-6 Astra",
          "family": "gpt-astra",
          "releaseDate": "2026-09-04",
          "limit": { "context": 1050000, "input": 922000, "output": 128000 },
          "capabilities": {
            "tools": true,
            "input": ["text", "image", "pdf"],
            "output": ["text"],
            "temperature": false,
            "reasoning": {
              "supported": true,
              "effort": ["low", "medium", "high", "xhigh", "max"],
            },
          },
          "cost": {
            "input": 10,
            "output": 50,
            "cache": { "read": 1, "write": 12.5 },
          },
        },
        "gpt-6-luna": {
          "name": "GPT-6 Luna",
          "family": "gpt-luna",
          "releaseDate": "2026-09-22",
          "limit": { "context": 1050000, "input": 922000, "output": 128000 },
          "capabilities": {
            "tools": true,
            "input": ["text", "image", "pdf"],
            "output": ["text"],
            "temperature": false,
            "reasoning": {
              "supported": true,
              "toggle": true,
              "effort": ["low", "medium", "high", "xhigh", "max"],
            },
          },
          "cost": {
            "input": 0.1,
            "output": 0.5,
            "cache": { "read": 0.01, "write": 0.125 },
          },
        },
      },
    },
  },
}
```

A fresh machine with no other OpenCode settings can use that file verbatim. An
existing config must keep its own `default_agent`, `permissions`, `mcp`,
`plugins`, and `instructions` keys.

JSONC allows trailing commas and comments; plain `opencode.json` does not.

---

## 4. Add the key

Pick exactly one method. A saved account wins over an environment connection for
the same integration.

### 4.1 Saved account (recommended)

```bash
opencode auth login codex-lb --method key
# paste the key at the prompt
opencode auth list        # should show codex-lb
```

Non-interactive:

```bash
opencode auth login codex-lb --method key --answer key=<API_KEY>
```

The TUI equivalent is `/connect` -> **OpenAI (codex-lb)**.

Storage: the server SQLite database, not the config file.

```bash
opencode debug paths db
# ~/.local/share/opencode/opencode.db
```

`opencode auth export` only prints stored credentials as JSON (including
secrets) for backup or migration; `opencode auth import` restores that JSON.
Neither command is a place to paste a single key.

Remove it later with:

```bash
opencode auth logout codex-lb
```

### 4.2 Environment variable

`"env": ["CODEX_LB_API_KEY"]` in the config declares the variable name only; the
value never enters the file.

```bash
export CODEX_LB_API_KEY=<API_KEY>
```

For the shared background service, persist it on the service instead:

```bash
opencode service set env CODEX_LB_API_KEY <API_KEY>
opencode service unset env CODEX_LB_API_KEY   # remove later
```

Keep the `env` line if either method is used. Remove the line only if the
provider should authenticate solely through a saved account.

---

## 5. Verify

```bash
opencode models | grep codex-lb
```

Expected:

```text
codex-lb/gpt-6.1-sol
codex-lb/gpt-6-astra
codex-lb/gpt-6-luna
```

Then a real request:

```bash
opencode run --model codex-lb/gpt-6.1-sol#high "Reply with OK"
```

Config changes reload automatically; a restart is unnecessary. If the provider
does not appear, check `~/.local/share/opencode/log/opencode.log`.

---

## 6. Provider and model field reference

Provider (`providers.codex-lb`):

| Field | Meaning |
| --- | --- |
| `name` | Display name in `/models` and `/connect`. |
| `env` | Ordered env var names that may supply the credential. |
| `package` | Runtime adapter. `@opencode/ai/providers/openai-compatible/responses` for the Codex Responses API. |
| `settings.baseURL` | Endpoint prefix; the adapter appends `/responses`. |
| `settings.apiKey` | Alternative to `env`: `"{env:CODEX_LB_API_KEY}"`. |
| `headers` | Extra HTTP headers for every request. |
| `body` | JSON merged into every request body. |
| `models` | Map of OpenCode model id -> model config. |

Model fields used here:

| Field | Meaning |
| --- | --- |
| `name` | Display name. |
| `family` | Grouping in the model picker. |
| `releaseDate` | `YYYY-MM-DD`, used for ordering. |
| `limit.context` / `limit.input` / `limit.output` | Token limits; overrides the 200k/32k fallback for unknown models. |
| `capabilities.tools` | Enables tool calling. |
| `capabilities.input` / `output` | Accepted media types. |
| `capabilities.temperature` | `false` prevents sending `temperature` (these models reject it). |
| `capabilities.reasoning.supported` | Marks the model as reasoning-capable. |
| `capabilities.reasoning.effort` | Effort levels; each becomes a selectable variant. |
| `capabilities.reasoning.toggle` | Adds a `none` variant that disables reasoning. |
| `cost.*` | USD per million tokens, used for spend estimates only. |

`modelID` is only needed when the OpenCode id differs from the id sent upstream;
here they are identical, so it is omitted.

---

## 7. Models and variants

| OpenCode id | Display | Context | Max output | Effort variants | Notes |
| --- | --- | --- | --- | --- | --- |
| `gpt-6.1-sol` | GPT-6.1 Sol | 1,050,000 | 128,000 | `low`, `medium`, `high`, `xhigh`, `max` | Default in Codex; near-Astra at lower cost |
| `gpt-6-astra` | GPT-6 Astra | 1,050,000 | 128,000 | `low`, `medium`, `high`, `xhigh`, `max` | Most capable |
| `gpt-6-luna` | GPT-6 Luna | 1,050,000 | 128,000 | `none`, `low`, `medium`, `high`, `xhigh`, `max` | Cheapest; `none` comes from `toggle` |

Select a variant with `#`:

```bash
opencode run --model codex-lb/gpt-6.1-sol#high "..."
opencode run --model codex-lb/gpt-6-luna#none "..."
```

Variants are per session, agent, or command. The root `model` field does not
retain a variant:

```jsonc
{ "model": "codex-lb/gpt-6.1-sol" }
```

To pin one for an agent, set the model with the variant on that agent:

```jsonc
{
  "agents": {
    "orchestrator": {
      "model": "codex-lb/gpt-6.1-sol#high"
    }
  }
}
```

Custom variants (for example a `deep` alias) can be added in the model's
`variants` array; their `settings`/`body` are applied after the provider and
model values:

```jsonc
"variants": [
  { "id": "deep", "settings": { "reasoningEffort": "max", "reasoningSummary": "auto" } }
]
```

---

## 8. Cost values used

USD per million tokens, from the OpenAI catalog entry for each model.

| Model | Input | Output | Cache read | Cache write |
| --- | --- | --- | --- | --- |
| `gpt-6.1-sol` | 2 | 10 | 0.1 | 2.5 |
| `gpt-6-astra` | 10 | 50 | 1 | 12.5 |
| `gpt-6-luna` | 0.1 | 0.5 | 0.01 | 0.125 |

If the gateway bills differently, edit or delete `cost`; it does not affect
requests.

---

## 9. Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| Models missing from `/models` | Provider not loaded: check JSONC syntax and that the key is `providers`, not `provider`. |
| `Cannot initialize provider/...` | `baseURL` contains an unresolved `${VAR}` placeholder. |
| 401 / 403 | No credential. Run `opencode auth login codex-lb --method key` or export `CODEX_LB_API_KEY`. |
| 404 on requests | Wrong package or baseURL. Use the `/responses` package and stop `baseURL` at `/backend-api/codex` (no `/v1`, no `/responses`). |
| Endpoint rejects stored responses | Add `"body": { "store": false }` at provider level. |
| Gateway wants the key inline | Add `"settings": { "apiKey": "{env:CODEX_LB_API_KEY}" }` instead of `env`. |
| Request fails only over WebSocket | Set `"settings": { "transport": "http" }`; WebSocket is opt-in and falls back on failure. |
| Model replies without reasoning | Use a `#<effort>` variant; without one the provider default applies. |
| Config seems stale | `/reload` in the TUI, or `opencode service restart` if the service is unhealthy. |

---

## 10. Moving this to another machine

Files to copy:

- `~/.config/opencode/opencode.jsonc` (provider block and any other settings)
- Optionally the credential export, if migrating accounts

```bash
# old machine
opencode auth export > codex-lb-auth.json     # contains secrets
# new machine
opencode auth import < codex-lb-auth.json
rm codex-lb-auth.json                         # delete the plaintext copy
```

Never commit the exported file, `.env` files, or the OpenCode database. The
config file itself is safe to commit because it contains only the env var name.

Minimal manual rebuild checklist:

1. Install OpenCode V2.
2. Merge the `providers` block from §3 into `~/.config/opencode/opencode.jsonc`.
3. Run `opencode auth login codex-lb --method key` and paste the key.
4. Run `opencode models | grep codex-lb` and confirm three models.
5. Run `opencode run --model codex-lb/gpt-6.1-sol#high "Reply with OK"`.

---

## References

- OpenCode V2 providers: <https://opencode.ai/v2/docs/providers>
- OpenCode V2 models and variants: <https://opencode.ai/v2/docs/models>
- OpenCode V2 provider accounts: <https://opencode.ai/v2/docs/cli/providers>
- Model catalog metadata: <https://models.dev>
- Codex CLI config reference: <https://github.com/openai/codex>
