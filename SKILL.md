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

> ⚠️ **后台跑法（2026-09-28 踩坑）**：必须用 Bash 工具的 `run_in_background=true` 跑 `transcribe_batch.sh`。
> **千万不要用 `nohup ... &`** —— 沙箱会把 nohup 起的进程在父 shell 退出后回收，日志只留下第一个文件就「进程结束」，产出为 0。
> 正确写法：`PYBIN=<managed python> bash <脚本路径> ... 2>&1 | tee /tmp/v2e.log` 并设 `run_in_background=true`，之后用 TaskOutput 阻塞取结果。
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
> **批次 >20 篇时，把润色拆给多个后台子代理并行**（每批 2–5 篇），主 agent 只做汇总与打包。
> 否则逐篇读原文会把主 context 撑爆。子代理 prompt 必须自包含：给定输入路径、输出路径、章节标题与日期、
> 固定输出格式（`# 标题` + `> 来源：抖音 @作者 · 日期`）、以及同音错字修正清单。
> 要求子代理「写完用 ls -l 验证一次」——实测有子代理静默失败、返回空结果但文件没写出来的情况。

对每份 txt 逐个润色，输出到 `润色稿/<同名>.md`：
- 繁体 → 简体。**注意：同一批文件里可能简繁混杂**（medium 模型实测有的篇出简体、有的出繁体），必须逐篇判断再决定是否转。
  转换用 venv 里的 opencc（未装则 `pip install opencc-python-reimplemented -i https://pypi.tuna.tsinghua.edu.cn/simple`）：
  `python -c "import opencc,sys;c=opencc.OpenCC('t2s');s=open(sys.argv[1]).read();open(sys.argv[2],'w').write(c.convert(s))" in.txt /tmp/out.txt`
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

## 其他文本源 → EPUB（不限于音视频）

`build_epub.sh` 只做「一堆 md → 带目录的 EPUB」，**任何已经拿到文本的场景都能复用**（知乎回答合集、公众号导出、网页存档、PDF 提取稿等），不必装 Calibre、不要手写 OPF。

约定：把内容拆成若干 `xxx.md` 放进一个目录，**文件名决定顺序**（用 `00_`、`01_` 前缀），每卷用 `# 卷标题`、每篇用 `## 篇标题`。

```bash
bash ~/.workbuddy/skills/video-to-epub/scripts/build_epub.sh \
  "<md 目录>" "<输出目录>" "<书名>" [目录深度=1] [作者]
```

- **目录深度**：`1` 只列卷（篇数多时目录干净，如 885 篇合集）；`2` 连每篇都进目录（篇数少时导航更好）。默认 1。
- **作者**：第 5 个参数，写进 EPUB 的 `dc:creator`。
- 脚本会打印卷数/节数与 EPUB 体积，可快速判断有没有漏篇。

已跑通实例：知乎某作者 966 篇合集（885 回答 + 81 文章，125 万字 → 10 个一级卷，`--toc-depth=2`，1.9 MB）。要点：
- HTML 转 Markdown 用 `markdownify(html, heading_style="ATX", strip=["img","figure","video"])`；**先删 `<noscript>`**（知乎正文的图片会重复出现两份）。
- 正文里的 `<h2>` 会变成 `##`，会混进目录；想目录只到篇级就把正文标题降级为 `###`。
- **远程图片不要直接塞进 EPUB**（离线打不开、体积暴涨）：剥掉或下载压缩后再打包，并在前言里说明图未收录。

**封面：`build_epub.sh` 不支持，要自己再调一次 pandoc**（2026-10-21）。无封面的 EPUB 在 iPad「图书」里是个灰块，
只要目标是给人读的书就该加。做法是先 PIL 生成 1200×1800 封面（字体用 `/System/Library/Fonts/Supplemental/Songti.ttc`，
index 0=Black 1=Bold 3=Light 6=Regular，汉字封面用宋体比黑体有书感），然后用同样的参数重打一次、只多一个 `--epub-cover-image=封面.png`：

```bash
pandoc 合并.md -o "书名.epub" --metadata title="书名" --metadata lang=zh-CN --metadata author="作者" \
  --toc --toc-depth=2 --epub-chapter-level=1 --epub-cover-image=封面.png
```
重打后**必须重跑一次内检**——封面会多一个 `EPUB/text/cover.xhtml`，要确认目录条目数没被它污染。
另：`--epub-chapter-level` 在新版 pandoc 会报 deprecated 警告（改用 `--split-level`），但功能仍正常，可忽略；
`Could not load translations for zh-CN` 同理，不影响输出。

