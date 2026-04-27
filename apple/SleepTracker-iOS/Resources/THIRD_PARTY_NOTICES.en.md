# Open Source Notices

Some Circadia features may reference, use or integrate publicly released third-party algorithms, model weights, code, developer tools, technical documentation, research or open-source community resources.

Intellectual property and other rights in such third-party materials belong to their respective rights holders. Circadia's use of third-party materials is governed by the respective licences, terms of use, model cards, repository notices, copyright notices and other authorisation documents.

## 1. Apple technology and resources

Some Circadia features use or reference publicly released Apple on-device machine learning technology, Core ML tooling, Apple Health / HealthKit documentation, sample code, models, algorithms, developer tools or research, including but not limited to:

- **MLX** (core array framework) — © Apple Inc., MIT License;
- **MLX-Swift** — © Apple Inc., Apache License 2.0;
- **MLX Swift Examples** (`MLXLLM`, `MLXLMCommon`) — © Apple Inc. and contributors, MIT License;
- **SoundAnalysis** framework and the bundled `SNClassifierIdentifier.version1` general-purpose sound classifier — © Apple Inc., provided as part of iOS / iPadOS under the Apple Developer Program License Agreement;
- **SF Symbols** — © Apple Inc., used in Apple-platform Apps under the SF Symbols licence terms.

Use of relevant Apple materials is governed by Apple's applicable developer terms, licences, model licences, documentation and platform rules.

Apple, iPhone, iOS, Apple Health, HealthKit, Core ML, App Store and related names and logos are trademarks or registered trademarks of Apple Inc.

Unless explicitly stated in writing, there is no sponsorship, endorsement, partnership, agency or affiliation between Circadia and Apple Inc.

## 2. Google DeepMind / Google models and research

The optional on-device AI assistant (Sleep AI) inside Circadia uses model weights from the **Gemma** family of open models, originally released by **Google DeepMind**.

- Architecture and weights © Google LLC / Google DeepMind;
- Use is subject to the **Gemma Terms of Use** and the **Gemma Prohibited Use Policy**;
- Circadia does not redistribute the original Gemma weights; if you choose to download them, they remain governed by Google's terms;
- See <https://ai.google.dev/gemma/terms> and <https://ai.google.dev/gemma/prohibited_use_policy>.

If Circadia ships LoRA-fine-tuned adapters derived from Gemma, those adapters are distributed as a derivative work under the Gemma Terms of Use.

"Gemma" is a trademark of Google LLC. The reference here is for identification only and does not imply endorsement.

Google, Google DeepMind and related names and logos belong to their respective rights holders. Unless explicitly stated in writing, there is no sponsorship, endorsement, partnership, agency or affiliation between Circadia and Google LLC, Google DeepMind or their affiliates.

## 3. Alibaba Tongyi Lab / Qwen models

In Mainland China and selected regions, Circadia uses **Qwen** open-weights model series, publicly released by **Alibaba Tongyi Lab (Alibaba Cloud / Alibaba Group)**.

- Architecture and weights © Alibaba Group / Tongyi Lab;
- Use is governed by the **Apache License 2.0** (the upstream open-source license for the Qwen mainline); some variants may carry additional usage terms — refer to the official repository and model card;
- Circadia does not redistribute the original weights; if you choose to download them, the upstream terms from Alibaba and the original publisher continue to apply;
- See <https://github.com/QwenLM/Qwen3> and the corresponding Hugging Face model cards.

If Circadia ships LoRA fine-tuning adapters built on Qwen, those adapters, as derivative works, are also subject to the upstream license.

"Qwen", "Tongyi", "通义", "通义千问" and related names and logos are trademarks or service marks of Alibaba Group / Alibaba Tongyi Lab. Their reference here is for identification only and does not imply any endorsement.

Unless explicitly stated in writing, there is no sponsorship, endorsement, partnership, agency or affiliation between Circadia and Alibaba Group, Alibaba Tongyi Lab or their affiliates.

## 4. GitHub open-source projects

Some Circadia features use or reference publicly released open-source projects, algorithms, code snippets, developer tools, documentation or technical discussions on GitHub, including but not limited to:

