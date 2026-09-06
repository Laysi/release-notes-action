#!/usr/bin/env bash
# Reads the commits a tag added, rewrites them as grouped release notes with
# any endpoint that speaks the OpenAI chat-completions format, and writes the
# markdown to a file.
#
#   TAG=v1.2.3 AI_MODEL=gpt-5 AI_API_KEY=... bash notes.sh
#
# The caller needs the repository checked out with its full history and tags
# (actions/checkout with fetch-depth: 0); a shallow clone has neither the tag
# nor the commits, and that is a configuration error, so it fails.
#
# What does not fail is the model. A missing key, an unreachable endpoint or
# an error body leaves the file holding the plain commit list and sets
# `failed` to 1: for a repository whose release page is the distribution,
# publishing commit subjects beats publishing nothing.
#
#   TAG            required. The tag being released.
#   TAG_PATTERN    which tags count as previous versions. Default `*`. A
#                  repository shipping two things from one history has two tag
#                  prefixes, and the wrong one gives the wrong range.
#   PREVIOUS_TAG   skips the lookup above.
#   EXCLUDE_PATHS  paths to leave out, comma or newline separated.
#   EXCLUDE_TYPES  conventional-commit types to drop. Default `ci,chore`.
#   LIMIT          most commits to send. Default 40.
#   CONTEXT        what the project is and who reads the notes.
#   AI_BASE_URL    endpoint up to but not including /chat/completions.
#                  Defaults to OpenAI. http is fine for a gateway on the same
#                  host; over a network use https, the key travels along.
#   AI_MODEL       model slug. Empty means no call at all.
#   AI_API_KEY     key for that endpoint, sent as a bearer token.
#   AI_EXTRA_HEADERS
#                  extra request headers, one `Name: value` per line. What a
#                  gateway in front of the model asks for beyond the bearer
#                  token -- Cloudflare AI Gateway wants cf-aig-authorization
#                  when the gateway itself is authenticated.
#   OUTPUT_FILE    where to write. Defaults under RUNNER_TEMP.
set -uo pipefail

# Inputs win over environment, so a caller can set the three either on the
# step or once on the job.
pick() { [ -n "$1" ] && printf '%s' "$1" || printf '%s' "$2"; }
BASE_URL="$(pick "${INPUT_BASE_URL:-}" "${AI_BASE_URL:-https://api.openai.com/v1}")"
MODEL="$(pick "${INPUT_MODEL:-}" "${AI_MODEL:-}")"
API_KEY="$(pick "${INPUT_API_KEY:-}" "${AI_API_KEY:-}")"
EXTRA_HEADERS="$(pick "${INPUT_EXTRA_HEADERS:-}" "${AI_EXTRA_HEADERS:-}")"
BASE_URL="${BASE_URL%/}"

: "${TAG:?TAG is required}"
TAG_PATTERN="${TAG_PATTERN:-*}"
EXCLUDE_TYPES="${EXCLUDE_TYPES-ci,chore}"
LIMIT="${LIMIT:-40}"
OUT="${OUTPUT_FILE:-${RUNNER_TEMP:-/tmp}/release-notes.md}"

git rev-parse -q --verify "$TAG^{commit}" >/dev/null ||
    { echo "找不到 tag $TAG。checkout 要帶 fetch-depth: 0。" >&2; exit 1; }

# The previous version by version order, not by what git describe reaches:
# a repository that ships two things from one history has two tag prefixes,
# and describe would answer with whichever came last.
PREV="${PREVIOUS_TAG:-}"
[ -n "$PREV" ] || PREV="$(git tag --list "$TAG_PATTERN" --sort=-v:refname | grep -A1 -x "$TAG" | tail -n1)"
[ "$PREV" = "$TAG" ] && PREV=""
RANGE="$TAG"
[ -n "$PREV" ] && RANGE="$PREV..$TAG"

# Seeded with `-- .` so the array is never empty, which `set -u` would trip
# over, and so an exclude has something to subtract from.
PATHSPEC=(-- .)
while IFS= read -r p; do
    p="$(printf '%s' "$p" | tr -d '[:space:]')"
    [ -n "$p" ] && PATHSPEC+=(":(exclude)$p")
done <<< "${EXCLUDE_PATHS:-}"

LOG="$(git log --no-merges --pretty='- %s' "$RANGE" "${PATHSPEC[@]}")" ||
    { echo "讀不出 $RANGE 的 commit。" >&2; exit 1; }

# Types are dropped by name: nothing a user runs changes when a workflow does,
# and a changelog listing those buries the lines that do.
if [ -n "$EXCLUDE_TYPES" ]; then
    TYPES="$(printf '%s' "$EXCLUDE_TYPES" | tr -d '[:space:]' | tr ',' '|')"
    LOG="$(printf '%s\n' "$LOG" | grep -vE "^- ($TYPES)(\([^)]*\))?:")"
fi
LOG="$(printf '%s\n' "$LOG" | head -n "$LIMIT")"
[ -n "$LOG" ] || LOG="（此區間沒有 commit）"

# Fixed rules plus the caller's one-paragraph description of the project. The
# rules are not an input: a knob every caller sets the same way is a copy of
# the same paragraph in every repository.
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
    REQ="$(jq -n --arg m "$MODEL" --arg s "$PROMPT" --arg u "$LOG" \
        '{model: $m, messages: [{role: "system", content: $s}, {role: "user", content: $u}]}')" || ERR="jq 組不出請求"

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
    printf '%s\n' "$LOG" > "$OUT"
    FAILED=1
    echo "[release-notes] 模型整理失敗，改用 commit 清單：$ERR" >&2
fi

{
    printf 'file=%s\n' "$OUT"
    printf 'failed=%s\n' "$FAILED"
    printf 'previous-tag=%s\n' "$PREV"
    printf 'range=%s\n' "$RANGE"
} >> "${GITHUB_OUTPUT:-/dev/null}"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ] && [ "$FAILED" = 1 ]; then
    printf '發版說明未經模型整理（%s），發佈的是 commit 清單。\n' "$ERR" >> "$GITHUB_STEP_SUMMARY"
fi
