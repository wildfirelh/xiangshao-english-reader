# 许可范围

本项目原创应用源码、构建工具及开发文档采用根目录 [LICENSE](LICENSE) 中的 MIT 许可证。

`assets/` 下的教材 PDF、课本图文、离线朗读音频及教材清单不在本项目 MIT 授权范围内，其内容相关权利归相应权利人所有。本仓库公开这些资源，不表示对教材及第三方内容授予新的使用许可。

第三方依赖继续适用各自许可证。

## 内置离线语音识别模型

`assets/models/sherpa/` 中的英文 Zipformer 模型来自
[csukuangfj/sherpa-onnx-streaming-zipformer-en-2023-06-26](https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-en-2023-06-26)，
源模型声明采用 Apache-2.0，适用该目录随附的 `LICENSE`，不重新授予 MIT。
固定源版本、文件 SHA-256 与下载出处见 `model.json`，准备工具为
`tools/prepare_sherpa_model.py`。Sherpa-ONNX 推理库同样采用 Apache-2.0。
模型随安装包内置；跟读录音与识别结果在本机处理，不上传任何语音评测服务。
