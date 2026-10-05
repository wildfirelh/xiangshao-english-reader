# 离线英文识别模型

模型：`csukuangfj/sherpa-onnx-streaming-zipformer-en-2023-06-26`，Apache-2.0。
源仓库：https://huggingface.co/csukuangfj/sherpa-onnx-streaming-zipformer-en-2023-06-26
固定 revision：`672fbf1b30579d6585301139bb363f42a0ad4a24`。

在项目根目录运行 `python tools/prepare_sherpa_model.py`，获取并逐个核对 SHA-256。
只打包 int8 encoder/joiner、FP32 decoder 和 tokens，约 70 MiB。
这些文件随 App 内置，运行时不请求网络。模型元数据及校验值见 model.json。

模型识别器提供文本、词元和时间戳，没有原生词级发音置信度；当前评分是
识别文本与课文目标的跟读匹配及完整度反馈，不能判断音素、重音或口音质量。
