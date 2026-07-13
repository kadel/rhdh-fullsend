#!/usr/bin/env bash
set -euo pipefail

# Download fullsend agent run transcripts from GitHub Actions and
# organise them so AgentsView can ingest them as Claude sessions.
#
# Usage:
#   ./fetch-fullsend-runs.sh                          # default repos (7 days)
#   ./fetch-fullsend-runs.sh --since 30d              # last 30 days
#   ./fetch-fullsend-runs.sh --all                    # all available artifacts
#   ./fetch-fullsend-runs.sh org/repo1 org/repo2      # custom repos (7 days)
#   ./fetch-fullsend-runs.sh --since 14d org/repo1    # custom repos + window
#
# Prerequisites: gh (authenticated), jq
#
# Directory layout produced (matches AgentsView Claude discovery):
#   runs/<repo>/<run-id>_issue-<N>_<transcript>.jsonl

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RUNS_DIR="${RUNS_DIR:-${SCRIPT_DIR}/../runs}"
SCAFFOLD_DIR="${FULLSEND_SCAFFOLD_DIR:-}"

# Parse flags
SINCE_DAYS=7
while [[ $# -gt 0 ]]; do
  case "$1" in
    --since)
      SINCE_DAYS="${2%d}"  # strip trailing 'd' if present
      shift 2
      ;;
    --all)
      SINCE_DAYS=0
      shift
      ;;
    *)
      break
      ;;
  esac
done

if [ $# -gt 0 ]; then
  REPOS=("$@")
else
  REPOS=("redhat-developer/rhdh-agentic" "redhat-developer/rhdh-plugins" "redhat-developer/rhdh-plugin-export-overlays")
fi

# Compute cutoff date
if [ "$SINCE_DAYS" -gt 0 ]; then
  if date -v-1d >/dev/null 2>&1; then
    SINCE_DATE=$(date -v-${SINCE_DAYS}d -u +%Y-%m-%dT00:00:00Z)
  else
    SINCE_DATE=$(date -u -d "${SINCE_DAYS} days ago" +%Y-%m-%dT00:00:00Z)
  fi
else
  SINCE_DATE=""
fi

for cmd in gh jq; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "error: $cmd is required" >&2; exit 1; }
done

mkdir -p "$RUNS_DIR"

# --- System prompt reconstruction ---
# Assembles the agent's effective system prompt from scaffold sources and
# returns a JSONL line that AgentsView renders as the first chat message.
_scaffold_warned=false

