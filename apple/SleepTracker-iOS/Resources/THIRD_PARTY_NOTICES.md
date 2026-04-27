# Third-Party Notices & Acknowledgments

Circadia is built on the work of many open-source projects, research datasets, and platform frameworks. We are grateful to every author whose code, models, or data made this app possible.

The notices below apply to components included in or used by this app. Each retains its original copyright and license.

---

## 1. Google DeepMind — Gemma model family · *Gemma Terms of Use*

Circadia's optional on-device assistant ("Sleep AI") uses model weights from the **Gemma** family of open models, originally released by **Google DeepMind**.

- Architecture and weights: © Google LLC / Google DeepMind.
- Use is subject to the **Gemma Terms of Use** and the **Gemma Prohibited Use Policy**.
- Circadia does not redistribute Gemma weights; if you choose to download them, they remain governed by Google's terms.
- See <https://ai.google.dev/gemma/terms> and <https://ai.google.dev/gemma/prohibited_use_policy>.

> "Gemma" is a trademark of Google LLC. Use of the name is for identification only and does not imply endorsement.

If we ship LoRA-fine-tuned adapters derived from Gemma, those adapters are also distributed under the Gemma Terms of Use as a derivative work.

## 2. Apple Inc. — MLX, MLX-Swift, MLX Swift Examples

- **MLX** (core array framework) — © Apple Inc., MIT License.
- **MLX-Swift** — © Apple Inc., Apache License 2.0.
- **MLX Swift Examples** (`MLXLLM`, `MLXLMCommon`) — © Apple Inc. and contributors, MIT License.

See <https://www.apache.org/licenses/LICENSE-2.0> and <https://opensource.org/license/MIT>.

## 3. Apple Inc. — SoundAnalysis & built-in sound classifier

Circadia's snore detection uses Apple's **SoundAnalysis** framework and its bundled `SNClassifierIdentifier.version1` general-purpose sound classifier. © Apple Inc. Provided as part of iOS / iPadOS under the Apple Developer Program License Agreement.

## 4. Karol J. Piczak — *ESC-50: Dataset for Environmental Sound Classification* · CC BY-NC 3.0

Our optional fallback snore CNN (`python/training/train_snore_cnn.py`) is trained on the **ESC-50** dataset.

- Citation: K. J. Piczak. *ESC: Dataset for Environmental Sound Classification.* Proceedings of the 23rd Annual ACM Conference on Multimedia, 2015.
- License: **Creative Commons Attribution-NonCommercial 3.0** (CC BY-NC 3.0). See <https://creativecommons.org/licenses/by-nc/3.0/>.
- Source: <https://github.com/karolpiczak/ESC-50>.

> ESC-50 is licensed for **non-commercial** use. The dataset itself is not redistributed by Circadia. The trained model weights, when shipped, are derivative works and inherit ESC-50's non-commercial restriction; the production build prefers Apple's SoundAnalysis classifier (see §3) for any commercial distribution.

## 5. swift-bridge · Apache 2.0 / MIT

Copyright © the swift-bridge authors. Dual-licensed under Apache 2.0 and MIT.
See <https://github.com/chinedufn/swift-bridge>.

## 6. SQLite · Public Domain

SQLite is in the public domain.
See <https://www.sqlite.org/copyright.html>.

## 7. Rust crates

Circadia includes Rust crates for signal processing and on-device storage. Each crate retains its own license; see the source repository's `Cargo.lock` and the `LICENSE` file in each crate for full attribution. Notable direct dependencies include `rusqlite` (MIT), `serde` (MIT/Apache-2.0), `tokio` (MIT), and `chrono` (MIT/Apache-2.0).

## 8. PyTorch, NumPy, and the Python scientific stack

Training and export tooling under `python/` uses **PyTorch** (BSD-3-Clause), **NumPy** (BSD-3-Clause), **coremltools** (BSD-3-Clause), **PyYAML** (MIT), and **tqdm** (MIT/MPL-2.0). These tools run on developer machines only and are not shipped inside the iOS app.

## 9. SF Symbols · Apple Inc.

SF Symbols are provided by Apple Inc. for use in Apple-platform apps under the SF Symbols license terms.

## 10. Hugging Face Hub & community

Public Gemma checkpoints used during development are distributed via the **Hugging Face Hub**. Re-quantized variants (e.g. `mlx-community/gemma-3n-E2B-it-4bit`) are credited to their respective uploaders under the Gemma Terms of Use.

---

## Acknowledgments

Circadia would not exist without the broader open-source community. In particular we thank:

- **Google DeepMind** — for releasing Gemma as an open-weights model family.
- **Apple's MLX team** — for making on-device transformers practical on Apple Silicon.
- **Apple's SoundAnalysis team** — for shipping a privacy-preserving sound classifier inside iOS.
- **Karol J. Piczak** — for curating ESC-50, which made early snore-detection prototyping possible.
- The maintainers of **PyTorch, NumPy, SQLite, Rust, swift-bridge, mlx-lm, coremltools, Hugging Face Transformers,** and every other dependency we did not name individually.

Thank you. 🙏

---

*Components above retain their original copyright notices and licenses. The remainder of Circadia is © 2026 BIRI GA. All rights reserved.*
