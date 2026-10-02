# 英语点读

Flutter 项目，已实现教材 JSON 解析、Asset 加载、口语评测接口、点读音频调度、单元目录与阅读进度保存。资源构建默认覆盖 Unit 1–10 所在正文：PDF 第 8–72 页（65 页，含复习、评价页），生成高清图片、英文热区、中文机器翻译和离线 MP3。资源缺失时仍保留灰色示例页兜底。

本地正文批处理已完成：65 张图片、1,185 个点读条目和 MP3，722 条不同英文内容的翻译全部成功，清单没有空译文。

## 从 PDF 构建资源

在本项目根目录执行（Windows 使用 `py -3.13`；其他环境可改成 `python`）：

```powershell
py -3.13 -m pip install -r tools/requirements.txt
# 验证 Unit 1 前四页
py -3.13 tools/build_textbook_assets.py assets/textbook.pdf --pages 8-11
# 正文批量构建：默认 PDF 第 8–72 页
py -3.13 tools/build_textbook_assets.py assets/textbook.pdf
# 按首尾页选择范围（包含首尾两页）
py -3.13 tools/build_textbook_assets.py assets/textbook.pdf --start-page 8 --end-page 72
# 包含封面、目录、附录的完整 89 页 PDF
py -3.13 tools/build_textbook_assets.py assets/textbook.pdf --start-page 1 --end-page 89
```

脚本默认输出 `assets/textbooks/xiangshao_3_1/`，图片为 200 DPI WebP（quality=85，保留像素尺寸），语音为 `en-US-AnaNeural`。可用 `--image-format png` 导出 PNG。另从 PDF 第 1 页提取正面封面为 `images/cover.webp`；当前 PDF 的封面是横向展开图，因此取右侧正面。不传 PDF 路径时依次查找项目根目录的 `textbook.pdf`、`assets/textbook.pdf`。`asyncio` 已内置于 Python，无需额外安装。

- `--pages 8-11,13` 可指定不连续页码，与 `--start-page` / `--end-page` 互斥。使用 PDF 的物理页码，从 1 开始；`pageIndex` 也保存物理页码。每次生成的 `book.json` 只包含本次选择的页面，并替换旧清单；已有的其他资源文件保留。
- 英文按标点分句，结合对齐和间距合并换行；过滤无英文字母的内容。数字页码不会生成音频，英文标题、词汇和字母仍可点读。旋转页的热区会转换到渲染图片坐标系。
- 这是基于文本层的几何提取，不包含 OCR。扫描页会输出图片并给出无英文文本的警告；若所选页面全部无英文，构建失败并保留旧清单。图片中没有文本层的文字不会自动变成热区。曲谱、复杂表格和特殊排版需人工校对。
- Edge-TTS **构建时需要联网**，生成的 MP3 可在 App 中离线播放。默认最多 3 个并发请求、每条重试 3 次；支持 `--proxy http://127.0.0.1:端口`。
- 已存在且非空的同名 MP3 会直接跳过。更换 PDF、抽取算法、文字或声音后使用 `--refresh-audio` 更新缓存；缓存按文件名判断，不比对内容。
- 使用 `deep-translator` 自动翻译英文为简体中文，默认 MyMemory，可用 `--translator google` 切换 Google。两个服务均需联网且可能限流；译文是机器翻译，教材人名、曲谱片段及多义词仍需校对。
- 翻译默认 2 个并发，每次请求有 20 秒连接/读取超时，重试 3 次；可用 `--translation-concurrency`、`--translation-timeout`、`--translation-delay` 调整。同一句英文只请求一次，成功结果立即缓存到 `.asset-cache/*.en-zh-CN.json`，已有 `book.json` 中的译文也会复用。`--refresh-translations` 强制重新翻译。
- 翻译失败写入空字符串 `""`，不阻断音频、图片及清单生成。失败结果不缓存，下次运行会继续补齐；终端会报告缺失数量，App 显示“暂无释义”。字母和部分专有名词可能由翻译服务原样返回。
- 临时音频和清单在 `.asset-cache/staging/` 内生成，避免 Flutter 打包临时文件；全部音频成功才发布 `book.json`。音频失败返回非零状态，可重跑继续，成功的翻译缓存会保留。
- 如用 `--output` 指定其他路径，必须位于本项目 `assets/` 内，并把对应目录加入 `pubspec.yaml`。

新增资源后重新运行 `flutter run` 或重新构建 APK，使 Flutter 重新打包资源。

```powershell
py -3.13 -m unittest tools.test_build_textbook_assets -v
```

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
- 高亮使用浅黄色遮罩、2dp 琥珀色圆角边框和 180ms 淡入；系统启用“减少动态效果”时取消动画。窄屏和大字号下控制栏自动换行。

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

应用显示名称为“湘少英语三上点读”，版本为 `1.0.0+1`。保留现有 applicationId `com.example.english_point_reading`。图标提取封面的“英语”标题元素，生成各密度标准图标和 Android 8+ 自适应图标；源图位于 `tools/icon_sources/`，不作为教材资源打包。

```powershell
py -3.13 tools/prepare_launcher_icon.py
dart run flutter_launcher_icons
flutter build apk --release --split-per-abi
```

Release 开启 R8 代码压缩和资源缩减，使用独立发布签名；缺少签名配置时构建会失败，不会回退到调试签名。当前签名配置为 `android/key.properties`，密钥为 `android/release-signing/xiangshao-release.jks`，二者已排除在版本控制外。**请将两个文件一起安全备份，后续更新必须继续使用相同密钥。** 不要重新生成覆盖原密钥。

新工作环境应恢复上述签名文件。仅在首次创建发布身份且两个文件均不存在时，可使用 `py -3.13 tools/create_release_signing.py --keytool <JDK目录>/bin/keytool.exe`；脚本使用随机密码且不在终端打印密码。

产物位于 `build/app/outputs/flutter-apk/`：`app-arm64-v8a-release.apk`（主流 ARM64 手机）、`app-armeabi-v7a-release.apk`（32 位 ARM）和 `app-x86_64-release.apk`（x86_64）。这些是签名后的 Release 安装包，尚未上传应用商店。现有调试版与发布版签名不同，不能直接覆盖安装；需先备份所需数据再卸载调试版，卸载会清除其阅读进度。

### 系统音频中断

使用 `audio_session` 的 `speech` 配置，并由播放服务统一处理焦点丢失、临时中断、duck 请求和耳机拔出。进入 inactive / hidden / paused / detached 时也暂停，保留当前句子高亮与语速，并取消尚未完成的加载和跨页连读。回到前台或中断结束后保持暂停，点击热区或“重听”从该句开头继续。返回书架仍执行停止并清除选择。

配置参考：[Flutter Android 发布指南](https://docs.flutter.dev/deployment/android)、[audio_session 文档](https://pub.dev/packages/audio_session/versions/0.1.25)、[flutter_launcher_icons 文档](https://pub.dev/packages/flutter_launcher_icons)。
