# 英语点读

Flutter 项目，已实现教材 JSON 解析、Asset 加载、口语评测接口、点读音频调度、单元目录与阅读进度保存。资源构建默认覆盖 Unit 1–10 所在正文：PDF 第 8–72 页（65 页，含复习、评价页），生成高清图片、英文热区、中文机器翻译和离线 MP3。资源缺失时仍保留灰色示例页兜底。

当前随项目提供的正文资源包含 65 张图片、1,185 个点读条目和 MP3，722 条不同英文内容的翻译全部成功，清单没有空译文。全书音频已通过豆包语音合成模型 2.0 的 V3 HTTP SSE API 重新生成，采用下表指定的六类固定角色音色；779 组不同的文本与音色参数复用于 1,185 个点读音频文件。旧音频已移至本地 `.asset-cache/previous-audio/`，不参与 Flutter 打包。六类角色的联网短句试音保留在 `build/tts-check/`。

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

每次构建会以所选页面替换目标目录的 `book.json`，不会自动追加。请勿把 `--pages 8-11` 直接用于正式目录，否则正式清单将只剩这四页。预览资源如需进入 Flutter，需要额外在 `pubspec.yaml` 中声明预览目录并切换读取路径。

脚本默认输出 `assets/textbooks/xiangshao_3_1/`，图片为 200 DPI WebP（quality=85，保留像素尺寸），人物使用配置的固定 `speaker`。可用 `--image-format png` 导出 PNG。另从 PDF 第 1 页提取正面封面为 `images/cover.webp`；当前 PDF 的封面是横向展开图，因此取右侧正面。不传 PDF 路径时依次查找项目根目录的 `textbook.pdf`、`assets/textbook.pdf`。`asyncio` 已内置于 Python，无需额外安装；HTTP 合成使用 `requests`，不需要 Edge-TTS、WebSocket 协议库或额外 SSE SDK。

- `--pages 8-11,13` 可指定不连续页码，与 `--start-page` / `--end-page` 互斥。使用 PDF 的物理页码，从 1 开始；`pageIndex` 也保存物理页码。每次生成的 `book.json` 只包含本次选择的页面，并替换旧清单；旧清单引用但新清单不再使用的音频移至 `.asset-cache/previous-audio/` 备份。
- 英文按标点分句，结合对齐和间距合并换行；过滤无英文字母的内容。数字页码不会生成音频，英文标题、词汇和字母仍可点读。旋转页的热区会转换到渲染图片坐标系。
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

先识别漫画中的连续数字序号，将同一场景的句子放在一起，再按“提问／发起对话 → 应答 → 致谢告别”排序；同优先级按上到下、左到右排列。曲谱重复数字和练习编号不会直接作为漫画序号。句子 ID、文字和热区保持稳定，朗读次序只改变清单中的数组顺序。

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

- 底栏语速按钮在 `1.0x`（标准）与 `0.8x 慢速` 间切换，立即调整正在播放的音频，并对后续句子和跨页连读生效；速度保留至本次阅读器关闭，不重新生成 MP3。
- 连读结束一页后，会平滑翻至下一页并播放第一句；没有英文句子的页面会跳过，全书最后一句后停止。自动翻页期间手动点读、翻页或切回单句模式会取消待执行的自动播放。
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
      "pageIndex": 1,
      "imagePath": "assets/textbooks/xiangshao_3_1/images/p1.webp",
      "sentences": [
        {
          "id": "p1_s1",
          "text": "Hello!",
          "translation": "你好！",
          "audioPath": "assets/textbooks/xiangshao_3_1/audios/p1_s1.mp3",
          "rect": { "left": 0.1, "top": 0.2, "right": 0.5, "bottom": 0.3 }
        }
      ]
    }
  ]
}
```

`rect` 的四个值是相对于原始页面图片宽高的 0–1 坐标；左右、上下边界必须有序。`translation` 可省略。

阅读页会按图片原始比例居中显示，并把热区映射到实际图片区域。图片缺失时显示灰色页面，音频缺失时点按会显示提示，页面仍可操作。底部栏提供单句点读／整页连读切换、释义开关和跟读评测占位入口。

## 使用

```dart
final book = await TextbookRepository().loadBookFromAsset(
  'assets/textbooks/xiangshao_3_1/book.json',
);

