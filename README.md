# video-to-epub

把本地**视频或音频**批量转成「逐字稿 → 润色稿 → 合并 markdown → EPUB 电子书」的完整流水线，内含 whisper.cpp / pandoc 的实战踩坑记录。

输入可为视频（mp4/mov/mkv/flv/avi）或成品音频（mp3/wav/m4a/aac/flac/ogg）。

## 先看这三条结论

1. **默认用 `ggml-medium`，不要用 `small`。** 中文口播的准确率差距很大，财经/科普/哲学类专有名词尤其明显；medium 只比 small 慢一点。
2. **并行有用，但只有约 1.8 倍，不是线性。** 实测 3 路并发合计约 10.6x 实时（每路 3.5x），单进程 5.9x。16 GB 机器 **3 路是上限**（每进程 wired 约 2.25 GB，3 路时 wired 已到 9.2 GB）。另外：**别用几十秒的短样本估速度**——100s 片段会测出 12x，实际稳态只有 5.9x。
3. **转写只是及格线，润色才是成书的关键。** 原始转写无标点、同音错字多、简繁混杂；不经过逐篇润色，出来的 EPUB 没法读。

## 三种典型场景

| 场景 | 做法 |
|---|---|
| 一个目录里几十上百条短视频/短音频 | 直接 `transcribe_batch.sh` 串行跑，边转边把已完成的派给子代理润色 |
| 单集长节目（20–60 分钟） | 按「一本书」搭骨架：先 `yt-dlp --dump-json` 拿标题/UP 主/章节时间戳，再转写 |
| 超长合集（>2 小时） | 切段（每段 ≤4000s、前后留 15s 重叠）并行跑；合并时按「句中点落在核心窗口」归属 |

## 依赖（macOS）

| 依赖 | 安装 | 用途 |
|---|---|---|
| ffmpeg / ffprobe | `brew install ffmpeg` | 音频提取 / 时长检查 |
| whisper-cli（whisper.cpp） | `brew install whisper-cpp` | 语音转写（Metal GPU 加速） |
| pandoc | `brew install pandoc` | EPUB 生成 |
| ggml-medium.bin | 见下方 | 中文转写（multilingual 版） |

### 模型下载（国内镜像 + 禁用 xet）

```bash
mkdir -p ~/.cache/whisper-cpp
curl -fsL https://hf-mirror.com/ggerganov/whisper.cpp/resolve/main/ggml-medium.bin \
  -o ~/.cache/whisper-cpp/ggml-medium.bin
```

> 可选：faster-whisper（Python）+ large-v3-turbo，用于定点复查 whisper 漏掉的句子。同样需要 `HF_HUB_DISABLE_XET=1` + `HF_ENDPOINT=https://hf-mirror.com`。

## 安装

克隆到 WorkBuddy（或 Claude Code 等支持 SKILL.md 的 Agent）的 skills 目录：

```bash
git clone https://github.com/zhai66666-max/video-to-epub.git \
  ~/.workbuddy/skills/video-to-epub
```

## 流水线

```
视频 / 音频
   │  ffmpeg → 16kHz 单声道 wav（超长音频先切段）
   ▼
whisper-cli 转写                      逐字稿/xxx.txt（原样，无标点）
   │  完整性检查：音频总时长 vs 转写末段时间戳，尾部缺口 >8s 告警
   ▼
AI 润色                               润色稿/xxx.md
   │  繁体→简体 · 同音错字修正 · 加标点分段 · 话题切篇 · 概括标题
   │  引号统一「」 · 不通处回原音频定点复查
   ▼
组装 markdown（# 卷 + ## 篇）+ pandoc
   ▼
书名.epub（含目录、封面）
```

## 脚本说明

| 脚本 | 作用 |
|---|---|
| `scripts/transcribe_batch.sh` | 批量转音频 + whisper 转写，自动时长完整性检查，已存在 txt 跳过（可断点续跑） |
| `scripts/fix_quotes.py` | 把润色稿里的 ASCII 引号 `"` 批量换成中文「」（EPUB 渲染需要） |
| `scripts/build_epub.sh` | 合并润色稿 markdown 并用 pandoc 生成带目录的 EPUB |

`build_epub.sh` 的目录约定是 **一个 md = 一卷**：文件内 `#` 是卷标题、`##` 是篇标题，`--toc-depth 2` 才能把篇也收进目录。篇数少时用 2，篇数上百时用 1（只列卷）。

**封面**要自己再调一次 pandoc（脚本不带封面）：

```bash
pandoc 合并.md -o "书名.epub" --metadata title="书名" --metadata lang=zh-CN \
  --toc --toc-depth=2 --epub-chapter-level=1 --epub-cover-image=封面.png
```

## 关键坑

1. **简繁不是按模型一刀切。** 同一批文件里可能有的整篇繁体、有的整篇简体，甚至同一文件内混着来。必须逐篇用 `opencc.OpenCC('t2s')` 判断后转。
2. **年份会漂移。** 长文本转写里「2026」可能被写成「2016」，而且换模型也一样。判据优先级：① 片内时间线（"今年""去年"+ 事件本身的存在年限）② 把可疑句单独切出来用同模型 `-mc 0` 重跑 ③ small/medium 交叉验证。改了什么、依据是什么，要在成书里写明。
3. **同音字：非词必改，是词从原文。** 判据是"它是不是一个汉语词"，不是"读起来顺不顺"。两个模型给出同一读法，说明音频确实如此，别推翻。
4. **VAD 会漏整句。** 转写后必须做时长完整性检查，缺口用 faster-whisper large-v3-turbo 定点重转。
5. **中文文本禁用 ASCII `"`**，统一「」，否则 EPUB 渲染方向混乱。
6. **`/tmp` 会丢。** 实测跑着跑着整个 `/tmp/<项目>` 目录被清空、后台任务一并消失。中间产物放工作区或输出目录下的隐藏目录。
7. **切段合并要按核心窗口归属。** 重叠区不裁掉，同一句话会进两段，润色后变成两篇各写一遍。
8. **速度参考（Apple M5 / 10 核）**：medium + Metal 约 12x 实时（单进程）；small + Metal 约 7.7x；faster-whisper large-v3-turbo CPU int8 约 4.7x；ffmpeg 转 16kHz wav 约 20x 以上。

完整的实战细节（EPUB 内检五条、`nav.xhtml` 两个 `<nav>` 的目录统计陷阱、卷/篇分级组装、长音频切段脚本、`.appdata` 元数据解码等）见 [`SKILL.md`](SKILL.md)。

## License

MIT