build_prompt_line() {
  local agent_name="$1" ts="$2" repo_claude_md="$3" repo_agents_md="$4"

  if [ -z "$SCAFFOLD_DIR" ]; then
    if [ "$_scaffold_warned" = false ]; then
      echo "  [info] FULLSEND_SCAFFOLD_DIR not set — skipping prompt reconstruction" >&2
      _scaffold_warned=true
    fi
    return 0
  fi

  local sections=()

  # 1. Agent definition
  local agent_file="${SCAFFOLD_DIR}/agents/${agent_name}.md"
  if [ -f "$agent_file" ]; then
    sections+=("## Agent Definition\n\n$(cat "$agent_file")")
  fi

  # 2. Project instructions (CLAUDE.md + AGENTS.md)
  local project_section=""
  if [ -n "$repo_claude_md" ]; then
    project_section="### CLAUDE.md\n\n${repo_claude_md}"
  fi

  local agents_md_content="$repo_agents_md"
  if [ -z "$agents_md_content" ] && [ -f "${SCAFFOLD_DIR}/AGENTS.md" ]; then
    agents_md_content="$(cat "${SCAFFOLD_DIR}/AGENTS.md")"
  fi
  if [ -n "$agents_md_content" ]; then
    [ -n "$project_section" ] && project_section="${project_section}\n\n"
    project_section="${project_section}### AGENTS.md\n\n${agents_md_content}"
  fi

  # Inject bridge pointer when repo has AGENTS.md but no CLAUDE.md
  if [ -z "$repo_claude_md" ] && [ -n "$agents_md_content" ]; then
    local bridge="Project rules and instructions live in [AGENTS.md](AGENTS.md). Read that file now — it is the single source of truth for all agent-facing guidance in this repo."
    project_section="### CLAUDE.md (bridge)\n\n${bridge}\n\n${project_section}"
  fi

  if [ -n "$project_section" ]; then
    sections+=("## Project Instructions\n\n${project_section}")
  fi

  # 3. Skills from harness YAML
  local harness_file="${SCAFFOLD_DIR}/harness/${agent_name}.yaml"
  if [ -f "$harness_file" ]; then
    local skills_section=""
    while IFS= read -r skill_path; do
      local skill_name
      skill_name=$(basename "$skill_path")
      local skill_file="${SCAFFOLD_DIR}/${skill_path}/SKILL.md"
      if [ -f "$skill_file" ]; then
        [ -n "$skills_section" ] && skills_section="${skills_section}\n\n---\n\n"
        skills_section="${skills_section}### ${skill_name}\n\n$(cat "$skill_file")"
      fi
    done < <(grep -E '^\s*- skills/' "$harness_file" | sed 's/^[[:space:]]*- //')

    if [ -n "$skills_section" ]; then
      sections+=("## Skills\n\n${skills_section}")
    fi
  fi

  if [ ${#sections[@]} -eq 0 ]; then
    return 0
  fi

  local body
  body=$(printf '%s' "${sections[0]}")
  local idx
  for ((idx=1; idx < ${#sections[@]}; idx++)); do
    body=$(printf '%s\n\n---\n\n%s' "$body" "${sections[$idx]}")
  done

  local prompt_content
  prompt_content=$(printf '📋 System Prompt (reconstructed)\n\n%b' "$body")

  local tmpfile
  tmpfile=$(mktemp)
  printf '%s' "$prompt_content" > "$tmpfile"

  jq -nc --rawfile content "$tmpfile" \
    --arg ts "$ts" \
    '{type: "user", timestamp: $ts, message: {content: $content}}'

  rm -f "$tmpfile"
}

echo "Fetching fullsend runs -> $RUNS_DIR"
echo "Repos: ${REPOS[*]}"
if [ -n "$SINCE_DATE" ]; then
  echo "Since: $SINCE_DATE (${SINCE_DAYS}d)"
else
  echo "Since: all available"
fi
echo

total_fetched=0
total_skipped=0

for repo in "${REPOS[@]}"; do
  repo_name=$(basename "$repo")
  echo "--- $repo ---"

  # Cache CLAUDE.md / AGENTS.md for this repo (one API call each)
  repo_claude_md=""
  repo_agents_md=""
  if [ -n "$SCAFFOLD_DIR" ]; then
    repo_claude_md=$(gh api "repos/${repo}/contents/CLAUDE.md" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null || true)
    repo_agents_md=$(gh api "repos/${repo}/contents/AGENTS.md" --jq '.content' 2>/dev/null | base64 -d 2>/dev/null || true)
  fi

  # Fetch artifacts with automatic pagination, filtered by date window
  since_filter=""
  if [ -n "$SINCE_DATE" ]; then
    since_filter="| select(.created_at >= \"$SINCE_DATE\")"
  fi
  artifacts=$(gh api --paginate "repos/${repo}/actions/artifacts?per_page=100" \
    --jq "[.artifacts[] | select(.name | startswith(\"fullsend-\")) | select(.expired == false) ${since_filter} | {id:.id, name:.name, run_id:.workflow_run.id, created:.created_at}]" 2>/dev/null \
    | jq -s 'add // []') || {
    echo "  [skip] could not list artifacts"
    continue
  }

  count=$(echo "$artifacts" | jq 'length')
  echo "  $count fullsend artifact(s)"

  for i in $(seq 0 $((count - 1))); do
    art_name=$(echo "$artifacts" | jq -r ".[$i].name")
    run_id=$(echo "$artifacts" | jq -r ".[$i].run_id")
    created=$(echo "$artifacts" | jq -r ".[$i].created")
    agent_name=${art_name#fullsend-}

    # Skip if we already have files for this run+agent
    project_dir="${repo_name}"
    if compgen -G "${RUNS_DIR}/${project_dir}/${run_id}_*.jsonl" >/dev/null 2>&1; then
      total_skipped=$((total_skipped + 1))
      continue
    fi

    # Get run metadata (title, conclusion, URL)
    run_meta=$(gh api "repos/${repo}/actions/runs/${run_id}" \
      --jq '{title:.display_title, conclusion:.conclusion, url:.html_url}' 2>/dev/null) || continue
    title=$(echo "$run_meta" | jq -r '.title')
    conclusion=$(echo "$run_meta" | jq -r '.conclusion')
    run_url=$(echo "$run_meta" | jq -r '.url')

    echo "  run $run_id | $art_name | $conclusion"

    tmpdir=$(mktemp -d)

    if ! gh run download "$run_id" --repo "$repo" --dir "$tmpdir" --name "$art_name" 2>/dev/null; then
      rm -rf "$tmpdir"
      echo "    (download failed)"
      continue
    fi

    # Default entity type from agent name; overridden by run-summary.json if available
    case "$agent_name" in
      review|fix) entity_type="pr" ;;
      *)          entity_type="issue" ;;
    esac

    # Find the agent run directory (agent-<type>-<id>-<hash>/)
    agent_dir=$(find "$tmpdir" -mindepth 1 -maxdepth 1 -type d -name 'agent-*' | head -1)
    if [ -z "$agent_dir" ]; then
      echo "    (no agent directory in artifact)"
      rm -rf "$tmpdir"
      continue
    fi

    # Extract metadata from run-summary.json (canonical source)
    summary_file="${agent_dir}/run-summary.json"
    if [ -f "$summary_file" ]; then
      work_item_url=$(jq -r '."fullsend.work_item_id" // empty' "$summary_file")
      if [ -n "$work_item_url" ]; then
        issue_num=$(echo "$work_item_url" | grep -oE '[0-9]+$' || true)
        # Derive entity type from URL path
        case "$work_item_url" in
          */pull/*) entity_type="pr" ;;
          *)        entity_type="issue" ;;
        esac
      fi
      cost_usd=$(jq -r '.metrics.total_cost_usd // empty' "$summary_file")
      duration_s=$(jq -r '(.duration_ms // 0) / 1000 | floor' "$summary_file")
      num_turns=$(jq -r '.metrics.num_turns // empty' "$summary_file")
    fi
    [ -z "${issue_num:-}" ] && issue_num="unknown"

    # Extract agent result (triage summary, review comment, etc.)
    result_file=$(find "$agent_dir" -name 'agent-result.json' -type f | head -1)
    result_comment=""
    if [ -n "$result_file" ] && [ -f "$result_file" ]; then
      result_comment=$(jq -r '.comment // empty' "$result_file")
    fi

    dest_dir="${RUNS_DIR}/${project_dir}"

    # Build header once per run (shared across transcripts)
    agent_setting_line=$(jq -nc \
      --arg agent "$agent_name" \
      --arg ts "$created" \
      '{type: "agent-setting", agentSetting: ("fs-" + $agent), timestamp: $ts}')

    title_extra=""
    [ -n "${cost_usd:-}" ] && title_extra=" · \$${cost_usd}"
    [ -n "${duration_s:-}" ] && title_extra="${title_extra} · ${duration_s}s"
    [ -n "${num_turns:-}" ] && title_extra="${title_extra} · ${num_turns} turns"

    meta_line=$(jq -nc \
      --arg entity "$entity_type" \
      --arg issue "$issue_num" \
      --arg run_id "$run_id" \
      --arg agent "$agent_name" \
      --arg conclusion "$conclusion" \
      --arg extra "$title_extra" \
      --arg url "$run_url" \
      --arg ts "$created" \
      --arg cwd "/fullsend/${project_dir}" \
      '{
        type: "user",
        timestamp: $ts,
        message: {
          content: ("\($agent) \($entity) #\($issue) - run \($run_id) [\($conclusion)\($extra)]\n\($url)")
        },
        cwd: $cwd
      }')

    result_line=""
    if [ -n "$result_comment" ]; then
      result_line=$(jq -nc \
        --arg comment "$result_comment" \
        --arg ts "$created" \
        '{
          type: "assistant",
          message: {
            role: "assistant",
            type: "message",
            content: [{ type: "text", text: $comment }],
            stop_reason: "end_turn"
          },
          timestamp: $ts
        }')
    fi

    prompt_line=$(build_prompt_line "$agent_name" "$created" "$repo_claude_md" "$repo_agents_md" || true)

    found=false
    while IFS= read -r -d '' jsonl; do
      found=true
      mkdir -p "$dest_dir"

      local_name=$(basename "$jsonl")
      dest_file="${dest_dir}/${run_id}_${entity_type}-${issue_num}_${local_name}"

      case "$local_name" in
        *-agent-a*)
          # Subagent transcript — copy as-is (AgentsView groups under parent)
          cp "$jsonl" "$dest_file"
          ;;
        *)
          # Main session — inject headers, prompt, and result
          {
            echo "$agent_setting_line"
            echo "$meta_line"
            [ -n "$prompt_line" ] && echo "$prompt_line"
            cat "$jsonl"
            [ -n "$result_line" ] && echo "$result_line"
          } > "$dest_file"
          ;;
      esac
      echo "    -> ${project_dir}/$(basename "$dest_file")"
      total_fetched=$((total_fetched + 1))
    done < <(find "$tmpdir" -name '*.jsonl' -path '*/transcripts/*' -print0)

    if [ "$found" = "false" ]; then
      echo "    (no transcripts in artifact)"
    fi

    rm -rf "$tmpdir"
  done

  echo
done

echo "Done: ${total_fetched} fetched, ${total_skipped} skipped"
if [ "$total_fetched" -gt 0 ] || [ "$total_skipped" -gt 0 ]; then
  echo "Start viewer: make fullsend-up   (or: podman compose -f docker-compose.fullsend.yaml up -d)"
fi
