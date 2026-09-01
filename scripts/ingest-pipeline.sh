#!/bin/bash
# bilibili-to-wiki 主编排脚本：抓取 → 勘误 → 入库 → 反哺 → 图谱 → 日志
# 用法: bash ingest-pipeline.sh <视频输入> [--pages N] [--no-whisper]
set -uo pipefail

BILI_SKILL="$HOME/.pi/agent/skills/bilibili-learn"
WIKI_SKILL="$HOME/.pi/agent/skills/llm-wiki"
KB="$(cat "$HOME/.llm-wiki-path" 2>/dev/null)"
LOG_FILE="$HOME/.pi/logs/bili-to-wiki.log"
TMP_DIR="$(mktemp -d)"
INPUT="$1"; shift 2>/dev/null || true
PAGES=""
NO_WHISPER=""

while [ $# -gt 0 ]; do
  case "$1" in
    --pages) PAGES="$2"; shift 2 ;;
    --no-whisper) NO_WHISPER="--no-whisper"; shift ;;
    *) shift ;;
  esac
done

mkdir -p "$(dirname "$LOG_FILE")"
log() { printf '%s\n' "[$(date '+%F %T')] $*" >> "$LOG_FILE"; }

# --- 前置检查 ---
[ -f "$BILI_SKILL/scripts/bili.py" ] || { echo "ERROR: bilibili-learn 缺失"; log "precheck fail: bilibili-learn missing"; exit 1; }
[ -d "$WIKI_SKILL/scripts" ] || { echo "ERROR: llm-wiki 缺失"; log "precheck fail: llm-wiki missing"; exit 1; }
[ -n "$KB" ] || { echo "ERROR: 知识库未初始化（~/.llm-wiki-path 为空）"; log "precheck fail: no kb path"; exit 1; }

echo "[1/4] 抓取字幕: $INPUT"
ARGS=(run "$INPUT" --out "$TMP_DIR")
[ -n "$PAGES" ] && ARGS+=(--pages "$PAGES")
[ -n "$NO_WHISPER" ] && ARGS+=(--no-whisper)
python -X utf8 "$BILI_SKILL/scripts/bili.py" "${ARGS[@]}" 2>&1 | tail -3

SUB="$(find "$TMP_DIR" -name subtitle.txt | head -1)"
[ -n "$SUB" ] || { echo "ERROR: 未生成 subtitle.txt"; log "fail: no subtitle for $INPUT"; exit 2; }

# --- 勘误 ---
echo "[2/4] 术语勘误 (glossary clean)"
python -X utf8 "$BILI_SKILL/scripts/glossary.py" clean "$SUB" --out "${SUB%.txt}.corrected.txt" 2>&1 | head -8
CORRECTED="${SUB%.txt}.corrected.txt"
[ -f "$CORRECTED" ] || cp "$SUB" "$CORRECTED"

# --- 输出 corrected 稿路径（命名与入库交给 agent，脚本不猜文件名）---
echo "[3/4] corrected 稿: $CORRECTED"
CORRECTED_CONTENT_SUMMARY="$(head -c 200 "$CORRECTED" | tr '\n' ' ')"
echo "[4/4] 下一步（由 agent 执行）："
echo "  1. 复制 corrected 稿到 \$KB/raw/notes/<agent 决定的合理文件名>.md（含 front matter）"
echo "  2. 对 raw 文件执行 llm-wiki digest"
bash "$WIKI_SKILL/scripts/cache.sh" check "$DEST" 2>/dev/null || true
log "pipeline: $INPUT -> corrected 稿就绪（digest 由 agent 继续）"
