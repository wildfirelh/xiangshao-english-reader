# 离线英文识别模型

模型：`csukuangfj/sherpa-onnx-streaming-zipformer-en-2023-06-26`，Apache-2.0。
源仓库：https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-en-2023-06-26
固定 revision：`672fbf1b30579d6585301139bb363f42a0ad4a24`。

在项目根目录运行 `python tools/prepare_sherpa_model.py`，获取并逐个核对 SHA-256。
模型包括 int8 encoder/joiner、FP32 decoder 和 tokens，原始内容约 70 MiB。
三个 ONNX 文件采用无损 XZ 格式内置；首次使用在后台解压至应用私有目录，
验证压缩包与还原模型的大小和 SHA-256。后续复用校验通过的缓存模型。
原始 ONNX 保留在源码中，但不重复打入 APK。运行时不请求网络。
模型元数据、内置资产路径及两组校验值见 model.json。

模型识别器提供文本、词元和时间戳，没有原生词级发音置信度；当前评分是
识别文本与课文目标的跟读匹配及完整度反馈，不能判断音素、重音或口音质量。
