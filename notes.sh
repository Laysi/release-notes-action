#!/usr/bin/env bash
# Rewrites a commit list as grouped release notes, using any endpoint that
# speaks the OpenAI chat-completions format.
#
#   COMMITS_FILE=commits.md AI_MODEL=gpt-5 AI_API_KEY=... bash notes.sh
#
# Prints nothing to stdout. Writes the markdown to a file and reports the path
# through GITHUB_OUTPUT (or OUTPUT_FILE when run by hand).
#
# It never exits non-zero on a failed call. The file then holds the commit
# list unchanged and `failed` is 1: for a repository whose release page is
# the distribution, publishing plain commit subjects beats publishing nothing.
#
#   COMMITS_FILE  required. Commit subjects, one per line, already filtered.
#   CONTEXT       what the project is and who reads the notes.
#   AI_BASE_URL   endpoint up to but not including /chat/completions.
#                 Defaults to OpenAI. http is fine for a gateway on the same
#                 host; over a network use https, the key travels along.
#   AI_MODEL      model slug. Empty means no call at all.
#   AI_API_KEY    key for that endpoint, sent as a bearer token.
#   AI_EXTRA_HEADERS
#                 extra request headers, one `Name: value` per line. What a
#                 gateway in front of the model asks for beyond the bearer
#                 token -- Cloudflare AI Gateway wants cf-aig-authorization
#                 when the gateway itself is authenticated.
#   OUTPUT_FILE   where to write. Defaults under RUNNER_TEMP.
set -uo pipefail

# Inputs win over environment, so a caller can set the three either on the
# step or once on the job.
BASE_URL="${INPUT_BASE_URL:-}"; [ -n "$BASE_URL" ] || BASE_URL="${AI_BASE_URL:-https://api.openai.com/v1}"
MODEL="${INPUT_MODEL:-}"; [ -n "$MODEL" ] || MODEL="${AI_MODEL:-}"
API_KEY="${INPUT_API_KEY:-}"; [ -n "$API_KEY" ] || API_KEY="${AI_API_KEY:-}"
EXTRA_HEADERS="${INPUT_EXTRA_HEADERS:-}"; [ -n "$EXTRA_HEADERS" ] || EXTRA_HEADERS="${AI_EXTRA_HEADERS:-}"
BASE_URL="${BASE_URL%/}"

: "${COMMITS_FILE:?COMMITS_FILE is required}"
[ -r "$COMMITS_FILE" ] || { echo "讀不到 commit 清單：$COMMITS_FILE" >&2; exit 1; }
OUT="${OUTPUT_FILE:-${RUNNER_TEMP:-/tmp}/ai-release-notes.md}"
COMMITS="$(cat "$COMMITS_FILE")"

# Fixed rules plus the caller's one-paragraph description of the project. The
# rules are not an input: a knob that every caller sets the same way is a
# copy of the same paragraph in every repository.
PROMPT="${CONTEXT:-}
依 commit 主旨清單寫出這一版的變更說明。

- 繁體中文，商務語氣，清晰簡潔；技術名詞、檔名、操作名與套件名保留英文。
- 只輸出三級標題（###）與單層 bullet。不要 H1、H2、前言、結語、表格與程式碼圍欄。
- 依性質分組，只列出有內容的分組：升級注意事項、新功能、修正、其他。
- 每個 bullet 寫成「**範圍**：一句話」，講使用者看得到的變化，不照抄 commit 訊息，不列 commit hash。
- 同類 commit 併成一條，每個分組最多 6 條。
- 只寫 commit 支持得住的事實。commit 沒寫的版本號、價格、模型名稱、部署環境與安全影響一律不補。
- 真的會影響資料、部署或相容性的才進升級注意事項。"

CONTENT=""
ERR=""
if [ -z "$MODEL" ] || [ -z "$API_KEY" ]; then
    ERR="沒有設定 AI_MODEL 或 AI_API_KEY"
else
    # No temperature and no max_tokens: newer OpenAI models reject both, and
    # neither buys anything here.
    REQ="$(jq -n --arg m "$MODEL" --arg s "$PROMPT" --arg u "$COMMITS" \
        '{model: $m, messages: [{role: "system", content: $s}, {role: "user", content: $u}]}')" || ERR="jq 組不出請求"
    # Seeded so the array is never empty, which `set -u` would trip over.
    HEADERS=(-H 'Content-Type: application/json' -H "Authorization: Bearer $API_KEY")
    while IFS= read -r line; do
        [ -n "$line" ] && HEADERS+=(-H "$line")
    done <<< "$EXTRA_HEADERS"

    if [ -z "$ERR" ]; then
        RESP="$(curl -sS --connect-timeout 10 --max-time 300 "$BASE_URL/chat/completions" \
            "${HEADERS[@]}" \
            -d "$REQ" 2>&1)" || ERR="呼叫 $BASE_URL 失敗：$RESP"
    fi
    if [ -z "$ERR" ]; then
        CONTENT="$(printf '%s' "$RESP" | jq -r '.choices[0].message.content // empty' 2>/dev/null)" || CONTENT=""
        # OpenAI-style .error.message, or the .detail/.message that some
        # compatible gateways answer with.
        [ -n "$CONTENT" ] || ERR="$(printf '%s' "$RESP" | jq -r '(.error.message // .detail // .message // "模型沒有回覆內容") | tostring' 2>/dev/null)"
        [ -n "$CONTENT" ] || [ -n "$ERR" ] || ERR="模型沒有回覆內容"
    fi
fi

if [ -n "$CONTENT" ]; then
    printf '%s\n' "$CONTENT" > "$OUT"
    FAILED=0
else
    printf '%s\n' "$COMMITS" > "$OUT"
    FAILED=1
    echo "[release-notes] 模型整理失敗，改用 commit 清單：$ERR" >&2
fi

{
    printf 'file=%s\n' "$OUT"
    printf 'failed=%s\n' "$FAILED"
} >> "${GITHUB_OUTPUT:-/dev/null}"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ] && [ "$FAILED" = 1 ]; then
    printf '發版說明未經模型整理（%s），發佈的是 commit 清單。\n' "$ERR" >> "$GITHUB_STEP_SUMMARY"
fi
