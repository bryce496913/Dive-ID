#!/usr/bin/env python3
"""Photo model comparison (Docs/PhotoModelCandidates.md): convert candidate image models
to Core ML on a Mac, check parity with the original PyTorch model, and compute BioCLIP's
species-name text vectors. Evaluation only: nothing here goes into the app.

  python -I Tools/PhotoModels/convert.py --models <downloads> --out <dir> [--fixtures N]

<downloads> holds bioclip/ (imageomics/bioclip) and dinov2-small/ (facebook/dinov2-small).
For each model, <out>/<name>/ gets model.mlpackage (float16), model-8bit.mlpackage (8-bit
weights), parity.json and, for BioCLIP, text-vectors.json. Versions: requirements.txt.
"""
import argparse
import json
import math
import sys
from pathlib import Path

import coremltools as ct
import numpy as np
import torch
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
GLOBAL = ROOT / "DiveID/Resources/IdentificationPacks/Global"
SIZE = 224
CLIP_MEAN, CLIP_STD = [0.48145466, 0.4578275, 0.40821073], [0.26862954, 0.26130258, 0.27577711]
IMAGENET_MEAN, IMAGENET_STD = [0.485, 0.456, 0.406], [0.229, 0.224, 0.225]


class Tower(torch.nn.Module):
    """RGB in 0..1 at 224 × 224 → L2-normalized embedding; normalization is inside the model."""
    def __init__(self, model, kind, mean, std):
        super().__init__()
        self.model, self.kind = model, kind  # registered, so its weights are parameters, not constants
        self.register_buffer("mean", torch.tensor(mean).view(1, 3, 1, 1))
        self.register_buffer("std", torch.tensor(std).view(1, 3, 1, 1))

    def forward(self, image):
        x = (image - self.mean) / self.std
        embedding = self.model.encode_image(x) if self.kind == "clip" else self.model(pixel_values=x).pooler_output
        return embedding / embedding.norm(dim=-1, keepdim=True)


def bioclip(downloads):
    import open_clip
    model = open_clip.create_model("ViT-B-16", pretrained=str(downloads / "bioclip/open_clip_pytorch_model.bin"), load_weights_only=True)
    model.eval()
    return model, Tower(model, "clip", CLIP_MEAN, CLIP_STD).eval()