**交付前校验（务必做）**：`build_epub.sh` 会打印 `#`/`##` 计数，对着预期值核一遍（篇 + 前言小节）。再看单章体积是否失控（单卷 >1 MB 会让部分阅读器卡顿，必要时在 md 层把该卷再拆上下两卷）。逐条目读内容用 `python3 -c "import zipfile..."`，**不要用 `unzip -p`** —— 文件路径写错时它静默返回 0 字节，会误判成文件损坏。

**EPUB 内检五条**（Python + zipfile，30 秒跑完，比 epubcheck 省事）：① 所有 `.xhtml/.opf/.ncx` 用 `ET.fromstring` 过一遍良构；② `content.opf` 的 manifest href 相对 `EPUB/` 解析后都存在；③ nav.xhtml 里每条 `href` 的 `#锚点` 在目标文件里找得到 `id="…"`；④ 每章 `<h2>` 数 == 该卷篇数，**空标题必须为 0**；⑤ `<package version="3.0">`、书名/作者正确。注意锚点是挂在 `<section id="…">` 上而不是 `<h1>` 上，别按 `<h1 id=…>` 去查。

**校验目录嵌套时别再犯错（2026-10-06 实测踩坑）**：pandoc 的 `nav.xhtml` 里有**两个 `<nav>`** —— `epub:type="toc"`（可见目录）和 `epub:type="landmarks"`（含 "Title Page" / "Table of Contents"，**不是目录条目**）。两个坑：

1. 直接 `re.findall(r'<a[^>]*href=...')` 扫全文会把 landmarks 的条目也算进目录，凭空多出 2 条，看起来像"目录里混进了 Title Page"。
2. 用「遇 `<ol>` 深度 +1、遇 `</ol>` 减 1」自己算层级**会算错**：顶层 `<li>` 内含嵌套 `<ol>`，但它在嵌套 `<ol>` 闭合之后才闭合，深度跟踪会把所有条目压成同一层，得出"目录是平的"这种**错误结论**。

**正确做法**：先切出 `<nav epub:type="toc">…</nav>`，再用「顶层 `<li>` 后紧跟 `<ol>`」的配对关系判归属，逐卷数篇数：
```python
toc = re.search(r'<nav epub:type="toc".*?</nav>', nav, re.S).group(0)
for m in re.finditer(r'<li id="toc-li-\d+"><a[^>]*>(.*?)</a><ol class="toc">(.*?)</ol>', toc, re.S):
    vol  = re.sub(r'<[^>]+>', '', m.group(1)).strip()
    kids = re.findall(r'<a[^>]*>(.*?)</a>', m.group(2), re.S)
    print(vol, len(kids))          # 卷名 → 篇数，逐卷核对
```
配对后逐卷打印「卷名 + 篇数」，和你的分卷表一一对照；篇数总和必须等于总篇数。本次实测输出 `前言3 / 卷一5 / 卷二6 / 卷三4 / 卷四3 / 附记3`，5+6+4+3=18 与预期一致。

**顺带**：`opencc` 是判"简体稿里有没有繁体残留"的权威口径——`OpenCC('t2s').convert(s) != s` 即有残留。**不要用"我自己列一批繁体字去求交集"的办法**，简繁同形字（主／值／格／食…）会大量误报（本次 18 篇全部误报「有残留」，实为 0）。

## 在线视频下载（YouTube 等）先过网络这道关（2026-10-09 实测）

用户给的常是 YouTube 链接，但本环境代理（`$HTTPS_PROXY`）**不通 YouTube / Google / Invidious / Piped**，
`yt-dlp` 会报 `Unable to download API page: Tunnel connection failed: 502`。B 站通。

判断顺序：
1. `yt-dlp --dump-json <url>` 试一次，看是真被挡还是偶发；
2. 被挡就**找同源镜像**——YouTube 长访谈在 B 站常有完整搬运，用 WebSearch 或让用户直接给 BV 号（用户一般手上有）；
3. 拿到 BV 号后 `yt-dlp -f "30032+30232" --merge-output-format mp4`（B 站 480p + 音频，够转写也够归档），
   下载速度实测 40 MB/s，4 小时视频约 1 分 40 秒。
