#!/usr/bin/env python3
"""Download and convert the SHA-pinned OpenAI CLIP ViT-B/32 checkpoint."""

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path
import shutil
import tempfile
import urllib.request

import coremltools as ct
import numpy as np
import open_clip
import torch


CHECKPOINT_SHA256 = "40d365715913c9da98579312b702a82c18be219cc2a73407c4526f58eba950af"
CHECKPOINT_URL = (
    "https://openaipublic.azureedge.net/clip/models/"
    f"{CHECKPOINT_SHA256}/ViT-B-32.pt"
)


class ImageEncoder(torch.nn.Module):
    def __init__(self, model: torch.nn.Module) -> None:
        super().__init__()
        self.visual = model.visual
        self.register_buffer(
            "mean", torch.tensor((0.48145466, 0.4578275, 0.40821073)).view(1, 3, 1, 1)
        )
        self.register_buffer(
            "std", torch.tensor((0.26862954, 0.26130258, 0.27577711)).view(1, 3, 1, 1)
        )

    def forward(self, image: torch.Tensor) -> torch.Tensor:
        return self.visual((image - self.mean) / self.std)


class TextEncoder(torch.nn.Module):
    def __init__(self, model: torch.nn.Module) -> None:
        super().__init__()
        self.token_embedding = model.token_embedding
        self.positional_embedding = model.positional_embedding
        self.transformer = model.transformer
        self.ln_final = model.ln_final
        self.text_projection = model.text_projection
        self.register_buffer("attn_mask", model.attn_mask)

    def forward(self, text: torch.Tensor) -> torch.Tensor:
        values = self.token_embedding(text)
        values = values + self.positional_embedding
        values = self.transformer(values, attn_mask=self.attn_mask)
        values = self.ln_final(values)
        pooled = values[torch.arange(values.shape[0]), text.argmax(dim=-1)]
        return pooled @ self.text_projection


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def download_checkpoint(cache_directory: Path) -> Path:
    cache_directory.mkdir(parents=True, exist_ok=True)
    checkpoint = cache_directory / "ViT-B-32.pt"
    if checkpoint.exists() and sha256(checkpoint) == CHECKPOINT_SHA256:
        return checkpoint
    checkpoint.unlink(missing_ok=True)
    with tempfile.NamedTemporaryFile(dir=cache_directory, delete=False) as temporary:
        temporary_path = Path(temporary.name)
    try:
        urllib.request.urlretrieve(CHECKPOINT_URL, temporary_path)
        actual = sha256(temporary_path)
        if actual != CHECKPOINT_SHA256:
            raise RuntimeError(
                f"OpenAI checkpoint SHA-256 mismatch: expected {CHECKPOINT_SHA256}, got {actual}"
            )
        temporary_path.replace(checkpoint)
    finally:
        temporary_path.unlink(missing_ok=True)
    return checkpoint


def load_model(checkpoint: Path) -> torch.nn.Module:
    archive = torch.jit.load(str(checkpoint), map_location="cpu").eval()
    state = archive.state_dict()
    for metadata_key in ("input_resolution", "context_length", "vocab_size"):
        state.pop(metadata_key, None)
    model = open_clip.create_model(
        "ViT-B-32", pretrained=None, force_quick_gelu=True
    ).eval()
    model.load_state_dict(state, strict=True)
    return model


def convert(checkpoint: Path, output: Path) -> None:
    output.mkdir(parents=True, exist_ok=True)
    image_path = output / "openai_clip_vit_b32_image.mlpackage"
    text_path = output / "openai_clip_vit_b32_text.mlpackage"
    if image_path.exists() and text_path.exists():
        return
    for partial_path in (image_path, text_path):
        if partial_path.is_dir():
            shutil.rmtree(partial_path)
        else:
            partial_path.unlink(missing_ok=True)

    model = load_model(checkpoint)
    # Core ML Tools 9 cannot lower PyTorch's fused native MHA operator. The
    # reference implementation produces the same result and traces to the
    # converter-supported primitive attention operations.
    torch.backends.mha.set_fastpath_enabled(False)
    image_example = torch.zeros((1, 3, 224, 224), dtype=torch.float32)
    text_example = torch.zeros((1, 77), dtype=torch.int32)
    with torch.inference_mode():
        image_trace = torch.jit.trace(ImageEncoder(model).eval(), image_example)
        text_trace = torch.jit.trace(TextEncoder(model).eval(), text_example)

    image_model = ct.convert(
        image_trace,
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS15,
        compute_precision=ct.precision.FLOAT16,
        inputs=[
            ct.ImageType(
                name="image",
                shape=image_example.shape,
                color_layout=ct.colorlayout.RGB,
                scale=1.0 / 255.0,
            )
        ],
        outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
    )
    image_model.author = "OpenAI"
    image_model.license = "MIT"
    image_model.short_description = "OpenAI CLIP ViT-B/32 image encoder"
    image_model.save(image_path)

    text_model = ct.convert(
        text_trace,
        convert_to="mlprogram",
        minimum_deployment_target=ct.target.macOS15,
        compute_precision=ct.precision.FLOAT16,
        inputs=[ct.TensorType(name="text", shape=text_example.shape, dtype=np.int32)],
        outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
    )
    text_model.author = "OpenAI"
    text_model.license = "MIT"
    text_model.short_description = "OpenAI CLIP ViT-B/32 text encoder"
    text_model.save(text_path)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    parser.add_argument("--cache", type=Path)
    arguments = parser.parse_args()
    cache = arguments.cache or arguments.output.parent / "openai-clip-cache"
    convert(download_checkpoint(cache), arguments.output)


if __name__ == "__main__":
    main()
