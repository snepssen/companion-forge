# Third-party notices

Companion is GPL-3.0-or-later. The licence text is `LICENSE`, which the
build copies into the app beside this file.

These are the other works the built app ships or links. The libraries are
the ones `Package.swift` links and `Package.resolved` pins, and the files
are the ones `build.sh` copies into `Companion.app`. A package that is
only resolved, and not linked into the app, is not listed.

## espeak-ng

- Licence: GPL-3.0-or-later
- Source: https://github.com/espeak-ng/espeak-ng/commit/724808c5a83f9ef95fdd0db886ba7ba537ff224a
- Commit: `724808c5a83f9ef95fdd0db886ba7ba537ff224a`

Included through voice-core 1.0.3
(https://github.com/snepssen/voice-core, revision
`d55f336b3518603de2f30e7a04d085aec40ebc5d`). voice-core builds that
commit, the same one piper1-gpl pins, and the app links the library.
`build.sh` copies voice-core's `espeak-ng-data` into the app.

## Silero VAD

- Licence: MIT. Copyright (c) 2020-present Silero Team.
- Source: https://github.com/snakers4/silero-vad

The weights are `silero_vad.onnx`, fetched from
https://github.com/snakers4/silero-vad/blob/master/src/silero_vad/data/silero_vad.onnx
and copied into the app by `build.sh`. speech-core's SileroVAD loads them.

## English Wiktionary dictionary

- Licences: Creative Commons Attribution-ShareAlike 4.0 International
  (https://creativecommons.org/licenses/by-sa/4.0/) and the GNU Free
  Documentation License 1.3 (https://www.gnu.org/licenses/fdl-1.3.html).
- Source: English Wiktionary, https://en.wiktionary.org/, by its contributors.

`dictionary.sqlite` is a modified extract. `scripts/build-dictionary.sh`
fetches kaikki.org's extract of English Wiktionary
(https://kaikki.org/dictionary/English/kaikki.org-dictionary-English.jsonl.gz),
and `scripts/build-dictionary.py` keeps translations between English and
the languages the companion is asked about, plus a short English
definition for each word, and drops the rest. `build.sh` copies the
database into the app. The database stays under both of those licences.

Attribution: English Wiktionary contributors, English Wiktionary,
CC BY-SA 4.0 and GFDL, via kaikki.org. Changes: cut down to a SQLite
dictionary of translations and short definitions.

## FluidAudio

- Licence: Apache-2.0 (https://www.apache.org/licenses/LICENSE-2.0)
- Source: https://github.com/FluidInference/FluidAudio
- Version: 0.17.7, revision `503b4bd1bbf7220882de39fe8ae6716aae4132da`

The app links the FluidAudio library for Parakeet recognition and CAM++
voiceprints.

## swift-transformers

- Licence: Apache-2.0 (https://www.apache.org/licenses/LICENSE-2.0)
- Source: https://github.com/huggingface/swift-transformers
- Version: 1.3.5, revision `48473106a93b2d8dfb114b82f0628ebbb71734e7`

The app links the Tokenizers product.

## swift-huggingface

- Licence: Apache-2.0 (https://www.apache.org/licenses/LICENSE-2.0)
- Source: https://github.com/huggingface/swift-huggingface
- Version: 1.0.0, revision `c30143a4616f3fa994ee3ab3e3464f752845c07c`

The app links the HuggingFace product.

## swift-crypto

- Licence: Apache-2.0 (https://www.apache.org/licenses/LICENSE-2.0)
- Source: https://github.com/apple/swift-crypto
- Version: 4.5.2, revision `da9d28d69ebe3894b18376c8f2395c2f37b8448f`
- Copyright 2019 The SwiftCrypto Project.

The app links it because swift-transformers and swift-huggingface depend
on the Crypto product. The app's own sealing uses CryptoKit on Apple
platforms. The direct dependency in `Package.swift` is only for Linux,
where CryptoKit is absent.

swift-crypto's `NOTICE.txt` also attributes test vectors from Google's
wycheproof project (Apache-2.0, https://github.com/C2SP/wycheproof) and a
derivation of files from SwiftNIO (Apache-2.0,
https://github.com/apple/swift-nio).

## MLX

- Licence: MIT
- MLX: Copyright © 2023 Apple Inc. https://github.com/ml-explore/mlx
- mlx-swift: Copyright (c) 2023 ml-explore.
  https://github.com/ml-explore/mlx-swift, version 0.32.3, revision
  `19601207e9a0de51e03ee6ec0c3c5f3784275075`
- mlx-swift-lm: Copyright (c) 2024 ml-explore.
  https://github.com/ml-explore/mlx-swift-lm, version 3.32.3, revision
  `3b339ad6e3b3f44c8121ecff5131c7fd55e075e6`

The app links MLXLLM, MLXLMCommon, MLXEmbedders and MLXHuggingFace from
mlx-swift-lm, which links MLX through mlx-swift. `build.sh` requires
MLX's `default.metallib` in the app.

## ONNX Runtime

- Licence: MIT. Copyright (c) Microsoft Corporation.
- Source: https://github.com/microsoft/onnxruntime
- Swift package: https://github.com/microsoft/onnxruntime-swift-package-manager,
  version 1.24.2, revision `b7fb7f7dea8a2469e6335d95a61b8f36d0dc83b2`

voice-core links it for Piper inference, and speech-core's SileroVAD
links it to run the VAD model. The app links both.

## Fonts

The pages under `docs/` self-host three fonts in `docs/fonts/`. They are
not copied into the app. The licence text is `docs/fonts/OFL.txt`.

- Inter. Copyright 2020 The Inter Project Authors
  (https://github.com/rsms/inter). SIL Open Font License 1.1.
- JetBrains Mono. Copyright 2020 The JetBrains Mono Project Authors
  (https://github.com/JetBrains/JetBrainsMono). SIL Open Font License 1.1.
- Space Grotesk. Copyright 2020 The Space Grotesk Project Authors
  (https://github.com/floriankarsten/space-grotesk). SIL Open Font License 1.1.

The files are the Latin subsets named in `docs/fonts.css`.

## MIT licence

Silero VAD, MLX, mlx-swift, mlx-swift-lm and ONNX Runtime are under the
MIT licence. Their copyright notices are above.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