4. **B 站简介里常自带完整章节时间戳**，直接拿来切章（比听口播自报家门可靠得多）。

**超长音频（>2h）转写要切段并行**（2026-10-09 实测）：
4h22m 音频切成 4 段（每段 3948s、头尾各留 12s 重叠），4 个 whisper-cli medium 进程并行，**实耗 33 分钟**；
串行按 7.3x 实时估算约 36 分钟且不能并行润色，切段明显更划算。
合并时按 `offsets.from` 加回段起点 → 排序 → 与上一条终点比较去重叠。
段长控制在 4000s 以内，太长的段会让并行尾部的等待时间变长（最后一段晚 3 分钟结束）。

## 关键坑（务必遵守）
0. **build_epub.sh 的篇标题必须是 `##`，不是 `###`**（2026-10-09 踩坑）：约定是「一卷 = 一个 md，
   `# 卷` + `## 篇」，`--toc-depth 2` 才能把篇也收进目录。若自作主张把单篇的 `# 标题` 再降一级成 `###`，
   目录里就只剩卷、**篇全部消失**（实测 6/44 → 只有卷）。组装时**不要降级**；只有单篇 md 首行是 `#` 时才需要降成 `##`。
   判据：生成后看脚本打印的「节数（## 二级）」是否 ≈ 篇数。
1. **VAD 漏音**：whisper-cli 可能漏掉整句（本例漏了 3.5s 的内容）。转写后必须做时长完整性检查；用户反馈异常时用 large-v3-turbo 定点重转。
2. **引号**：中文文本禁用 ASCII `"`，统一「」；润色稿写好后再跑一次 fix_quotes.py 兜底。
3. **繁体**：**同一批文件里简繁混杂**，必须逐篇判断再转——2026-10-06 实测 medium：18 篇里第 1 篇整篇繁体、第 2/3 篇简体、杭州六小龙那篇又整篇繁体；甚至同一文件内也可能混。**不要按"模型=繁体/简体"的先验一刀切。** 转换用 venv 里的 opencc（未装则 `pip install opencc-python-reimplemented -i https://pypi.tuna.tsinghua.edu.cn/simple`）。
4. **模型下载**：HuggingFace 新 xet 协议会失败，必须 `HF_HUB_DISABLE_XET=1` + `HF_ENDPOINT=https://hf-mirror.com`。
5. **用户目录习惯**：用户可能中途清理/重建工作目录；写文件前先确认目录存在，中间产物放 /tmp。
6. **faster-whisper 备选**：若 whisper.cpp 不可用，faster-whisper（venv：`~/.workbuddy/binaries/python/envs/default`）需先装 av 等依赖（pip 清华源），且其 MPS 通常不可用、CPU 速度约 2-8x 实时，慢于 whisper.cpp Metal。
7. **前言里的「X 分钟 / X 万字」必须回算，不能凭印象写**（2026-09-29 新增）：这两个数是出版物里少见的可验证硬指标，写错等于自证没核。回算方法——
   - 时长：`ffprobe` 逐文件取 `format=duration` 求和再换算（不要用文件体积估）。
   - 字数：对润色稿 `len(re.sub(r'\s','', re.sub(r'[*`>|#-]','', 去掉标题行的正文)))` 求和。
   实测踩坑：某批 15 个视频写「3.6 万字」，实为 **4.0 万字**（差 4000 字）；时长 116 分钟是对的。
   注意口径：**「正文 X 万字」不含前言与篇目表**，全书总量要另行说明，两个数不要混用。

## 源目录若带元数据，先拿标题和作者（2026-09-28 新增）

抖音导出目录（如 `xxx/data/关注/<id>/视频`，其**上一级** `xxx/data/.appdata/` 里藏着每个视频的标题与作者 —— 注意 .appdata 在数据根目录，不在列表目录下；`db_*.js` 是
`window.dbv_base64="<base64 gzip>"` 格式，解码即得 JSON，比听口播自报家门可靠得多：

