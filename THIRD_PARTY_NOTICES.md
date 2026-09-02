# Third-party notices

## CLIP tokenizer

`CLIPTokenizer.swift` and `clip-merges.txt` implement the OpenAI CLIP byte-pair
tokenizer. OpenAI CLIP is provided under the MIT License. The earlier Hugging
Face swift-coreml-transformers implementation is provided under the Apache
License 2.0.

- OpenAI CLIP: Copyright © 2021 OpenAI.
- Hugging Face swift-coreml-transformers: Copyright © 2023 Hugging Face.

The complete applicable license texts are included in `LICENSES/`.

## OpenAI CLIP model

Release builds download the SHA-256-pinned OpenAI CLIP ViT-B/32 checkpoint and
convert its image and text encoders to Core ML. The checkpoint and converted
model are distributed under OpenAI CLIP's MIT License, included in `LICENSES/`.
