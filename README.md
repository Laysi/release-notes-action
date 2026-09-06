# release-notes-action

This GitHub Action reads the commits a tag added and turns them into grouped release notes. It sends the list to any endpoint that speaks the OpenAI chat/completions format, so you can use a hosted provider, a compatible gateway, or a local server.

You give it a tag. It works out the previous tag, filters the commits, calls the model, and writes a Markdown file. Your workflow is one step.

The action does not fail the caller's job when the model is not configured, the request fails, or the model returns no usable explanation. In those cases, the output file contains the plain commit list and `failed` is `1`. This matters when the repository's release page is the distribution channel: plain commit subjects are better than publishing no release at all.

## Usage

Check out the full history and tags, then call the action with the tag you are releasing.

```yaml
on:
  push:
    tags: ["v*"]

jobs:
  release:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
        with:
          fetch-depth: 0

      - id: notes
        uses: Laysi/release-notes-action@v1
        with:
          tag: ${{ github.ref_name }}
          context: This project is a financial and human resources system. The readers are the people who install and operate it.
          base-url: ${{ vars.AI_BASE_URL }}
          model: ${{ vars.AI_MODEL }}
          api-key: ${{ secrets.AI_API_KEY }}

      - env:
          GH_TOKEN: ${{ github.token }}
        run: gh release create "$GITHUB_REF_NAME" --notes-file "${{ steps.notes.outputs.file }}"
```

`fetch-depth: 0` is required. A shallow clone has neither the tag nor the commits, and the action fails rather than publishing empty notes.

## Inputs

| Name | Required | Default | Description |
| --- | --- | --- | --- |
| `tag` | Yes | — | The tag being released. |
| `tag-pattern` | No | `*` | Which tags count as previous versions. A repository that ships two things from one history has two tag prefixes, and the wrong one gives the wrong range. |
| `previous-tag` | No | `""` | Set this to skip the lookup above. |
| `exclude-paths` | No | `""` | Paths to leave out, comma or newline separated. |
| `exclude-types` | No | `ci,chore` | Conventional-commit types to drop, comma separated. Set to an empty string to keep everything. |
| `limit` | No | `40` | The most commits to send. |
| `context` | No | `""` | What the project is and who reads the notes. This is placed before the writing rules in the request. |
| `base-url` | No | `""` | The OpenAI-format endpoint URL up to, but not including, `/chat/completions`. An empty value falls back to `AI_BASE_URL`, then `https://api.openai.com/v1`. |
| `model` | No | `""` | The model identifier. An empty value falls back to `AI_MODEL`; if both are empty, no request is made. |
| `api-key` | No | `""` | The key for the endpoint, sent as a bearer token. An empty value falls back to `AI_API_KEY`. |
| `extra-headers` | No | `""` | Additional request headers, one `Name: value` per line. |

## Outputs

| Name | Description |
| --- | --- |
| `file` | The path to the generated Markdown file. If the model fails, it holds the commit list instead. |
| `failed` | `1` when the model did not write the release notes; otherwise `0`. |
| `previous-tag` | The previous tag that was found, or empty for a first release. |
| `range` | The commit range that was read. |

Read `failed` when you would rather stop than publish a plain commit list:

```yaml
- if: steps.notes.outputs.failed == '1'
  run: exit 1
```

## Endpoint examples

Set `base-url` to the endpoint up to `/chat/completions` and set `api-key` to the key expected by that endpoint.

```text
# OpenAI
https://api.openai.com/v1

# NVIDIA build
https://integrate.api.nvidia.com/v1

# Groq
https://api.groq.com/openai/v1

# OpenRouter
https://openrouter.ai/api/v1

# Gemini OpenAI compatibility
https://generativelanguage.googleapis.com/v1beta/openai

# Local Ollama
http://127.0.0.1:11434/v1
```

Cloudflare AI Gateway supports both of these forms:

```text
# Cloudflare AI Gateway through the Cloudflare API
https://api.cloudflare.com/client/v4/accounts/{account_id}/ai/v1

# Cloudflare AI Gateway compatibility endpoint
https://gateway.ai.cloudflare.com/v1/{account_id}/{gateway_id}/compat
```

For the first form, use a Cloudflare API token as `api-key`. For the second form, use the provider's own key as `api-key`, and write `model` as `provider/model`, for example `openai/gpt-5-mini` or `anthropic/claude-sonnet-4-5`. If the gateway itself requires authentication, pass its credential in `extra-headers`:

```yaml
extra-headers: cf-aig-authorization: Bearer ${{ secrets.CF_AIG_TOKEN }}
```

## Request shape

The request sends only `model` and `messages`. It does not send `temperature` or `max_tokens`, because newer OpenAI models reject those fields.

## Writing rules

The writing rules are fixed in `notes.sh` and are deliberately not an input. A knob that every caller sets identically is the same paragraph copied into every repository. The generated output is Traditional Chinese prose with a business tone. Technical terms, file names, operation names, and package names remain in English.

## Shared configuration

You can share configuration across repositories with GitHub organization variables and secrets:

- `AI_BASE_URL` as an organization variable
- `AI_MODEL` as an organization variable
- `AI_API_KEY` as an organization secret

The `base-url`, `model`, and `api-key` inputs fall back to those environment variables when the inputs are empty. An input value takes precedence over its environment variable.

## Test

```bash
bun test.ts
```

## License

MIT
