#!/bin/bash
# 合并润色稿并生成 EPUB
# 用法: bash build_epub.sh <润色稿目录> <输出目录> <书名>
# 依赖: pandoc (brew install pandoc)
set -e

POLISH_DIR="${1:?用法: build_epub.sh <润色稿目录> <输出目录> <书名>}"
OUT_DIR="${2:?用法: build_epub.sh <润色稿目录> <输出目录> <书名>}"
TITLE="${3:?用法: build_epub.sh <润色稿目录> <输出目录> <书名>}"

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

pandoc "$MERGED" -o "$EPUB" --metadata title="$TITLE" --metadata lang=zh-CN \
  --toc --toc-depth=1 2>/dev/null || pandoc "$MERGED" -o "$EPUB" --metadata title="$TITLE" --toc --toc-depth=1

echo "合并文件: $MERGED ($(wc -l < "$MERGED") 行)"
echo "EPUB: $EPUB"
# 验证章节数
echo "章节数: $(grep -c '^# ' "$MERGED")"
