# 小学英语点读

## 应用介绍与试用

![小学英语点读 v1.7.1 宣传海报](docs/promo/v1.7.1-poster-r2.png)

目前支持湘少版三年级上册。点读与对话连读、六档语速、中文释义、离线跟读及原音／自录音对比试听，帮助孩子听英语、练开口。海报中的手机界面为功能示意，跟读匹配分依据识别文本与完整度。

[直接下载 Android ARM64 版 v1.7.1（码云，无需登录）](https://gitee.com/wildfire666/xiangshao-english-reader/releases/download/v1.7.1/xiangshao-english-reader-v1.7.1-build9-arm64-v8a.apk) · [GitHub 发布页](https://github.com/wildfirelh/xiangshao-english-reader/releases/tag/v1.7.1)

Flutter 多教材点读应用。主入口为“书本 / 我的”双 Tab，采用悬浮胶囊导航；书架根据本地教材清单显示封面、年级筛选和独立阅读进度，点击后才加载该教材的阅读器。支持单句点读、整页连读、顺序连读、暂停／继续、单元目录、六档语速、通知降音、应用内更新和本地离线英语跟读。

历史版本 `v1.5.0` 发布多教材架构与主界面重构，应用正式更名为“小学英语点读”。

`v1.7.1` 提供本地离线英语跟读，并通过模型与原生库的无损压缩适配码云附件上限。长按句子或点击麦克风进入录音，显示实时声浪、逐词绿／黄／红反馈及 0–100 跟读匹配分，支持课本原音／自录音 AB 试听和重练。评分依据识别文本与完整度，不能判断音素、重音或口音。完整更新见 [CHANGELOG.md](CHANGELOG.md)。

湘少版三上资源包含 PDF 第 8–72 页（65 页，含复习、评价页），以及高清图片、英文热区、中文译文和单句／气泡离线 MP3。湘少版三下已列入书架，标记为“准备中”。

## 多教材扩展

`assets/textbooks/catalog.json` 管理教材元数据。`TextbookCatalogRepository` 先读取小型清单，打开已上线教材时才加载并缓存完整 `book.json`；加载失败可重试。目录、封面、正文路径和页面范围都从清单读取，主入口无需按教材 ID 添加分支。

| 字段 | 用途 |
| --- | --- |
| `id`、`title`、`grade`、`term` | 教材身份、书架标题、年级与上下册 |
| `cover`、`ready`、`totalUnits` | 本地封面路径、是否上线、单元数量 |
| `manifestPath` | 可选正文路径；默认为 `assets/textbooks/{id}/book.json` |
| `firstPageIndex`、`pageCount` | 可选正文范围，用于加载正文前显示阅读位置百分比 |
| `units` | 单元 `number`、`title`、`startPage`；页码对应正文物理 PDF 页码 |

新增教材时，将正文、图片和音频放入对应 assets 目录，在 `pubspec.yaml` 声明该教材及图片／音频目录，再向清单添加元数据并设置 `ready: true`。尚未准备好的教材仅添加 `ready: false` 元数据，不要求正文资源。已读取正文后，书架以实际页面列表核对进度；不同教材沿用 `last_read_page_index.<bookId>` 独立保存，返回书架会刷新进度与语速。阅读器继续支持旧目录调用方式，新入口明确传入清单中的单元数据。

“我的”使用本地学习记录：音频在原生播放器实际开始后才累计当天和书籍，同一天／同一本去重；打开书籍、翻页或资源加载失败不增加计数。统计与护眼开关保存为 `learning_preferences_v1`，语速沿用现有 `playback_speed`。开启护眼提醒后，在阅读器前台每 20 分钟提示休息，后台与退出阅读器会取消计时。关于页读取实际安装版本，并分别说明应用代码与教材资源的版权范围。

## 下载与开源

- [码云：直接下载 ARM64 APK（无需登录）](https://gitee.com/wildfire666/xiangshao-english-reader/releases/download/v1.7.1/xiangshao-english-reader-v1.7.1-build9-arm64-v8a.apk)
- [GitHub：下载 APK 与查看版本更新](https://github.com/wildfirelh/xiangshao-english-reader/releases/tag/v1.7.1)
- [AtomGit：历史版本下载](https://gitcode.com/gcw_rw0AAl7X/xiangshao-english-reader/releases)

后续版本在 GitHub 和码云发布，每个平台使用一个公开仓库，同时提供源码与带版本号的安装包。AtomGit 保留历史版本，停止新增发布。原创应用代码采用 [MIT 许可证](LICENSE)，教材资源的许可范围见 [NOTICE.md](NOTICE.md)。

应用仅在用户明确要求发布时上传正式新版本。日常更新先完成开发、测试并汇总待发布内容；源码提交或同步不自动触发 APK 发布。

当前版本为 `1.7.1+9`，提供内置模型的离线跟读练习、动态录音权限、词级匹配反馈和 AB 试听，新增模型及原生库无损打包，保留三种播放模式、暂停／继续与六档语速。已有正式版可直接覆盖安装，保留教材阅读进度和语速偏好；`1.4.0` 及以后版本可使用“检查更新”升级。更新入口位于“我的”，详见 [版本说明](releases/v1.7.1.md)。

单句资源包含 65 张正文图片、1,185 个点读条目和 MP3，722 条不同英文内容的翻译全部成功，清单没有空译文。单句音频通过豆包语音合成模型 2.0 的 V3 HTTP SSE API 生成，采用下表指定的六类固定角色音色；779 组不同的文本与音色参数复用于 1,185 个点读音频文件。旧音频已移至本地 `.asset-cache/previous-audio/`，不参与 Flutter 打包。六类角色的联网短句试音保留在 `build/tts-check/`。

`1.3.0+4` 新增整气泡音频轨道：全书 65 页包含 1,137 个气泡，其中 43 个包含多个小句；共 1,228 个 MP3，包括原有 1,185 个单句文件和 43 个多句气泡文件。整段音频新增 42 组合成配置，另 1 组复用已有缓存；仅有一个小句的气泡直接引用对应单句文件。全书音频已逐一核对缓存 SHA-256，清单没有缺失译文，原有单句的文字、译文、热区和音频路径保持稳定。

## 从 PDF 构建资源

在本项目根目录安装依赖并预览场景与角色计划（Windows 使用 `py -3.13`；其他环境可改成 `python`）：

```powershell
py -3.13 -m pip install -r tools/requirements.txt
py -3.13 tools/build_textbook_assets.py assets/textbook.pdf --plan-only
```

`--plan-only` 不要求凭据，也不请求翻译或语音接口；结果位于 `.asset-cache/dialogue-plan.json`。正常构建会在写入教材资产前验证凭据和当前所需音色，缺少配置时提前报错。

项目根目录的 `.env.volc` 为本机私有配置，已加入 `.gitignore`；可提交的 `.env.volc.example` 提供填写模板。脚本使用 `python-dotenv` 自动加载 `.env.volc`，**当前进程环境变量优先**，其后读取私有配置和脚本顶部默认值。本机已安装 `python-dotenv 1.2.4`，新环境通过上方 `tools/requirements.txt` 安装即可。

推荐填写新版豆包语音控制台的 `VOLC_API_KEY`；旧版账户兼容 `VOLC_APPID` + `VOLC_TOKEN`，其中 Token 是该语音应用的 Access Token。V3 不使用 `VOLC_CLUSTER`。API 固定为 `https://openspeech.bytedance.com/api/v3/tts/unidirectional/sse`，资源 ID 为 `seed-tts-2.0`。六类 `VOLC_VOICE_*` 使用账户已授权、支持英语的 **豆包 2.0 音色 ID（speaker）**。公开模板保留凭据占位，音色已写入本项目选定的默认值，实际运行可由本地配置或进程环境覆盖。可在 [API Key 管理](https://console.volcengine.com/speech/new/setting/apikeys) 获取凭据，在 [官方音色列表](https://www.volcengine.com/docs/6561/1257544?lang=zh#%E8%B1%86%E5%8C%85%E8%AF%AD%E9%9F%B3%E5%90%88%E6%88%90%E6%A8%A1%E5%9E%8B2-0-%E9%9F%B3%E8%89%B2%E5%88%97%E8%A1%A8) 与控制台音色库核对授权和英语支持。

本机 `.env.volc` 已填写 AppID / Access Token，下列用户指定的六类音色已全部通过当前账户的英文短句联网验证，公开模板同步保存这些音色 ID。V3 不需要 Secret Key。

| 类别 | speaker ID |
| --- | --- |
| 女学生 | `en_female_stokie_uranus_bigtts` |
| 男学生 | `ICL_uranus_en_male_kevin_mccallister_tob` |
| Dino | `en_male_michael-mouse_uranus_bigtts` |
| 女教师 | `en_female_wenrouzhishijieshuonv_uranus_bigtts` |
| 男教师 | `en_male_josh_coery_uranus_bigtts` |
| 旁白 | `en_female_authoritative-british_uranus_bigtts` |

试音文件 `build/tts-check/{role}.mp3` 已更新为当前映射；Dino 继续使用语速 `1.06` 和音调 `3`。其他账户需验证各音色的授权。

填写 `.env.volc` 后，先进行纯本地检查，再单独合成一句 Dino 测试音频：

```powershell
# 只检查凭据格式、六类音色和合成参数，不发起网络请求
py -3.13 tools/build_textbook_assets.py --check-tts-config
# 仅检查本次使用的 dino 配置；保存至 build/tts-check/dino.mp3
py -3.13 tools/build_textbook_assets.py --tts-test-text "Hello, my name is Dino." --tts-test-role dino
# 已有相同指纹缓存时，可加 --refresh-audio 强制重新请求接口
py -3.13 tools/build_textbook_assets.py --tts-test-text "Hello, my name is Dino." --tts-test-role dino --refresh-audio
```

本地检查只能验证配置完整性与参数范围；凭据、音色的实际授权与服务可用性需联网合成确认。真实凭据应只保存在 `.env.volc` 或本机环境变量中，**不要提交密钥到仓库**。

填写授权的英语音色和凭据后，先在独立目录验证前四页，再生成正文全书：

```powershell
# 验证 Unit 1 前四页；预览资源不会替换正式教材清单
py -3.13 tools/build_textbook_assets.py assets/textbook.pdf --pages 8-11 --output assets/textbooks/xiangshao_3_1_preview
# 正文全书：PDF 第 8–72 页，复用已存在的高清图片
py -3.13 tools/build_textbook_assets.py assets/textbook.pdf --start-page 8 --end-page 72 --reuse-images
# 不传范围时同样默认正文第 8–72 页
py -3.13 tools/build_textbook_assets.py assets/textbook.pdf --reuse-images
```

当目标目录已有相同 `bookId` 的清单时，构建只更新本次选择的页面，并合并保留其他页的图片、译文和音频引用；例如在正式目录运行 `--pages 8-11` 不会删掉其余正文页。没有旧清单或 `bookId` 不同时，生成的清单只包含所选范围。上方独立预览目录适合检查资源；如需让预览进入 Flutter，需要在 `pubspec.yaml` 中声明预览目录并切换读取路径。

脚本默认输出 `assets/textbooks/xiangshao_3_1/`，图片为 200 DPI WebP（quality=85，保留像素尺寸），人物使用配置的固定 `speaker`。可用 `--image-format png` 导出 PNG。另从 PDF 第 1 页提取正面封面为 `images/cover.webp`；当前 PDF 的封面是横向展开图，因此取右侧正面。不传 PDF 路径时依次查找项目根目录的 `textbook.pdf`、`assets/textbook.pdf`。`asyncio` 已内置于 Python，无需额外安装；HTTP 合成使用 `requests`，不需要 Edge-TTS、WebSocket 协议库或额外 SSE SDK。

- `--pages 8-11,13` 可指定不连续页码，与 `--start-page` / `--end-page` 互斥。使用 PDF 的物理页码，从 1 开始；`pageIndex` 也保存物理页码。同一教材的局部生成会按页码合并旧清单并排序，只有合并后不再引用的旧音频才移至 `.asset-cache/previous-audio/` 备份，不移动保留页的单句或气泡音频。
- 英文按标点分句，结合对齐和间距合并换行；过滤无英文字母的内容。数字页码不会生成音频，英文标题、词汇和字母仍可点读。旋转页的热区会转换到渲染图片坐标系。
- 在单句热区之外，根据 PDF 文本块、行距与列对齐聚合同一气泡，支持人工校对气泡归属；当前结合已有场景、人物标注聚类，不同场景或说话人不合并。气泡内文本按阅读顺序合成一次完整音频，单句音频仍独立保留。一句的气泡直接复用对应单句 MP3，多句气泡通过相同的参数指纹机制缓存整段音频。
- 这是基于文本层的几何提取，不包含 OCR。扫描页会输出图片并给出无英文文本的警告；若所选页面全部无英文，构建失败并保留旧清单。图片中没有文本层的文字不会自动变成热区。曲谱、复杂表格和特殊排版需人工校对。
- 火山引擎**构建时需要联网**，生成的 MP3 可在 App 中离线播放。向 V3 `/api/v3/tts/unidirectional/sse` 一次性发送句子，接收 SSE 音频包，逐包 Base64 解码并拼接为 **24kHz / 64kbps MP3**。仅收到明确的成功结束码 `20000000` 且音频有效后，才写入成功缓存；HTTP 200、收到部分音频或连接自行关闭均不能表示合成完成。默认最多 3 个并发请求、每条最多尝试 3 次、HTTP 超时 60 秒；网络故障、并发限流和指定服务异常会重试，鉴权或参数错误立即失败。支持 `--proxy http://127.0.0.1:端口`。
- 音频按文字、`speaker`、语速、音调、接口、模型资源 ID 和编码参数的 SHA-256 指纹缓存到 `.asset-cache/speech-volc-http-v3-doubao2/`，并校验 MP3 内容哈希；同一合成配置只请求一次。该缓存与 V1 和旧引擎隔离，不会把已有旧音频当作豆包 2.0 合成结果。修改声音参数会自动生成新资源，`--refresh-audio` 可强制重新下载。音频路径包含指纹，缓存与清单不保存实际凭据。
- 使用 `deep-translator` 自动翻译英文为简体中文，默认 MyMemory，可用 `--translator google` 切换 Google。两个服务均需联网且可能限流；译文是机器翻译，教材人名、曲谱片段及多义词仍需校对。
- 翻译默认 2 个并发，每次请求有 20 秒连接/读取超时，重试 3 次；可用 `--translation-concurrency`、`--translation-timeout`、`--translation-delay` 调整。同一句英文只请求一次，成功结果立即缓存到 `.asset-cache/*.en-zh-CN.json`，已有 `book.json` 中的译文也会复用。`--refresh-translations` 强制重新翻译。
- 翻译失败写入空字符串 `""`，不阻断音频、图片及清单生成。失败结果不缓存，下次运行会继续补齐；终端会报告缺失数量，App 显示“暂无释义”。字母和部分专有名词可能由翻译服务原样返回。
- 临时音频和清单在 `.asset-cache/staging/` 内生成，避免 Flutter 打包临时文件；全部音频成功才发布 `book.json`。音频失败返回非零状态，可重跑继续，成功的翻译缓存会保留。
- 如用 `--output` 指定其他路径，必须位于本项目 `assets/` 内，并把对应目录加入 `pubspec.yaml`。

新增资源后重新运行 `flutter run` 或重新构建 APK，使 Flutter 重新打包资源。

```powershell
py -3.13 -m unittest tools.test_build_textbook_assets -v
```

### 场景顺序与人物声线

先识别漫画中的连续数字序号，保证一个场景读完才进入下一场景。整页连读以气泡为单位，在同一场景内按气泡从上到下、结合列归属排序，气泡内按原文阅读顺序合并为完整段落。单句清单保留既有“提问／发起对话 → 应答 → 致谢告别”的语境校对。曲谱重复数字和练习编号不会直接作为漫画序号；句子 ID、文字和热区保持稳定。

`tools/textbook_context/xiangshao_3_1.json` 保存本版教材的 367 条已核对角色标注，以及无序号插图和跨框气泡的场景补充。标注受 PDF 哈希及原句、坐标校验保护，不会套用到其他版本。自动识别支持说话人标签、自我介绍和明确的两人场景；无法确认的词汇、标题与练习使用旁白，称呼中的人名不会直接被当成说话人。

| 角色 | `VOICE_MAP` 键 | 音色环境变量 |
| --- | --- | --- |
| Lingling、Anne、Lulu 等女孩 | `girl` | `VOLC_VOICE_GIRL` |
| Peter、Mingming、Dongdong、Tim 等男孩 | `boy` | `VOLC_VOICE_BOY` |
| Miss Li 等女教师 | `teacher_female` | `VOLC_VOICE_TEACHER_F` |
| Mr Zhang、Mr Yang 等男教师 | `teacher_male` | `VOLC_VOICE_TEACHER_M` |
| Dino | `dino` | `VOLC_VOICE_DINO` |
| 标题、题头指令、旁白与兜底 | `narrator` | `VOLC_VOICE_NARRATOR` |

各环境变量或 `VOICE_MAP` 常量应填入已授权、支持英语的豆包 2.0 `speaker` ID。请求通过 JSON 字符串 `req_params.additions` 传入 `explicit_language=en`；音频格式、采样率和码率位于 `req_params.audio_params`。脚本保留已校对的说话人与场景归属。`--voice` 只覆盖旁白 `speaker`，不改变人物配置。

Dino 使用独立 `speaker`，默认语速 `1.06`、音调 `3`；其他角色默认语速 `1.0`、音调 `0`，可在顶部 `ROLE_SPEED_MAP` 和 `ROLE_PITCH_MAP` 调整。音调通过 `additions.post_process.pitch` 设置，整数范围 `[-12,12]`，正值升调；**该参数不是 Hz**，不能把旧引擎的 `+15Hz` 直接填入。语速转换为 V3 的 `speech_rate`，Dino 为 `6`、其他角色为 `0`。这里使用普通文本和后处理参数合成；接口说明见 [官方 V3 HTTP/SSE 文档](https://docs.volcengine.com/docs/DoubaoVoice/HTTPChunkedSSEUnidirectionalStreaming-V3?lang=zh) 和 [新版 HTTP 参数文档](https://docs.volcengine.com/docs/DoubaoVoice/unidirectional-streaming-text-to-speech-http?lang=zh)。

```powershell
# 无凭据也可生成校对计划，不修改教材资产
py -3.13 tools/build_textbook_assets.py assets/textbook.pdf --plan-only
# 填写凭据与六类音色后，复用图片生成全书豆包音频
py -3.13 tools/build_textbook_assets.py assets/textbook.pdf --reuse-images --start-page 8 --end-page 72
# 包括角色识别、排序、缓存和真实教材回归测试
py -3.13 -m unittest discover -s tools -p 'test_*.py' -v
```

校对计划位于 `.asset-cache/dialogue-plan.json`。合成失败时保留旧清单和已完成的指纹缓存；直接重跑会跳过已缓存音频并重新请求失败句子，无需加 `--refresh-audio`。SSE 连接不提供断点续传。

## 目录与阅读进度

### 首页书架与竖屏

应用初始路由 `/` 显示书架、教材封面和 Unit 1–10。点击“继续学习”恢复该教材上次保存的页码；点击单元则优先打开该单元起始页并保存进度。阅读页返回按钮回到书架并刷新阅读位置；返回时停止音频。封面缺失时显示书本图标。

Flutter 启动时请求 `portraitUp`，Android MainActivity 同时声明 `portrait`。Android 16 起，面向 API 36 的应用在宽度至少 600dp 的设备上可能由系统忽略方向限制，参见 [Flutter 方向 API 文档](https://api.flutter.dev/flutter/services/SystemChrome/setPreferredOrientations.html)。

### 图片压缩

```powershell
py -3.13 tools/compress_images_to_webp.py
py -3.13 -m unittest tools.test_compress_images_to_webp -v
```

脚本将教材图片目录内的 PNG 转为 WebP（quality=85），验证格式和尺寸后同步更新清单，再删除原 PNG。仅修改 `imagePath`，保留热区、译文和音频路径；可重复运行。清单备份和体积报告位于 `.asset-cache/webp-conversion/`，不随 App 打包。

本次 65 张正文图片从 **79.19 MiB** 压缩至 **10.28 MiB**，缩减 **87.02%**；另有首页封面。后续资源构建默认直接生成 WebP。

### 点读控制

- 点按底栏模式按钮打开三种模式的单选列表。**单句点读**独立朗读选中的小句，读完即停；**整页连读**从当前页首个气泡起读，气泡内使用完整段落音频并高亮整个气泡，读至页尾停止。
- **顺序连读**未播放时选中仅进入待命，并提示“请点击任意文本，从此处开始顺序连读”。点中精确句子后从该句独立音频开始，遵循气泡／子句的教材次序继续，页尾平滑翻至下一有英文的页面，至全书末尾结束；再次点读立即切换起点并保留顺序模式。
- 整页连读期间手动点读会取消旧队列并切回单句；气泡两行之间的空白选择该气泡首个小句，精确句子热区优先。连读播放／加载期间可暂停，保留高亮；继续播放从当前已暂停音频的位置恢复，加载或跨页中的暂停也不会产生迟到的播放。
- 手动左右滑动在手指开始拖动时就停止调度并清除高亮，取消尚未完成的音频加载和自动翻页，底栏同步显示停止状态；上一页／下一页或目录跳转也会停止。系统顺序连读自动翻页保持队列，用户介入则取消自动流程。
- 倍速按钮点按打开 `0.5x / 0.8x / 1.0x / 1.2x / 1.5x / 2.0x` 单选列表，每档显示用途及当前勾选。选择立即调整当前及后续音频，不重新生成 MP3；语速保存到本地，下次打开阅读器恢复。列表支持大字号滚动与系统减少动画设置。
- 高亮使用 22% 不透明度的黄色荧光笔底色、4dp 圆角和 180ms 淡入，完全移除描边；系统启用“减少动态效果”时取消动画。窄屏和大字号下控制栏自动换行。

### 人名译文校正

```powershell
py -3.13 tools/patch_translations.py --dry-run
py -3.13 tools/patch_translations.py
py -3.13 -m unittest tools.test_patch_translations tools.test_build_textbook_assets -v
```

规则统一玲玲、明明、安妮、彼得、东东、蒂姆、迪诺、李老师、张老师和杨老师。英文名按独立单词匹配（兼容紧邻中文和 `Mr.` 写法），已知中文误译需匹配英文原句；漏译修正同时核对完整原句和原译文，避免把普通“恐龙”“添”等词误改成人名。脚本仅修改 `translation`，再次执行无重复修改。构建脚本发布译文前也会应用相同规则，旧翻译缓存不会覆盖校正结果。

本次扫描 1,185 条，修改 43 条。原始清单按内容哈希备份到 `.asset-cache/translation-patches/`，明细为其中的 `latest-report.json`。

阅读器右上角“目录”打开侧栏，选择单元即可直接跳转。目录使用当前 PDF 核对过的页码，缺少起始页资源时对应条目不可选。

| 单元 | 标题 | PDF 起始页 | 教材印刷页 |
| --- | --- | --- | --- |
| 1 | Hello! | 8 | 1 |
| 2 | What's your name? | 13 | 6 |
| 3 | How old are you? | 18 | 11 |
| 4 | This is my family | 28 | 21 |
| 5 | Is this your pen? | 33 | 26 |
| 6 | Touch your head | 38 | 31 |
| 7 | What colour is it? | 48 | 41 |
| 8 | What's this? | 53 | 46 |
| 9 | I like apples | 58 | 51 |
| 10 | Happy birthday! | 63 | 56 |

翻页、上一页/下一页、目录跳转均会停止音频并清除高亮，通过 `SharedPreferencesAsync` 保存当前物理 PDF 页码。键为 `last_read_page_index.<bookId>`，各教材独立保存。写入按顺序执行，防止快速翻页覆盖新进度；重新打开时等待进度读取后显示对应页面。若保存的页码不在当前资源中或读取失败，则显示当前资源第一页。AppBar 的“第 N / M 页”表示当前载入资源的顺序，目录标注教材印刷页码。

## 教材资源

将教材 JSON 放在 `assets/textbooks/xiangshao_3_1/`，图片放在 `images/`，音频放在 `audios/`。`imagePath` 和 `audioPath` 必须是完整的 Flutter Asset 路径，例如 `assets/textbooks/xiangshao_3_1/audios/p1_s1.mp3`。

```json
{
  "bookId": "xiangshao_3_1",
  "title": "湘少版英语三年级上册",
  "pages": [
    {
      "pageIndex": 8,
      "imagePath": "assets/textbooks/xiangshao_3_1/images/page_008.webp",
      "sentences": [
        {
          "id": "p1_s1",
          "bubbleId": "p1_b1",
          "text": "Hello!",
          "translation": "你好！",
          "audioPath": "assets/textbooks/xiangshao_3_1/audios/p1_s1.mp3",
          "rect": { "left": 0.1, "top": 0.2, "right": 0.5, "bottom": 0.3 }
        },
        {
          "id": "p1_s2",
          "bubbleId": "p1_b1",
          "text": "My name is Lingling.",
          "translation": "我叫玲玲。",
          "audioPath": "assets/textbooks/xiangshao_3_1/audios/p1_s2.mp3",
          "rect": { "left": 0.1, "top": 0.32, "right": 0.7, "bottom": 0.4 }
        }
      ],
      "bubbles": [
        {
          "id": "p1_b1",
          "text": "Hello! My name is Lingling.",
          "translation": "你好！我叫玲玲。",
          "audioPath": "assets/textbooks/xiangshao_3_1/audios/p1_b1.mp3",
          "rect": { "left": 0.1, "top": 0.2, "right": 0.7, "bottom": 0.4 },
          "sentenceIds": ["p1_s1", "p1_s2"]
        }
      ]
    }
  ]
}
```

`rect` 的四个值是相对于原始页面图片宽高的 0–1 坐标；左右、上下边界必须有序。`translation` 可省略。`sentences` 保存独立点读条目，`bubbles` 保存整段音频与有序的 `sentenceIds` 引用；子句通过可选 `bubbleId` 标注归属。旧清单没有 `bubbles` 时，每个单句作为一个兼容气泡读取，不要求先重新生成资源。

阅读页会按图片原始比例居中显示，并把热区映射到实际图片区域。图片缺失时显示灰色页面，音频缺失时点按会显示提示，页面仍可操作。底部栏提供三种播放模式、暂停／继续、倍速列表、释义开关和跟读评测占位入口。

## 使用

```dart
final book = await TextbookRepository().loadBookFromAsset(
  'assets/textbooks/xiangshao_3_1/book.json',
);

final audio = AudioPlayerService();
// 整页连读：使用完整气泡音频，可指定 targetBubble 从选中的气泡开始。
await audio.playPage(page: book.pages.first);
// 顺序连读：按气泡／子句次序，从指定小句开始；跨页由阅读器处理。
await audio.playSequential(
  page: book.pages.first,
  targetSentence: book.pages.first.sentences.first,
);
// 暂停与继续保持同一音频的播放位置。
await audio.pause();
await audio.resume();
// 手动单句点读：立即打断整页连读，并自动切换为 PlayMode.single。
await audio.playSentence(
  pageSentences: book.pages.first.sentences,
  targetSentence: book.pages.first.sentences.first,
);
// 页面销毁时调用 audio.dispose()。
```

调用前需导入 `repositories/textbook_repository.dart` 和 `services/audio_player_service.dart`。界面可以监听 `AudioPlayerService` 的 `ChangeNotifier`，读取 `currentSentenceId`、`currentBubbleId`、`isPlaying`、`canResume`、`isLoading` 和 `currentMode`：单句／顺序播放高亮小句，整页模式高亮完整气泡。`MockSpeechEvaluator` 只返回占位结果，不进行录音或真实评分。

## 验证

```sh
flutter pub get
flutter analyze
flutter test
```

已发布 `v1.5.0` 验证：148 项 Python 测试、229 项 Flutter 测试通过，`flutter analyze` 无问题；覆盖多教材清单、按需加载、独立进度、悬浮导航、学习统计、设置持久化及原有播放／更新流程。全书保留 65 页正文、1,185 个单句与 1,137 个气泡。

`v1.6.0` 验证：264 项 Flutter 测试、148 项 Python 测试通过，`flutter analyze` 无问题；三个 ABI 正式 APK 的版本、架构和原签名核对通过，教材清单、1,228 个 MP3 与 66 张 WebP 均与源文件逐字节一致，私有配置与 TTS 凭据未打包。Android API 36 模拟器验证选点待命、精确起句、暂停／继续、两种连读下手动划页停止，以及列表勾选反馈、深色模式与两倍字体，运行日志未发现异常。本机没有连接实体手机，本版尚未进行真机检查。

`v1.7.0` 验证：351 项 Flutter 测试、148 项 Python 测试通过，`flutter analyze` 无问题；Android API 36 断网模拟器完成动态权限拒绝／重试授权、真实录音、15 秒保护、词级漏读反馈与 AB 试听。真实流式识别器短句五次停止到评分为 17.477–29.065ms，首次模型加载约 2.95 秒，均在独立 isolate 进行。未连接实体手机，不据此承诺所有机型或录音环境的速度与识别准确率。

`v1.7.1` 补丁验证：367 项 Flutter 测试、151 项 Python 测试通过，`flutter analyze` 无问题；三个 ABI 正式 APK 构建完成，均小于 100 MiB，码云上传接受情况以实际验证为准。新补丁增加首次模型解压，首次准备耗时需独立测量，不能沿用 v1.7.0 直接复制模型时的 2.95 秒结果。

## Android 发布构建

应用显示名称为“小学英语点读”，版本为 `1.7.1+9`。保留现有 applicationId `com.example.english_point_reading`。图标提取封面的“英语”标题元素，生成各密度标准图标和 Android 8+ 自适应图标；源图位于 `tools/icon_sources/`，不作为教材资源打包。

```powershell
py -3.13 tools/prepare_launcher_icon.py
dart run flutter_launcher_icons
flutter build apk --release --split-per-abi
```

Release 开启 R8 代码压缩和资源缩减，使用独立发布签名；缺少签名配置时构建会失败，不会回退到调试签名。当前签名配置为 `android/key.properties`，密钥为 `android/release-signing/xiangshao-release.jks`，二者已排除在版本控制外。**请将两个文件一起安全备份，后续更新必须继续使用相同密钥。** 不要重新生成覆盖原密钥。

新工作环境应恢复上述签名文件。仅在首次创建发布身份且两个文件均不存在时，可使用 `py -3.13 tools/create_release_signing.py --keytool <JDK目录>/bin/keytool.exe`；脚本使用随机密码且不在终端打印密码。

本次 `1.7.1` 的交付文件为 `build/releases/v1.7.1/xiangshao-english-reader-v1.7.1-build9-arm64-v8a.apk`，ARM64 分包 versionCode 为 `2009`。大小：**98.34 MiB（103,119,027 字节）**；SHA-256：**`e81ec93514b522ef0192b04404021bf386ec3d15c47e3991ed6d3453f7e7f488`**。保留原正式签名、教材清单与离线资源；约 70.04 MiB 的完整英文模型以 XZ 无损压缩随 App 内置，原生库启用无损压缩。私有配置、凭据和密钥不参与打包。

上述全架构构建命令还会生成 `app-armeabi-v7a-release.apk`（32 位 ARM）和 `app-x86_64-release.apk`（x86_64）。这些是签名后的 Release 安装包，尚未上传应用商店。现有调试版与发布版签名不同，不能直接覆盖安装；需先备份所需数据再卸载调试版，卸载会清除其阅读进度。

## 版本归档与 GitHub、码云发布

以下正式发布步骤仅在收到用户当前批次的明确发布指令后执行。

每次 App 或教材资源更新都递增 `pubspec.yaml` 的版本和构建号，更新 [CHANGELOG.md](CHANGELOG.md)，并在 `releases/v{版本}.md` 写中文功能说明。交付 APK 的文件名包含版本、构建号和架构。

```powershell
# 构建完成后，核对 APK 内部版本并归档带版本号的安装包及 SHA-256
py -3.13 tools/package_release.py
# 提交本次源码，并创建新版本的 annotated tag 后，直接同步 GitHub 并发布 APK 与 SHA-256
py -3.13 tools/publish_github_release.py
# 同步码云，发布三个架构的 APK、校验文件与应用内更新清单
py -3.13 tools/publish_gitee_release.py
```

归档脚本会拒绝版本不符的旧 APK，以及覆盖不同内容的同名文件。GitHub 发布入口为 `tools/publish_github_release.py`，直接读取本地版本标签并使用 GitHub 凭据同步源码和附件，不访问 AtomGit；码云入口为 `tools/publish_gitee_release.py`，仅使用 Gitee 凭据。本项目的持续发布约定记录在 [AGENTS.md](AGENTS.md)。

2026-10-03 已完成仓库合并，2026-10-04 发布 `v1.4.0` 后，按用户要求停止 AtomGit 新版本发布。后续 GitHub 与码云使用 `main` 和 `v{版本}` annotated tag 记录每个 App 版本：

| 平台 | 仓库 | 发布用途 |
| --- | --- | --- |
| GitHub | [wildfirelh/xiangshao-english-reader](https://github.com/wildfirelh/xiangshao-english-reader) | 公开源码与 ARM64 APK、中文版本说明和校验文件 |
| Gitee 码云 | [wildfire666/xiangshao-english-reader](https://gitee.com/wildfire666/xiangshao-english-reader) | 公开源码、三个架构的 APK、中文版本说明、校验文件及应用内更新清单 |
| AtomGit / GitCode | [xiangshao-english-reader](https://gitcode.com/gcw_rw0AAl7X/xiangshao-english-reader) | 保留源码和历史版本，停止新增发布 |

Gitee 的 `update.json` 作为应用内更新渠道。码云网页的部分下载入口可能提示登录；本应用和上方下载链接直接使用已验证的公开 Release 附件地址。

保留现有源码提交历史，旧独立下载仓库已在 Release 和附件迁移、匿名访问验证完成后删除。GitHub 和码云 Release 必须使用同一版本说明、同一 ARM64 安装包和同一 SHA-256 校验文件；APK 作为 Release 附件发布，不提交 APK Git 对象。

此前 AtomGit → GitHub 原生 Push 镜像的首次同步与“立即同步”已验证，自动触发未确认。后续通过上述两个发布脚本直接同步本地 `main` 与版本标签，GitHub Release 与 APK 上传独立完成，停止 AtomGit 发布不会影响 GitHub 发布或码云更新。AtomGit 发布工具保留为历史工具。

公开发布必须核对 GitHub 和码云的源码版本标签与对应安装包，在无登录凭据的情况下分别验证公开仓库页面和附件下载链接，并重新下载 APK 比较 SHA-256；另核对 Gitee 最新版本 API 与更新清单。只有验证通过，才将该版本视为同步与公开发布完成。

当前应用版本与说明为 [v1.7.1](releases/v1.7.1.md)，下载入口为 [GitHub v1.7.1 Release](https://github.com/wildfirelh/xiangshao-english-reader/releases/tag/v1.7.1) 和 [Gitee v1.7.1 Release](https://gitee.com/wildfire666/xiangshao-english-reader/releases/v1.7.1)。发布脚本检查匿名访问与下载 SHA-256，并将结果记录在本地 `build/releases/v1.7.1/`。GitHub 已完成的 v1.7.0 发布保留为历史版本；该版 APK 超过码云 100 MB 附件上限，码云未完成的发布记录将在补丁准备就绪后清理，不向更新器提供不完整安装包。仅修改发布渠道、说明或发布脚本且 App 内容不变时，无需新增 App 版本；本次涉及本地模型解压和 Android 打包配置，因此新增补丁版本。不覆盖已有版本标签，不改写已发布的历史更新日志和 Release 内容。安装包本地归档、凭据与签名文件遵循现有忽略规则。

## 本地离线跟读（v1.7.1）

长按课本句子，或点底栏麦克风选择当前页的一句话，打开跟读抽屉。先听标准音，
点击麦克风开始录音，再点击停止评分；说话后静音 1.5 秒会自动停止，最长录音 15 秒。
系统只在点击录音时申请麦克风权限，拒绝后可以重试，永久拒绝时提供系统设置入口。
录音、识别、评分均在本机完成，运行时不下载模型或上传语音。

结果展示原文逐词绿／黄／红反馈和 0–100 跟读匹配分，点击红色词重听该词所在的完整
课本原句。“听标准音”和“听我的录音”使用同一播放器独占切换，可以反复对比。
再读一次会清理上次临时 WAV；离开抽屉会停止试听、取消录音、清理文件并释放原生指针。
来电等系统录音中断和进入后台也会取消本次录音。

模型采用 `sherpa-onnx-streaming-zipformer-en-2023-06-26` 的量化 encoder/joiner，
FP32 decoder 和英文 tokens 共 73,440,167 字节（约 70.04 MiB）。资源准备命令：

```powershell
py -3.13 tools/prepare_sherpa_model.py
```

工具使用固定源版本和 SHA-256 校验，已有正确文件会跳过；模型元数据、来源和许可在
`assets/models/sherpa/` 中。完整模型以 XZ 无损压缩随 App 内置，首次打开跟读才在独立
isolate 解压到应用私有目录并核对原始文件 SHA-256；已有正确缓存直接复用。首次
准备包含解压步骤，可能比直接复制耗时更长；加载和录音期间增量推理也在独立 isolate
执行，减小录音结束后的处理耗时。运行时仍不下载模型，也不需要联网识别。

**评分范围**：Sherpa 流式 Dart 接口没有词级置信度，仅提供识别文本、词元和时间戳。
当前颜色与分数来自文本序列匹配及完整度，不是专业声学发音评测；无法判断音素、重音、
语调或口音。对齐接口保留可选原生置信度，真正提供时按 0.85／0.50 阈值评级，
没有时保持 `confidence: null`，不伪造模型概率。儿童声音、教材人名和背景噪声可能导致
识别错误，结果应配合 AB 试听练习。

本地基准工具 `tools/benchmark_local_speech.dart` 可对本机 WAV 测量初始化、流式推理和
停止到评分耗时。300ms 是性能目标，需要按设备实测；首次模型准备耗时单独记录，
不能用文本对齐单元测试的耗时替代真实音频推理。

v1.7.0 原跟读实现已通过 351 项 Flutter 测试、148 项 Python 测试和静态分析。在没有默认网络的
Android API 36 x86_64 模拟器中，真实 production worker 对 1.224 秒 `Good morning.`
音频按实时 PCM 节奏识别，五次停止到评分为 29.065、17.477、22.745、22.711、19.952ms，
均正确识别目标文本；纯静音为 0 分。该版首次模型加载约 2.95 秒，运行于独立 isolate；
此结果不包含 v1.7.1 新增加的 XZ 解压步骤。
另已验证 Android 动态权限拒绝／重试授权、真实麦克风录音、15 秒自动结束、0 分结果
与 AB 试听。未连接实体手机；此基准不代表所有机型、儿童声音或噪声环境。

用户于 2026-10-05 明确授权发布离线跟读批次，本次以 `v1.7.1+9` 完成必要的码云附件体积修复；公开发布以完成正式包核对与两个渠道的匿名下载验证为准。后续新增改动继续等待下一次发布指令。

## 系统音频中断

`audio_session` 配置 Android `media` / `speech`，并将 `androidWillPauseWhenDucked` 设为 `false`。系统请求降音时，将音量降至 `0.25`（原音量更低时保持更低值），保留正在执行的连读；降音结束后约 150ms 内渐进恢复到打断前音量。重复降音不重复缩减音量，新降音会取消尚未结束的恢复动画。切换播放模式或音频自然结束不会提前解除系统降音；降音期间开始的后续音频仍使用降音音量。

来电、需要暂停的焦点中断、未知焦点丢失和耳机拔出仍暂停。进入 inactive / hidden / paused / detached 时也暂停，保留当前句子或气泡高亮与语速，并中止继续播放和自动翻页；已经发起的素材加载可以完成准备，但不会自行发声。回到前台或暂停中断结束后保持暂停；连读点击“播放”从当前音频位置继续，跨页途中暂停则保留下一页目标供手动恢复。整页模式点击热区切为单句，顺序模式点击热区更换起点；“重听”从所选小句或气泡开头重新播放。返回书架仍执行停止并清除选择。

## 应用内更新

主界面启动时在后台检查 Gitee 最新正式 Release，成功检查后 24 小时内不重复自动请求；“我的”中的“检查更新”按钮支持随时手动检查。无网络或没有新版时，自动检查不打断阅读。发现新版后展示实际新增功能，用户确认后在应用内下载，显示进度并支持取消；取消或失败的临时文件会清理，完整且有效的缓存可复用。

安装包下载到 App 私有缓存目录，核对字节数、SHA-256、包名、架构、递增版本和当前应用的签名身份后，调用 Android 系统安装器。Android 8 及以上首次安装更新时，需要在系统设置允许“小学英语点读”安装应用；返回后继续安装。Internet 权限为普通安装权限，不显示运行时授权弹窗；不申请广泛存储权限。取消系统安装后可重试。覆盖安装保留原有阅读进度和倍速偏好。

发布新增命令：

```powershell
py -3.13 tools/publish_gitee_release.py
```

该命令同步同仓 `main` 和原有 annotated 标签，归档三个 ABI 安装包、上传并匿名完整下载核对每个 APK，最后上传 `update.json`，避免更新器看到未就绪的包。更新清单使用规范构建号 `9` 比较版本，分包 versionCode 分别为 `1009 / 2009 / 4009`。可通过 `--abi` 限定发布架构，或 `--prepare-only` 仅准备本地归档；归档与版本说明确定后不覆盖已有正式内容。

配置参考：[Flutter Android 发布指南](https://docs.flutter.dev/deployment/android)、[audio_session 文档](https://pub.dev/packages/audio_session/versions/0.1.25)、[flutter_launcher_icons 文档](https://pub.dev/packages/flutter_launcher_icons)。