```python
import base64, gzip, json, re
def load(p):                      # p = .appdata/db_videos.js | db_texts.js | db_authors.js
    s = open(p).read()
    m = re.search(r'"([A-Za-z0-9+/=]+)"', s)
    return json.loads(gzip.decompress(base64.b64decode(m.group(1))).decode('utf-8'))
v, t, a = load('db_videos.js'), load('db_texts.js'), load('db_authors.js')
vid = '<文件名去掉.mp4>'          # 视频 id 就是文件名
title   = t[vid]                              # 完整文案/标题（含 #话题标签，需清洗）
author  = a[v[vid]['authorId']]['nicknames'][0]
```
拿到的标题常带 `#标签` 和换行，写章节标题时只取第一句、去掉标签。用文件名（纯数字 id）建 `vmap`，
润色时按表回填作者出处，每篇开头用 `> 来源：抖音 @作者`。

## 单集长视频（B 站 / YouTube 一条 20–60 分钟）的做法（2026-10-21 实测）

批量目录那套流程同样适用，但单集要按「一本书」而不是「一篇文稿」来搭骨架：

1. **先拿元数据，别急着转写**。`yt-dlp --dump-json` 一次就能拿到标题、UP 主、时长、播放量，以及
   **B 站简介/分P自带的章节时间戳**（`chapters[].start_time`）。这些时间戳比听口播自报家门可靠，
   直接拿来做书的章节边界——本批 9 章（0/234/356/740/960/1179/1378/1564/1715 秒）与文稿断句完全对得上。
2. **一条 30 分钟音频不用切段**：medium + Metal 单次跑完 4 分 05 秒（≈7.2x 实时），
   切段并行省下的时间还不够处理边界重叠。切段只在 >2h 时才有意义。
3. **切章用 JSON 里的 `offsets`**（毫秒），按章节起点把带时间戳的转写稿分组，比事后人工找段落靠谱。
4. **结构别硬凑卷**：只有 1 篇的「卷」很尴尬（本书第三部分原本只有《结束语》一篇）。
   单篇宁可做成独立的 `#` 章（与前言、附记同级），也不要为了凑数把两件事并进一卷。
5. **篇内要小标题时，组装必须整体降一级**：篇文件内用 `##`/`###` 分小节，组卷时把
   `#`→`##`、`##`→`###`。不降级就与「篇 = `##`」撞层，toc-depth 2 的目录会混成一锅。
   校验：`#` 数 = 章数，`##` 数 = 篇数 + 各章自带小节数，两者对得上再打包。
6. **数字必须回算再写附记**：本书「每年 2 万、10%、23 年 → 150 万」这类说法要真跑一遍
   （`v = v*1.1 + 20000` 迭代），实测第 23 年 159.1 万、本金 46 万、增值 113 万，
   与口播的「45 岁左右 150 万、本金 46 万、剩下超 100 万」全部吻合——这句话才有资格写进附记。

**`yt-dlp` 命令不在 PATH 时别急着重装**：managed venv 里常常已经有模块，
直接 `python -m yt_dlp ...` 就能用（用装了这个模块的那个解释器；WorkBuddy 环境里通常在托管 venv 下）。
实测就是这种情况：`command -v yt-dlp` 为空，但 `python -m yt_dlp --version` 能正常出版本号。

## 年份漂移：长文本里「2026」会被写成「2016」（2026-10-06 实测，必读）

whisper 的长文本转写存在**上下文漂移**：同一篇里能把 2025／2026 写对，却在另外三处把「2026 年」写成「2016 年」。
**不要因为"几个模型都这么写"就认定音频如此。**

判定顺序（从强到弱）：

1. **片内时间线**——文中的「今年」「去年」「上个月」，加上事件本身的存在年限。
   例：`7682415584994217226`（发布 2026-09）里「2016 年 6 月 DeepSeek 完成首轮外部融资」不可能是真的，DeepSeek 2023 年才成立；
   「截至 2016 年第一季度《黑神话：悟空》营收超 90 亿」同理，游戏 2024 年才发售。
2. **孤立片段重跑**——把可疑句切出来，**用同一个模型加 `-mc 0` 单跑**：
   ```bash
   ffmpeg -v error -y -ss <start> -t <len> -i in.mp4 -vn -ac 1 -ar 16000 -c:a pcm_s16le seg.wav
   whisper-cli -m ~/.cache/whisper-cpp/ggml-medium.bin -f seg.wav -l zh --no-prints -mc 0 -bs 5 -nt
   ```
   实测：全篇 medium 给「2016 年 6 月」，孤立片段 medium 给「2026 年 6 月」——长上下文把年份带偏了。
   ⚠️ 但孤立片段**在归属判断上更差**（另一例把「七十二万元」听成「700 万元」），所以孤立片段只用来**定夺年份/数字这一类单点**，不要用它的整句替换全篇结果。
