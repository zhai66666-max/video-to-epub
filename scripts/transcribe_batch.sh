#!/bin/bash
# 批量转写：视频/音频 -> 16kHz wav -> whisper-cli 逐字稿(txt)
# 用法: bash transcribe_batch.sh <输入目录(视频或音频)> <输出目录>
# 支持输入: 视频 mp4/mov/mkv/flv/avi；音频 mp3/wav/m4a/aac/flac/ogg
# 依赖: ffmpeg, whisper-cli(whisper.cpp), 模型 ~/.cache/whisper-cpp/ggml-small.bin
set -e

SRC_DIR="${1:?用法: transcribe_batch.sh <输入目录> <输出目录>}"
OUT_DIR="${2:?用法: transcribe_batch.sh <输入目录> <输出目录>}"
MODEL="${3:-$HOME/.cache/whisper-cpp/ggml-small.bin}"

# 检查依赖
command -v ffmpeg >/dev/null || { echo "缺少 ffmpeg"; exit 1; }
command -v whisper-cli >/dev/null || { echo "缺少 whisper-cli (brew install whisper-cpp)"; exit 1; }
[ -f "$MODEL" ] || { echo "缺少模型: $MODEL"; exit 1; }

TMP_WAV=$(mktemp -d /tmp/v2e_wav.XXXXXX)
mkdir -p "$OUT_DIR"
cd "$SRC_DIR"

for v in *.mp4 *.mov *.mkv *.flv *.avi *.mp3 *.wav *.m4a *.aac *.flac *.ogg; do
  [ -f "$v" ] || continue
  base="${v%.*}"
  out="$OUT_DIR/${base}.txt"
  [ -s "$out" ] && { echo "跳过(已存在): $base"; continue; }

  echo "==> $base"
  # 视频或非wav音频 -> 统一转 16kHz 单声道 wav（whisper-cli 解码最稳的输入格式）
  if [[ "$v" != *.wav ]]; then
    ffmpeg -v error -y -i "$v" -vn -ac 1 -ar 16000 -c:a pcm_s16le "$TMP_WAV/${base}.wav"
  else
    cp "$v" "$TMP_WAV/${base}.wav"
  fi
  # 获取音频总时长(秒)
  DUR=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$TMP_WAV/${base}.wav")

  # whisper-cli 转写(中文; 若识别质量差可加 -t 8)
  whisper-cli -m "$MODEL" -f "$TMP_WAV/${base}.wav" -l zh --no-prints -otxt -oj \
    -of "$TMP_WAV/${base}" 2>/dev/null || true

  # 完整性检查: 比较音频时长与转写覆盖的末段时间戳
  PYBIN="${PYBIN:-python3}"
  LAST_END=$("$PYBIN" -c "
import json
try:
    d = json.load(open('$TMP_WAV/${base}.json'))
    segs = d.get('segments', d.get('transcription', {}).get('segments', []))
    print(max((s.get('end', 0) for s in segs), default=0))
except Exception:
    print(0)
")
  GAP=$("$PYBIN" -c "
print(round(float('$DUR') - float('$LAST_END'), 1))
")
  # 输出 txt 到目标目录
  cp "$TMP_WAV/${base}.txt" "$out"
  echo "   音频 ${DUR}s / 转写覆盖到 ${LAST_END}s / 尾部未覆盖 ${GAP}s"
  if "$PYBIN" -c "exit(0 if float('$GAP') > 8 else 1)" 2>/dev/null; then
    echo "   ⚠️ 警告: 尾部 ${GAP}s 未转写，可能漏音，建议用 faster-whisper large-v3-turbo 定点复查"
  fi
done

rm -rf "$TMP_WAV"
echo "=== 完成，文件数: $(ls "$OUT_DIR" | wc -l) ==="