final audio = AudioPlayerService();
audio.setPlayMode(PlayMode.continuous);
await audio.playSentence(
  pageSentences: book.pages.first.sentences,
  targetSentence: book.pages.first.sentences.first,
);
// 页面销毁时调用 audio.dispose()。
```

调用前需导入 `repositories/textbook_repository.dart` 和 `services/audio_player_service.dart`。界面可以监听 `AudioPlayerService` 的 `ChangeNotifier`，读取 `currentSentenceId`、`isPlaying` 和 `currentMode`。`MockSpeechEvaluator` 只返回占位结果，不进行录音或真实评分。

## 验证

```sh
flutter pub get
flutter analyze
flutter test
```

## Android 发布构建

应用显示名称为“湘少英语三上点读”，版本为 `1.2.0+3`。保留现有 applicationId `com.example.english_point_reading`。图标提取封面的“英语”标题元素，生成各密度标准图标和 Android 8+ 自适应图标；源图位于 `tools/icon_sources/`，不作为教材资源打包。

```powershell
py -3.13 tools/prepare_launcher_icon.py
dart run flutter_launcher_icons
flutter build apk --release --split-per-abi
```

Release 开启 R8 代码压缩和资源缩减，使用独立发布签名；缺少签名配置时构建会失败，不会回退到调试签名。当前签名配置为 `android/key.properties`，密钥为 `android/release-signing/xiangshao-release.jks`，二者已排除在版本控制外。**请将两个文件一起安全备份，后续更新必须继续使用相同密钥。** 不要重新生成覆盖原密钥。

新工作环境应恢复上述签名文件。仅在首次创建发布身份且两个文件均不存在时，可使用 `py -3.13 tools/create_release_signing.py --keytool <JDK目录>/bin/keytool.exe`；脚本使用随机密码且不在终端打印密码。

本次 `1.2.0` 的正式交付文件为 `build/releases/v1.2.0/xiangshao-english-reader-v1.2.0-build3-arm64-v8a.apk`（40.76 MiB，ARM64 分包 versionCode 为 2003），内含全书豆包 2.0 音频。签名与上一发布版一致，APK 内的清单、1,185 个 MP3 和 66 张 WebP（含封面）已逐一比对源文件。验证报告位于 `build/doubao2-release/release-verification.json`。

上述全架构构建命令还会生成 `app-armeabi-v7a-release.apk`（32 位 ARM）和 `app-x86_64-release.apk`（x86_64）。这些是签名后的 Release 安装包，尚未上传应用商店。现有调试版与发布版签名不同，不能直接覆盖安装；需先备份所需数据再卸载调试版，卸载会清除其阅读进度。

## 版本归档与 AtomGit、GitHub 发布

每次 App 或教材资源更新都递增 `pubspec.yaml` 的版本和构建号，更新 [CHANGELOG.md](CHANGELOG.md)，并在 `releases/v{版本}.md` 写中文功能说明。交付 APK 的文件名包含版本、构建号和架构。

```powershell
# 构建完成后，核对 APK 内部版本并归档带版本号的安装包及 SHA-256
py -3.13 tools/package_release.py
# 源码更新正常提交至 AtomGit 私有 main，并推送新版本的 annotated tag 后，发布公开 Release
py -3.13 tools/publish_public_release.py
# 同步 GitHub 私有源码仓库和公开下载仓库，发布同版本说明、APK 与 SHA-256
py -3.13 tools/publish_github_release.py
```

归档脚本会拒绝版本不符的旧 APK，以及覆盖不同内容的同名文件。AtomGit（原 GitCode）公开发布入口为 `tools/publish_public_release.py`，凭据使用本机 `GITCODE_TOKEN` 环境变量或现有 Git Credential Manager；GitHub 同步入口为 `tools/publish_github_release.py`，使用本机已登录的 GitHub 账户和凭据。原 `tools/publish_gitcode_release.py` 保留为私有仓库发布的兼容入口。本项目的持续发布约定记录在 [AGENTS.md](AGENTS.md)。

两端仓库按以下范围同步，源码使用 `main` 和 `v{版本}` annotated tag 记录每个 App 版本：

| 用途 | AtomGit / GitCode | GitHub | 可见性与内容 |
| --- | --- | --- | --- |
| 源码 | [xiangshao-english-reader](https://gitcode.com/gcw_rw0AAl7X/xiangshao-english-reader) | [wildfirelh/xiangshao-english-reader](https://github.com/wildfirelh/xiangshao-english-reader) | 私有：源码、教材源资产和开发说明 |
| 下载 | [xiangshao-english-reader-releases](https://gitcode.com/gcw_rw0AAl7X/xiangshao-english-reader-releases) | [wildfirelh/xiangshao-english-reader-releases](https://github.com/wildfirelh/xiangshao-english-reader-releases) | 公开：中文版本说明、下载文档，以及 Release 中的 APK 和 `.apk.sha256` 附件 |

两端公开仓库不上传源码、教材 PDF、教材清单或独立图片、音频等源资产，也不复制私有仓库历史。两边 Release 必须使用同一版本说明、同一安装包和同一 SHA-256 校验文件。

2026-10-03 已为私有源码仓库和公开下载仓库分别启用 AtomGit → GitHub 的原生 Push 镜像，首次同步成功，分支和标签一致。后续提交至 AtomGit 会自动同步 Git 提交、分支和标签；Release 说明及 APK 附件仍由 `tools/publish_github_release.py` 单独同步，脚本也会检查并补齐 Git 同步。

本次后续提交未观察到自动触发，已通过镜像的“立即同步”补齐两端提交；自动触发仍待确认。后续发布继续执行上述两个发布脚本，核对并补齐同步结果。

公开发布必须核对两端源码版本标签与对应安装包，在无登录凭据的情况下分别验证公开仓库页面和附件下载链接，并重新下载两端 APK 比较 SHA-256。只有两端匿名访问和下载校验均通过，才将该版本视为同步与公开发布完成。

当前应用版本与说明为 [v1.2.0](releases/v1.2.0.md)，本次公开发布渠道沿用现有 `1.2.0+3` 安装包。仅修改发布渠道、说明或发布脚本且 App 内容不变时，无需新增 App 版本；不覆盖已有版本标签，也不改写已发布的历史更新日志和 Release 内容。安装包本地归档、凭据与签名文件遵循现有忽略规则。

## 系统音频中断

使用 `audio_session` 的 `speech` 配置，并由播放服务统一处理焦点丢失、临时中断、duck 请求和耳机拔出。进入 inactive / hidden / paused / detached 时也暂停，保留当前句子高亮与语速，并取消尚未完成的加载和跨页连读。回到前台或中断结束后保持暂停，点击热区或“重听”从该句开头继续。返回书架仍执行停止并清除选择。

配置参考：[Flutter Android 发布指南](https://docs.flutter.dev/deployment/android)、[audio_session 文档](https://pub.dev/packages/audio_session/versions/0.1.25)、[flutter_launcher_icons 文档](https://pub.dev/packages/flutter_launcher_icons)。
