# 项目交付与发布约定

本项目为“湘少英语三上点读”。用户已明确授权：每次更新 APK，文件名必须带版本号，并同步提交到 GitCode、发布新版本、写明功能更新内容。后续交付 App 功能或教材资源更新时，在同一任务内完成以下流程，无需再次请求发布确认。

1. 在 `pubspec.yaml` 同步语义版本号和递增的构建号（`版本+构建号`），同步 `README.md`、`CHANGELOG.md` 和 `releases/v{版本}.md`。发布说明使用中文，写本版实际新增、改进和修复的功能。
2. 完成与改动相关的验证；常规交付执行 `flutter analyze`、`flutter test` 和 `py -3.13 -m unittest discover -s tools -p 'test_*.py' -v`，记录真实结果。教材更新还应核对清单、图片和音频完整性。
3. 使用现有发布签名执行 `flutter build apk --release --split-per-abi`，验证版本、架构及签名。保留原签名身份，不重新生成或覆盖密钥。
4. 运行 `py -3.13 tools/package_release.py` 校验并归档当前 ARM64 APK。正式安装包放入 `build/releases/v{版本}/`，命名为 `xiangshao-english-reader-v{版本}-build{构建号}-{架构}.apk`，并生成对应 SHA-256 校验文件。不得仅以 `app-release.apk` 等无版本文件名交付。示例：`xiangshao-english-reader-v1.2.0-build3-arm64-v8a.apk`。
5. 正常提交本次源码、教材资产和说明，推送至 GitCode 私有仓库的 `main`：`https://gitcode.com/gcw_rw0AAl7X/xiangshao-english-reader.git`。创建并推送 `v{版本}` annotated tag；禁止覆盖已有发布标签或推送到公网仓库。
6. 运行 `py -3.13 tools/publish_gitcode_release.py`，在该私有仓库创建正式 Release，使用对应中文发布说明，并附带带版本号的 APK 和 SHA-256 校验文件。发布凭据使用已有 Git Credential Manager 或本机 `GITCODE_TOKEN` 环境变量。核对远端提交、标签、Release 和附件后，才报告发布完成。

凭据、`.env.volc`、缓存、`build/`、`android/key.properties` 和签名密钥不得提交。保持现有忽略规则，提交前检查暂存区；可提交 `.env.volc.example` 中的占位模板和公开音色 ID。

如果鉴权或发布服务阻塞，继续完成可做的打包、说明和本地提交，准确报告已完成与未完成的步骤及具体阻塞。不得将“本地准备完成”表述为“GitCode 发布完成”。