3. **换模型交叉验证**——`ggml-small` 与 `ggml-medium` 对同一片段给出不同答案时，用第 1 条判据取舍。
   实测：medium 给「2016 年 4 月 17 日」，small 给「2026 年 4 月 17 日」，取 2026。

改完必须**在成书里写明改了什么、依据是什么**（本次写进《附记》），否则读者无法判断可信度。
反过来：**听不清的数字一律不改**（如某处「按年化〔?〕增长」），改成中性表述并列出，绝不猜。

## 同音字订正原则：「非词必改，是词从原文」（2026-10-06）

- 「一考」不是汉语词 → 唯一同音合理词是「艺考」（艺/一同音，上下文是艺术生就业）→ **改**。
- 「刚学」是真词 → **保留**，即使读起来别扭。
- 反例警告：**不要以"读起来不通顺"为理由自由改写。** 判据是"它是不是一个词"，不是"顺不顺"。
- 两个模型对同一处给出同一读法，说明音频确实如此，不要推翻。

## 并行润色：一边转写一边润色（2026-10-06）

转写串行、润色可并行，两边不必等——**whisper 还在跑第一个文件时，就能把已完成的 txt 派给子代理**。
本次 18 篇／180 分钟音频：转写 26 分钟、润色 3 波子代理并行，总墙钟约 37 分钟。
`transcribe_batch.sh` 本来就跳过已存在的 txt，天然支持这种交错。

**子代理静默失败仍会发生**：本次 7 个子代理里有 1 个**返回空字符串、一个文件都没写**。所以：
- **不要信子代理的汇报**，自己 `ls` 产物 + 逐条自检（存在、非空、ASCII 引号=0、首行 `#`、来源行在）。
- 缺文件就原样重派一遍，重跑即成功。
- prompt 里写死"若任何一项不满足，修好再回报"能降低频率，但**不能消除**这类失败。

**把规则抽成一个文件让子代理自己读**：在输出目录放一份 `.润色规则.md`（输出格式、简繁处理、引号规范、本批同音字表、"哪些数字能改哪些不能改"），
子代理 prompt 只写"先 Read 这个文件" + 本篇差异化的专名清单。比把规则重复塞进每个 prompt 更稳，也便于中途追加。

## 卷/篇两级目录：先组装「一卷一 md」（2026-10-06）

`build_epub.sh` 的约定是**一个 md = 一卷**（`# 卷` + `## 篇`）。要对 18 个单篇 md 出两级目录，
**不能直接 `--toc-depth=2`**——那样每篇自己就成了一卷。正确做法是写个组装脚本：

1. 读每篇润色稿，把首行 `# 标题` **降级为 `## 标题`**（第 3 行 `> 来源：…` 原样保留）；
2. 按卷拼成 `NN_卷名.md` 放进 /tmp 暂存目录，卷首加 `# 卷标题`；
3. 再跑 `bash build_epub.sh <暂存目录> <输出目录> <书名> 2 <作者>`。

前言（`00_前言.md`）与附记（`99_附记.md`）各占一个 `#`；TOC 深度 2 时会连带它们的 `##` 一起进目录，可接受。
组装完**断言「未纳入任何卷 = 空」**，防止漏篇。

## 动手前先查输出目录是否重名（2026-10-06）

默认输出 `~/Desktop/<项目名>逐字稿/` 很容易和上一批撞名——本次就撞上了：同名目录里躺着上一批（9/28–29）的
15 篇逐字稿、16 篇润色稿、一个 epub 和一份阅读版 html。**若沿用同名目录，新旧批次会被一起 `cat` 进同一本书。**
先 `ls` 确认；重名就换成更具体的名字（如 `收藏视频逐字稿`），并在交付时告知用户两批产物各在哪个目录。

## 额外产物：大字号 HTML 阅读版（2026-10-06）

EPUB 之外，用 `md-to-readable-html` 技能对 `合并.md` 再出一份阅读版（配合"iPad + 大字号"的阅读习惯）：

