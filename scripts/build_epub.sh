#!/bin/bash
# 合并润色稿并生成 EPUB
# 用法: bash build_epub.sh <润色稿目录> <输出目录> <书名> [目录深度=1] [作者]
# 说明: 每个 md 以 `# ` 开头作为卷/章标题，`## ` 作为节标题。
#       toc-depth=1 只列卷（适合 900+ 篇的合集，目录干净）；
#       toc-depth=2 会连每篇一起列出（篇数少时可读性更好）。
# 依赖: pandoc (brew install pandoc)
set -e

POLISH_DIR="${1:?用法: build_epub.sh <润色稿目录> <输出目录> <书名> [目录深度] [作者]}"
OUT_DIR="${2:?用法: build_epub.sh <润色稿目录> <输出目录> <书名> [目录深度] [作者]}"
TITLE="${3:?用法: build_epub.sh <润色稿目录> <输出目录> <书名> [目录深度] [作者]}"
DEPTH="${4:-1}"
AUTHOR="${5:-}"

command -v pandoc >/dev/null || { echo "缺少 pandoc"; exit 1; }

mkdir -p "$OUT_DIR"
MERGED="$OUT_DIR/合并.md"
EPUB="$OUT_DIR/$TITLE.epub"

: > "$MERGED"
# 按文件名排序合并；每个 md 以 # 开头，作为 EPUB 章节标题
for f in "$POLISH_DIR"/*.md; do
  cat "$f" >> "$MERGED"
  echo "" >> "$MERGED"
done

META=(--metadata title="$TITLE" --metadata lang=zh-CN)
[ -n "$AUTHOR" ] && META+=(--metadata author="$AUTHOR")

pandoc "$MERGED" -o "$EPUB" "${META[@]}" --toc --toc-depth="$DEPTH" --epub-chapter-level=1 \
  2>/dev/null || pandoc "$MERGED" -o "$EPUB" "${META[@]}" --toc --toc-depth="$DEPTH"

echo "合并文件: $MERGED ($(wc -l < "$MERGED") 行)"
echo "EPUB: $EPUB ($(du -h "$EPUB" | cut -f1))"
# 验证章节数
echo "章节数（# 一级）: $(grep -c '^# ' "$MERGED")"
echo "节数（## 二级）: $(grep -c '^## ' "$MERGED")"
