# 项目交付与发布约定

本项目为“湘少英语三上点读”。2026-10-03 用户已明确改为公开源码，并授权将源码与 APK Release 合并发布：AtomGit（原 GitCode）和 GitHub 每个平台只保留一个 `xiangshao-english-reader` 仓库；旧 `xiangshao-english-reader-releases` 仓库在 Release、附件和下载入口迁移验证完成后删除。此授权替代原“私有源码仓库 + 独立公开下载仓库”的约定。每次更新 APK，文件名必须带版本号，同步提交并在两端发布新版本，写明实际增加、改进和修复的功能。后续交付 App 功能或教材资源更新时，在同一任务内完成以下流程，无需再次请求发布或同步确认。

1. 在 `pubspec.yaml` 同步语义版本号和递增的构建号（`版本+构建号`），同步 `README.md`、`CHANGELOG.md` 和 `releases/v{版本}.md`。发布说明使用中文，写本版实际新增、改进和修复的功能。
2. 完成与改动相关的验证；常规交付执行 `flutter analyze`、`flutter test` 和 `py -3.13 -m unittest discover -s tools -p 'test_*.py' -v`，记录真实结果。教材更新还应核对清单、图片和音频完整性。
3. 使用现有发布签名执行 `flutter build apk --release --split-per-abi`，验证版本、架构及签名。保留原签名身份，不重新生成或覆盖密钥。
4. 运行 `py -3.13 tools/package_release.py` 校验并归档当前 ARM64 APK。正式安装包放入 `build/releases/v{版本}/`，命名为 `xiangshao-english-reader-v{版本}-build{构建号}-{架构}.apk`，并生成对应 SHA-256 校验文件。不得仅以 `app-release.apk` 等无版本文件名交付。示例：`xiangshao-english-reader-v1.2.0-build3-arm64-v8a.apk`。
5. 正常提交本次源码、教材源资产和说明，推送至 AtomGit 公开仓库的 `main`：`https://gitcode.com/gcw_rw0AAl7X/xiangshao-english-reader.git`。为新的 App 版本创建并推送 `v{版本}` annotated tag，保留已经发布的标签；对应 GitHub 公开仓库为 `https://github.com/wildfirelh/xiangshao-english-reader`。
6. 运行 `py -3.13 tools/publish_public_release.py`，在上述 AtomGit 源码仓库创建正式 Release，发布对应中文说明、带版本号的 APK 和 SHA-256 校验文件。发布凭据使用已有 Git Credential Manager 或本机 `GITCODE_TOKEN` 环境变量。安装包和校验文件作为同仓 Release 附件提供，不提交 APK Git 对象。
7. 接着运行 `py -3.13 tools/publish_github_release.py`，将源码分支与标签同步到上述 GitHub 公开仓库，并在同一仓库发布同一版本的中文说明、同一 APK 和 SHA-256 校验文件。GitHub 使用本机已登录的账户和凭据。
8. 核对两端公开仓库的源码提交、版本标签、Release 和附件；使用不带登录凭据的请求检查仓库页面、发布页面与下载链接可访问，并分别重新下载 APK 核对 SHA-256。所有验证成功后，才报告两端同步与公开发布完成。

保留 `xiangshao-english-reader` 源码仓库的 AtomGit → GitHub 原生 Push 镜像，旧下载仓库的镜像随仓库迁移移除。原生镜像只同步 Git 提交、分支和标签，Release 说明及附件必须通过 GitHub 发布入口单独同步。继续运行发布脚本核对并补齐两端 Git 同步和 Release 发布；若镜像后续失败，准确记录状态并用发布脚本完成同步。

首次镜像同步及后续“立即同步”已验证；本次新提交的自动触发尚未观察到，不得将手动镜像成功表述为自动触发已验证。每次发布仍需执行两个发布入口核对并补齐同步。

仅修改发布渠道、说明或发布脚本，不改变 App 内容时，无需递增 App 版本。可以复用已有 APK 和版本说明完成公开发布，但不得移动已有 App 版本标签或改写已发布的历史更新日志、Release 内容。

源码、教材资产、开发说明和已有提交历史使用上述两个公开仓库同步；不再创建或维护独立的 APK 下载仓库。改变仓库可见性前核对已有提交历史与当前暂存区，确保没有真实凭据和签名密钥；不得通过移动既有标签来迁移 Release。

凭据、`.env.volc`、缓存、`build/`、`android/key.properties` 和签名密钥不得提交。保持现有忽略规则，提交前检查暂存区；可提交 `.env.volc.example` 中的占位模板和公开音色 ID。

原创应用代码和工具采用 `LICENSE` 中的 MIT 许可证；教材 PDF、图文、离线音频等资源按 `NOTICE.md` 单独标注，不将第三方内容重新授予 MIT 许可。

如果鉴权、发布服务或匿名访问验证阻塞，继续完成可做的打包、说明和本地提交，准确报告已完成与未完成的步骤及具体阻塞。不得将“本地准备完成”或“已登录账号可以下载”表述为“公开发布完成”。
