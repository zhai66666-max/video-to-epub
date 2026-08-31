# video-to-epub

将本地视频或音频批量转成**带逐字稿、润色稿和 EPUB 电子书**的完整流水线（WorkBuddy / Claude 类 Agent Skill）。

输入可为视频（mp4/mov/mkv/flv/avi）或成品音频（mp3/wav/m4a/aac/flac/ogg），输出：

- `逐字稿/` — whisper-cli 原生转写（无标点，保留原样）
- `润色稿/` — AI 润色版（繁体转简体、加标点、修正同音错字、概括标题）
- `合并.md` — 全部润色稿合并为一个 markdown
- `书名.epub` — 由 pandoc 生成的电子书（章节名 = 每篇概括标题）

## 依赖（macOS）

| 依赖 | 安装 | 用途 |
|---|---|---|
| ffmpeg / ffprobe | `brew install ffmpeg` | 音频提取 / 时长检查 |
| whisper-cli（whisper.cpp） | `brew install whisper-cpp` | 语音转写（Metal GPU 加速） |
| pandoc | `brew install pandoc` | EPUB 生成 |
| ggml-small.bin 模型 | 见下方 | 中文转写（multilingual 版） |

### 模型下载（国内镜像 + 禁用 xet）

```bash
mkdir -p ~/.cache/whisper-cpp
curl -fsL https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/ggml-small.bin \
  -o ~/.cache/whisper-cpp/ggml-small.bin
```

> 可选：faster-whisper（Python）+ large-v3-turbo，用于定点复查 whisper 漏音段落。

## 安装

克隆到 WorkBuddy（或 Claude Code 等支持 SKILL.md 的 Agent）的 skills 目录：

```bash
git clone https://github.com/<你的用户名>/video-to-epub.git \
  ~/.workbuddy/skills/video-to-epub
```

## 流水线

```
视频/音频目录
   │  ffmpeg 抽音频 → 统一转 16kHz wav
   ▼
whisper-cli 转写（逐字稿/xxx.txt）
   │  完整性检查：比较音频总时长 vs 末段时间戳，缺口 >8s 告警
   ▼
AI 润色（润色稿/xxx.md）
   │  繁体→简体 · 同音错字修正 · 加标点分段 · 概括标题（# 标题）
   │  引号统一「」 · 断句不通时回原音频定点复查
   ▼
合并 markdown + pandoc 生成 EPUB
   ▼
交付：EPUB + 合并.md + 润色稿示例
```

## 脚本说明

| 脚本 | 作用 |
|---|---|
| `scripts/transcribe_batch.sh` | 批量转音频 + whisper 转写，自动时长完整性检查，已存在 txt 跳过（可断点续跑） |
| `scripts/fix_quotes.py` | 把润色稿中的 ASCII 引号 `"` 批量替换为中文「」（EPUB 渲染需要） |
| `scripts/build_epub.sh` | 合并润色稿 markdown 并用 pandoc 生成 EPUB |

## 关键坑（从实战中总结）

1. **VAD 漏音**：whisper.cpp 可能漏掉整句（能量检测误判静音），转写后必须做时长完整性检查；发现缺口用 faster-whisper large-v3-turbo 定点重转。
2. **引号**：中文文本禁用 ASCII `"`，统一「」，否则 EPUB 渲染方向混乱。
3. **繁体**：whisper 中文输出可能是繁体，润色时统一转简体（small/turbo 模型输出简体、medium 输出繁体）。
4. **模型下载**：HuggingFace 新 xet 协议会失败，必须 `HF_HUB_DISABLE_XET=1` + `HF_ENDPOINT=https://hf-mirror.com`。
5. **速度参考（Apple M5, 10 核）**：whisper.cpp ggml-small + Metal 约 7.7x 实时；faster-whisper large-v3-turbo CPU int8 约 4.7x 实时；ffmpeg 转 16kHz wav 约 20x 实时。

## License

MIT
