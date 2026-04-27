# 第三方许可与声明

Circadia 的部分功能可能参考、使用或集成第三方公开发布的算法、模型权重、代码、开发工具、技术文档、研究成果或开源社区资源。

相关第三方材料的知识产权及其他权利归其各自权利人所有。Circadia 对第三方材料的使用，受其各自适用的许可证、使用条款、模型卡、仓库声明、版权声明及其他授权文件约束。

## 1. Apple 相关技术及资源

Circadia 的部分功能可能使用或参考 Apple 公开发布的设备端机器学习技术、Core ML 相关工具、Apple Health / HealthKit 文档、示例代码、模型、算法、开发工具或研究成果，包括但不限于：

- **MLX**（核心数组框架）— © Apple Inc.，MIT 许可证；
- **MLX-Swift** — © Apple Inc.，Apache License 2.0；
- **MLX Swift Examples**（`MLXLLM`、`MLXLMCommon`）— © Apple Inc. 及贡献者，MIT 许可证；
- **SoundAnalysis** 框架及其内置 `SNClassifierIdentifier.version1` 通用声音分类器 — © Apple Inc.，作为 iOS / iPadOS 的一部分，依 Apple Developer Program License Agreement 提供；
- **SF Symbols** — © Apple Inc.，依 SF Symbols 许可条款用于 Apple 平台 App。

相关 Apple 材料的使用以 Apple 适用的开发者条款、许可证、模型许可、文档说明及平台规则为准。

Apple、iPhone、iOS、Apple Health、HealthKit、Core ML、App Store 及相关名称和标识均为 Apple Inc. 的商标或注册商标。

除非另有明确书面说明，Circadia 与 Apple Inc. 之间不存在赞助、认可、背书、推荐、合作、代理或隶属关系。

## 2. Google DeepMind / Google 相关模型及研究成果

Circadia 内可选的本设备 AI 助手（Sleep AI）使用 **Gemma** 系列开放模型权重，由 **Google DeepMind** 公开发布。

- 架构与权重 © Google LLC / Google DeepMind；
- 使用受 **Gemma Terms of Use** 与 **Gemma Prohibited Use Policy** 约束；
- Circadia 不再分发 Gemma 原始权重；如你选择下载，仍以 Google 适用条款为准；
- 详见 <https://ai.google.dev/gemma/terms> 与 <https://ai.google.dev/gemma/prohibited_use_policy>。

如 Circadia 随附基于 Gemma 的 LoRA 微调适配器（adapter），相关适配器作为衍生作品同样受 Gemma Terms of Use 约束。

"Gemma" 为 Google LLC 的商标，本处提及仅用于标识来源，不表示任何背书。

Google、Google DeepMind 及相关名称和标识均归其各自权利人所有。除非另有明确书面说明，Circadia 与 Google LLC、Google DeepMind 或其关联方之间不存在赞助、认可、背书、推荐、合作、代理或隶属关系。

## 3. GitHub 开源项目

Circadia 的部分功能使用或参考 GitHub 上公开发布的开源项目、算法、代码片段、开发工具、文档或技术讨论，包括但不限于：

- **swift-bridge** — © swift-bridge 作者，双许可于 Apache 2.0 / MIT，<https://github.com/chinedufn/swift-bridge>；
- **SQLite** — 公有领域，<https://www.sqlite.org/copyright.html>；
- Rust 生态依赖 — `rusqlite`（MIT）、`serde`（MIT/Apache-2.0）、`tokio`（MIT）、`chrono`（MIT/Apache-2.0）等；
- 训练侧工具（仅在开发机运行，不随 App 分发）— **PyTorch**（BSD-3-Clause）、**NumPy**（BSD-3-Clause）、**coremltools**（BSD-3-Clause）、**PyYAML**（MIT）、**tqdm**（MIT/MPL-2.0）。

相关项目的使用以其各自仓库中列明的许可证、版权声明、项目说明及其他授权文件为准。

## 4. Hugging Face 模型及社区资源

Circadia 在开发过程中通过 **Hugging Face Hub** 获取 Gemma 公共检查点。重新量化的变体（例如 `mlx-community/gemma-2-2b-it-4bit`）的权利归其各自上传者所有，使用以其模型卡、许可证及 Gemma Terms of Use 为准。

相关模型及资源的使用以其各自模型页面、模型卡、许可证、使用限制、发布者声明及其他授权文件为准。

## 5. 第三方组件、模型及资源清单

下表列明 Circadia 当前版本中使用、参考或集成的主要第三方组件、模型、算法、模型权重或资源。具体清单可能随版本更新而调整。

| 名称 | 来源 | 用途 | 许可证 / 条款 | 是否修改 | 备注 |
|---|---|---|---|---|---|
| Gemma-2-2B (Instruct, 4-bit) | Google DeepMind / Hugging Face | 本设备 Sleep AI 推理 | Gemma Terms of Use | 否（推理时加载 LoRA 适配器） | 不再分发原始权重 |
| Sleep-AI LoRA adapter | BIRI GA（基于 Gemma 微调） | 健康话题约束 | Gemma Terms of Use（衍生作品） | 是 | 由 Circadia 训练并随 App 分发 |
| MLX | Apple Inc. | 张量运算 | MIT | 否 | iOS 端推理后端 |
| MLX-Swift | Apple Inc. | Swift 绑定 | Apache 2.0 | 否 | — |
| MLX Swift Examples (MLXLLM/MLXLMCommon) | Apple Inc. 及贡献者 | LLM 推理脚手架 | MIT | 否 | — |
| SoundAnalysis | Apple Inc. | 打鼾事件检测 | Apple Developer Program License | 否 | 仅事件计数，不保存音频 |
| SF Symbols | Apple Inc. | UI 图标 | SF Symbols License | 否 | — |
| swift-bridge | swift-bridge 作者 | Swift ↔ Rust FFI | Apache 2.0 / MIT | 否 | — |
| SQLite | D. Richard Hipp 等 | 本地数据存储 | 公有领域 | 否 | — |
| Rust crates (rusqlite / serde / tokio / chrono) | 各开源作者 | 信号处理与存储 | MIT / Apache-2.0 | 否 | 详见 `Cargo.lock` |
| PyTorch / NumPy / coremltools / PyYAML / tqdm | 各开源社区 | 训练与导出工具链 | BSD-3 / MIT / MPL-2.0 | 否 | 仅开发机使用，不随 App 分发 |

## 6. 无背书声明

任何第三方名称、商标、项目、模型、算法、模型权重、代码、工具或资源的提及，仅用于说明 Circadia 所使用、参考或受益的技术来源。

相关提及不表示该等第三方赞助、认可、背书、推荐、合作、代理、保证或支持 Circadia。

## 7. 权利保留

所有第三方材料的知识产权及其他权利均由其各自权利人保留。

Circadia 尊重第三方权利人及开源社区。如你认为本页面中的任何第三方声明存在遗漏、不准确或需要更新，请通过以下方式联系：

**联系邮箱：** gabira@bayagud.com

---

*以上组件保留其原始版权声明与许可证。Circadia 的其余部分 © 2026 BIRI GA，保留所有权利。*