```bash
PY="${PYBIN:-python3}"   # 换成装了依赖的那个解释器，例如托管 venv 下的 python
$PY ~/.workbuddy/skills/md-to-readable-html/md2read.py 合并.md "书名-阅读版.html" \
  --title "书名" --kicker "来源 · N 篇 · 年份" --toc-depth 1-2 --keep-h1
```

书稿**必须带 `--keep-h1`**（否则「前言」被当页头剥掉、章节残缺）；`--toc-depth 1-2` 得到「卷→篇」两级目录（本次 30 条）。
量测两个断点（期望 820px→17px/false、393px→16.5px/false）：

```bash
agent-browser --session md2read eval "JSON.stringify({fs:getComputedStyle(document.body).fontSize,over:document.documentElement.scrollWidth>innerWidth})"
```
截完/量完先 `get url` 确认页面没串，再下结论。

## 速度参考（Apple M5，10 核）
- whisper.cpp ggml-small + Metal：约 7.7x 实时（180 分钟音频约 12 分钟）
- **whisper.cpp ggml-medium + Metal：约 7.3x 实时**（实测 125s 音频 17.1s；中文口播准确率显著优于 small，
  财经/科普类专业术语差别很大。**只要不是几百小时的量，默认直接用 medium**）
- faster-whisper large-v3-turbo CPU int8：约 4.7x 实时
- ffmpeg 转 16kHz wav：约 20x 实时
- **整批实测（2026-10-06）**：medium + Metal，18 条 × 180.2 分钟，转写段 20:03→20:33 约 **30 分钟（≈6.0x 实时）**，
  含 ffmpeg 抽音，且期间并发跑了 7 个润色子代理与若干定点复查，属受干扰的下限；空载时更接近上面的 7.3x。

## 超长合集（6h+）实测：并行不加速，`/tmp` 会丢（2026-10-25）

一次 17.5 小时的活（6h43m + 10h49m 两段中文讲座）跑下来，四条硬结论：

1. **并行转写不加速**。单进程 whisper-cli medium 约 12x 实时；开到 3 路并发后每路掉到 3.5x，合计仅约 10.5x——Metal 单 GPU 在单进程时基本就吃满了。加进程换来的是内存压力，不是速度。
2. **16 GB 内存机器上 3 路是上限**。每进程 wired 常驻约 2.25 GB（GPU 缓冲区不可换出），4 路会把 wired 顶到 11.6 GB、压缩内存 3.3 GB，有被系统 jetsam 杀进程的风险。开跑前先看 `vm_stat` 的 wired 页数。
3. **中间产物千万不要放 `/tmp`**。实测转写跑了十几分钟后整个 `/tmp/<项目>` 目录被系统清空、后台任务一并消失，产出归零。放工作区或输出目录下的隐藏目录（`<项目>/.work/`）。
4. **切段并行必须按「核心窗口」归属**。每段前后各留 15s 重叠供上下文，但合并时只保留「句中点落在本段核心窗口内」的句子，否则重叠区会把同一句话写进相邻两段。交给 LLM 润色前也要先按这个规则把 txt 裁干净，不然相邻两篇会各渲染一遍同一段内容，最后还得回头做去重。

另外一条省事的：**转写稿第一句往往就自带出处**（"大家好，这里是 XX 播客，我是 YY"），据此确认节目名与系列名，比事后猜书名可靠得多。

### 长音频切段的最小脚本

```bash
SEGLEN=3600; OV=15   # 每段 1 小时，前后各留 15s
# manifest: name  ff_start  ff_len  core_start  core_end
python3 - "$DUR" > manifest.txt <<'PY'
import sys
dur = float(sys.argv[1]); i = start = 0
while start < dur - 1:
    ce = min(start + 3600, dur)
    fs = max(0.0, start - 15)
    print(f"s{i:03d}\t{fs:.1f}\t{min(ce+15,dur)-fs:.1f}\t{start:.1f}\t{ce:.1f}")
    i += 1; start += 3600
PY
```

每段：`ffmpeg -ss $ff_start -t $ff_len -i in.m4a -vn -ac 1 -ar 16000 -c:a pcm_s16le seg.wav`，再喂 whisper-cli；转完删 wav 省磁盘（1 小时 16kHz 单声道约 115 MB）。
