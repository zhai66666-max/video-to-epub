---
name: video-to-epub
description: 将本地视频或音频批量转成带逐字稿、润色稿和 EPUB 电子书的完整流水线。当用户要求"视频/音频转成文字/逐字稿/转写""把视频或音频做成电子书/epub""视频转音频再转稿""批量转写音频"时使用。流程：ffmpeg 转 16kHz wav → whisper-cli(whisper.cpp) 转写 → AI 润色（简体、加标点、概括标题）→ 合并 markdown → pandoc 转 EPUB（章节名=概括标题）。输入可为视频(mp4/mov/mkv)或成品音频(mp3/wav/m4a)。
agent_created: true
---

# 视频/音频 → 逐字稿 → 润色 → EPUB 流水线

把一批本地媒体文件（视频 mp4/mov/mkv/flv/avi，或成品音频 mp3/wav/m4a/aac/flac/ogg）转成：原始逐字稿 → 润色稿 → 合并 markdown → EPUB 电子书。

## 触发条件
用户提供本地视频**或音频**目录，要求：转写逐字稿、转文字、做电子书、批量语音识别等。输出目录默认 `~/Desktop/<项目名>逐字稿/`（逐字稿/ + 润色稿/ + 合并.md + 书名.epub）。

## 输入类型判断
- 目录里是**视频** → 直接走流程（ffmpeg 抽音频）
- 目录里是**音频**（mp3/wav/m4a 等）→ 跳过"从视频抽音频"的语义，但仍统一转 16kHz wav 喂给 whisper-cli（转写前先确认输入是音频，不要去找视频）
- 视频音频混合目录也能处理

## 依赖（macOS）
- `ffmpeg`、`ffprobe`：音频提取/时长检查
- `whisper-cli`（whisper.cpp，`brew install whisper-cpp`）：转写，Metal GPU 加速
- `pandoc`（`brew install pandoc`）：EPUB 生成
- 模型 `~/.cache/whisper-cpp/ggml-small.bin`（中文用 multilingual 版；下载见下方"模型下载"）
- 可选：faster-whisper（Python）+ large-v3-turbo，用于定点复查漏音

## 流程

### 1. 环境与模型检查
```bash
command -v ffmpeg whisper-cli pandoc || echo "缺失"
[ -f ~/.cache/whisper-cpp/ggml-small.bin ] || echo "缺模型"
```
模型下载（国内镜像 + 禁用 xet）：
```bash
mkdir -p ~/.cache/whisper-cpp
curl -fsL https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/ggml-small.bin \
  -o ~/.cache/whisper-cpp/ggml-small.bin
```

### 2. 批量转音频 + 转写
```bash
bash ~/.workbuddy/skills/video-to-epub/scripts/transcribe_batch.sh \
  "<视频目录>" "<输出目录>/逐字稿"
```
- 输出 `逐字稿/<文件名>.txt`（whisper-cli 原生输出，无标点）
- 脚本自动做**完整性检查**：比较音频总时长 vs 转写末段时间戳，尾部缺口 >8s 会告警
- 已存在的 txt 自动跳过（可断点续跑）

### 3. 定点复查漏音（重要）
whisper.cpp 偶发漏掉整句（能量检测误判静音）。发现告警或用户指出"句子读不通/跳了"时：
1. 用 whisper-cli `-oj` 输出时间戳，定位空白段
2. 提取该段音频（前后各多留 2s）：`ffmpeg -ss <start> -t <len> -i note.wav seg.wav`
3. 用 faster-whisper large-v3-turbo 重新识别：
```bash
export HF_ENDPOINT=https://hf-mirror.com HF_HUB_DISABLE_XET=1
python -c "
from faster_whisper import WhisperModel
m = WhisperModel('large-v3-turbo', device='cpu', compute_type='int8')
for s, _ in m.transcribe('seg.wav', language='zh', vad_filter=False):
    print(f'[{s.start+<起点>:.1f}s] {s.text}')
"
```
把找回的内容补进润色稿对应位置。

### 4. AI 润色（核心增值步骤）
对每份 txt 逐个润色，输出到 `润色稿/<同名>.md`：
- 繁体 → 简体（whisper 中文默认输出繁体）
- 修正同音错字（结合上下文猜原意，如"择有→择优""树出→庶出""四世三宫→四世三公"）
- 加标点、分段、提升可读性，**保持原意不改内容**
- 每篇根据内容概括一个标题，用 `# 标题` 作为文件首行（将作为 EPUB 章节名）
- **引号一律用「」(U+300C)/」」(U+300D)**，禁用英文 `"`（U+0022），否则 EPUB 渲染方向混乱
- 已写错英文引号时运行：`python3 ~/.workbuddy/skills/video-to-epub/scripts/fix_quotes.py "<润色稿目录>"`
- 口播断句处若原话没说完，不要用"……"糊弄，回到原音频定点复查

### 5. 合并 + 生成 EPUB
```bash
bash ~/.workbuddy/skills/video-to-epub/scripts/build_epub.sh \
  "<润色稿目录>" "<输出目录>" "<书名>"
```
- 章节名 = 每篇的 `# 标题`（先与用户确认标题风格，或直接按内容概括）
- 产出 `<输出目录>/合并.md` 和 `<输出目录>/<书名>.epub`

### 6. 交付
- `present_files` 展示 EPUB（第一位）、合并.md、润色稿示例
- 提醒用户：原始逐字稿保留转写原样（无标点），润色稿为加工版
- 提醒可能存在的同音错字，建议对照原视频听一遍

## 关键坑（务必遵守）
1. **VAD 漏音**：whisper-cli 可能漏掉整句（本例漏了 3.5s 的内容）。转写后必须做时长完整性检查；用户反馈异常时用 large-v3-turbo 定点重转。
2. **引号**：中文文本禁用 ASCII `"`，统一「」；润色稿写好后再跑一次 fix_quotes.py 兜底。
3. **繁体**：whisper 中文输出繁体，润色时统一转简体（small 模型输出简体、turbo 输出简体、medium 输出繁体，视模型而定）。
4. **模型下载**：HuggingFace 新 xet 协议会失败，必须 `HF_HUB_DISABLE_XET=1` + `HF_ENDPOINT=https://hf-mirror.com`。
5. **用户目录习惯**：用户可能中途清理/重建工作目录；写文件前先确认目录存在，中间产物放 /tmp。
6. **faster-whisper 备选**：若 whisper.cpp 不可用，faster-whisper（venv：`~/.workbuddy/binaries/python/envs/default`）需先装 av 等依赖（pip 清华源），且其 MPS 通常不可用、CPU 速度约 2-8x 实时，慢于 whisper.cpp Metal。

## 速度参考（Apple M5，10 核）
- whisper.cpp ggml-small + Metal：约 7.7x 实时（180 分钟音频约 12 分钟）
- faster-whisper large-v3-turbo CPU int8：约 4.7x 实时
- ffmpeg 转 16kHz wav：约 20x 实时