- **swift-bridge** — © the swift-bridge authors, dual-licensed under Apache 2.0 / MIT, <https://github.com/chinedufn/swift-bridge>;
- **SQLite** — public domain, <https://www.sqlite.org/copyright.html>;
- Rust ecosystem dependencies — `rusqlite` (MIT), `serde` (MIT/Apache-2.0), `tokio` (MIT), `chrono` (MIT/Apache-2.0), etc.;
- Training tooling (developer machines only, not shipped with the App) — **PyTorch** (BSD-3-Clause), **NumPy** (BSD-3-Clause), **coremltools** (BSD-3-Clause), **PyYAML** (MIT), **tqdm** (MIT/MPL-2.0).

Use of such projects is governed by the respective licences, copyright notices, project descriptions and other authorisation documents in each repository.

## 5. Hugging Face models and community resources

During development, Circadia obtains public Gemma checkpoints via the **Hugging Face Hub**. Re-quantised variants (for example `mlx-community/gemma-2-2b-it-4bit`) belong to their respective uploaders, and use is governed by their model cards, licences and the Gemma Terms of Use.

Use of such models and resources is governed by their respective model pages, model cards, licences, usage restrictions, publisher notices and other authorisation documents.

## 6. Third-party component, model and resource list

The following table lists the main third-party components, models, algorithms, model weights or resources used, referenced or integrated in the current version of Circadia. The list may change in future releases.

| Name | Source | Use | Licence / Terms | Modified | Notes |
|---|---|---|---|---|---|
| Gemma-2-2B (Instruct, 4-bit) | Google DeepMind / Hugging Face | Sleep AI inference (overseas regions) | Gemma Terms of Use | No (LoRA loaded at runtime) | Original weights not redistributed |
| Qwen3-1.7B (Instruct, 4-bit) | Alibaba Tongyi Lab / Hugging Face | Sleep AI Instant tier (Mainland China etc.) | Apache 2.0 | No (LoRA loaded at runtime) | Original weights not redistributed |
| Qwen3-4B (Instruct, 4-bit) | Alibaba Tongyi Lab / Hugging Face | Sleep AI Pro tier (Mainland China etc.) | Apache 2.0 | No (LoRA loaded at runtime) | Original weights not redistributed |
| Sleep-AI LoRA adapter (Gemma) | BIRI GA (fine-tuned on Gemma) | Health-topic constraint | Gemma Terms of Use (derivative) | Yes | Trained by Circadia and shipped with the App |
| Sleep-AI LoRA adapter (Qwen) | BIRI GA (fine-tuned on Qwen3) | Health-topic constraint | Apache 2.0 (derivative) | Yes | Trained by Circadia and shipped with the App |
| MLX | Apple Inc. | Tensor compute | MIT | No | iOS-side inference backend |
| MLX-Swift | Apple Inc. | Swift bindings | Apache 2.0 | No | — |
| MLX Swift Examples (MLXLLM/MLXLMCommon) | Apple Inc. and contributors | LLM inference scaffold | MIT | No | — |
| SoundAnalysis | Apple Inc. | Snore event detection | Apple Developer Program License | No | Event counts only, no audio retained |
| SF Symbols | Apple Inc. | UI icons | SF Symbols License | No | — |
| swift-bridge | swift-bridge authors | Swift ↔ Rust FFI | Apache 2.0 / MIT | No | — |
| SQLite | D. Richard Hipp et al. | Local data storage | Public domain | No | — |
| Rust crates (rusqlite / serde / tokio / chrono) | Open-source authors | Signal processing and storage | MIT / Apache-2.0 | No | See `Cargo.lock` |
| PyTorch / NumPy / coremltools / PyYAML / tqdm | Open-source community | Training and export toolchain | BSD-3 / MIT / MPL-2.0 | No | Developer machines only, not shipped |

## 7. No endorsement

Any reference to a third-party name, trademark, project, model, algorithm, weight, code, tool or resource is only to identify the source of technology Circadia uses, references or benefits from.

Such references do not imply that the third party sponsors, endorses, recommends, partners with, acts as an agent for, warrants or supports Circadia.

## 8. Reservation of rights

Intellectual property and other rights in all third-party materials are reserved by their respective rights holders.

Circadia respects third-party rights holders and the open-source community. If you believe any third-party notice on this page is missing, inaccurate or needs updating, contact:

**Email:** keika_bayagud@outlook.com

---

*The components above retain their original copyright notices and licences. The remainder of Circadia is © 2026 BIRI GA. All rights reserved.*