def dinov2(downloads):
    from transformers import Dinov2Model
    model = Dinov2Model.from_pretrained(str(downloads / "dinov2-small"), use_safetensors=True)
    model.eval()
    # DINOv2 resizes its position embeddings (bicubic) to the input size on every call, which
    # Core ML can't convert. The input is always 224 × 224, so resize once and keep the result.
    embeddings = model.embeddings
    patches = (SIZE // model.config.patch_size) ** 2
    with torch.no_grad():
        fixed = embeddings.interpolate_pos_encoding(torch.zeros(1, patches + 1, model.config.hidden_size), SIZE, SIZE).clone()
    embeddings.register_buffer("fixed_position_embeddings", fixed)
    embeddings.interpolate_pos_encoding = lambda _embeddings, _height, _width: embeddings.fixed_position_embeddings
    return model, Tower(model, "dinov2", IMAGENET_MEAN, IMAGENET_STD).eval()


def fixture(path):
    """Resize the shorter side to 224 (bicubic) and centre-crop: both models' preprocessing."""
    image = Image.open(path).convert("RGB")
    scale = SIZE / min(image.size)
    image = image.resize((max(SIZE, round(image.width * scale)), max(SIZE, round(image.height * scale))), Image.BICUBIC)
    left, top = (image.width - SIZE) // 2, (image.height - SIZE) // 2
    return image.crop((left, top, left + SIZE, top + SIZE))


def to_tensor(image):
    return torch.from_numpy(np.asarray(image, dtype=np.float32) / 255).permute(2, 0, 1).unsqueeze(0)


def convert(tower, name):
    example = torch.rand(1, 3, SIZE, SIZE)
    traced = torch.jit.trace(tower, example, check_trace=False)
    model = ct.convert(traced, inputs=[ct.ImageType(name="image", shape=example.shape, scale=1 / 255, color_layout=ct.colorlayout.RGB)],
                       outputs=[ct.TensorType(name="embedding")], minimum_deployment_target=ct.target.iOS17,
                       compute_precision=ct.precision.FLOAT16, convert_to="mlprogram")
    model.short_description = f"{name} image embedding (Dive ID photo model comparison; evaluation only)"
    return model


def quantized(model):
    from coremltools.optimize.coreml import OpLinearQuantizerConfig, OptimizationConfig, linear_quantize_weights
    return linear_quantize_weights(model, OptimizationConfig(global_config=OpLinearQuantizerConfig(mode="linear_symmetric")))


def parity(tower, mlmodels, images):
    """Cosine between the PyTorch embedding and each Core ML model's, per fixture image."""
    rows = []
    for path in images:
        image = fixture(path)
        with torch.no_grad():
            reference = tower(to_tensor(image)).numpy().ravel()
        row = {"image": path.name}
        for label, mlmodel in mlmodels.items():
            out = np.asarray(mlmodel.predict({"image": image})["embedding"], dtype=np.float64).ravel()
            row[label] = float(np.dot(reference, out) / (np.linalg.norm(reference) * np.linalg.norm(out)))
        rows.append(row)
    return {label: {"minimumCosine": min(r[label] for r in rows), "images": len(rows)} for label in mlmodels} | {"perImage": rows}


def size(path):
    return sum(f.stat().st_size for f in Path(path).rglob("*") if f.is_file())


def text_prompt(record):
    """BioCLIP's taxonomic-plus-common-name prompt, from the catalogue's own taxonomy."""
    t = record.get("taxonomy") or {}
    name = (t.get("acceptedScientificName") or record["scientificName"]).split()
    ranks = [t.get("taxonomicClass"), t.get("order"), t.get("family"), name[0] if name else None, name[1] if len(name) > 1 else None]
    return f"a photo of {' '.join(r for r in ranks if r)} with common name {record['commonName']}."


def text_vectors(model, records, batch=256):
    import open_clip
    tokenizer = open_clip.get_tokenizer("ViT-B-16")  # the standard CLIP tokenizer, shipped with OpenCLIP
    out = []
    for start in range(0, len(records), batch):
        chunk = records[start:start + batch]
        with torch.no_grad():
            vectors = model.encode_text(tokenizer([text_prompt(r) for r in chunk]))
            vectors = vectors / vectors.norm(dim=-1, keepdim=True)
        out += [{"speciesID": r["id"], "prompt": text_prompt(r), "vector": [round(float(v), 7) for v in vec]} for r, vec in zip(chunk, vectors)]
    return out


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--models", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--fixtures", type=int, default=8)
    parser.add_argument("--only", choices=["bioclip", "dinov2"])
    args = parser.parse_args(argv)
    torch.manual_seed(0)
    records = json.loads((GLOBAL / "Creatures.json").read_text())
    photos = sorted(r["bundledImage"]["fileName"] for r in records if r.get("bundledImage"))
    step = max(1, len(photos) // args.fixtures)
    images = [GLOBAL / "Images" / f for f in photos[::step][:args.fixtures]]
    for name, load in (("bioclip", bioclip), ("dinov2", dinov2)):
        if args.only and args.only != name:
            continue
        out = args.out / name
        out.mkdir(parents=True, exist_ok=True)
        model, tower = load(args.models)
        mlmodel = convert(tower, name)
        mlmodel.save(str(out / "model.mlpackage"))
        small = quantized(mlmodel)
        small.save(str(out / "model-8bit.mlpackage"))
        report = parity(tower, {"float16": mlmodel, "8bit": small}, images)
        report |= {"bytes": {"float16": size(out / "model.mlpackage"), "8bit": size(out / "model-8bit.mlpackage")},
                   "parameters": sum(p.numel() for p in (tower.model.visual.parameters() if name == "bioclip" else tower.parameters())), "versions": {
                       "torch": torch.__version__, "coremltools": ct.__version__, "numpy": np.__version__}}
        (out / "parity.json").write_text(json.dumps(report, indent=1) + "\n")
        print(name, json.dumps({k: report[k] for k in ("float16", "8bit", "bytes", "parameters")}), flush=True)
        if name == "bioclip":
            (out / "text-vectors.json").write_text(json.dumps(text_vectors(model, records)))
            print("bioclip text vectors:", len(records), flush=True)
        del model, tower, mlmodel, small
    return 0


if __name__ == "__main__":
    sys.exit(main())
