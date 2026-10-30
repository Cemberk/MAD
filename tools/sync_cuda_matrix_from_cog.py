#!/usr/bin/env python3
"""Regenerate compat/cuda.json from replicate/cog's compatibility matrices.

Cog (https://github.com/replicate/cog, Apache-2.0) maintains which torch builds
exist for which CUDA versions, and which nvidia/cuda base images exist. madengine
image_spec cards resolve NVIDIA builds against that data, so MAD vendors a
filtered copy pinned to a cog commit instead of fetching it at build time.

Usage:
    python tools/sync_cuda_matrix_from_cog.py            # latest cog main
    python tools/sync_cuda_matrix_from_cog.py --ref <sha or tag>

Review the diff of compat/cuda.json and commit it.
"""

import argparse
import json
import os
import re
import urllib.request

COG = "replicate/cog"
FILES = {
    "torch": "pkg/config/torch_compatibility.json",
    "base_images": "pkg/config/cuda_compatibility.json",
}
MIN_CUDA = (11, 8)
MIN_TORCH = (2, 0)
MIN_UBUNTU = (22, 4)
OUT = os.path.join(os.path.dirname(__file__), "..", "compat", "cuda.json")


def _get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "MAD-cog-sync"})
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.load(resp)


def _ver(text):
    return tuple(int(p) for p in re.findall(r"\d+", (text or "").split("+")[0]))


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--ref", default="main", help="cog branch, tag or commit")
    args = parser.parse_args()

    commit = _get(f"https://api.github.com/repos/{COG}/commits/{args.ref}")["sha"]
    raw = f"https://raw.githubusercontent.com/{COG}/{commit}/"

    torch = [
        {k: e.get(k) for k in
         ("Torch", "Torchvision", "Torchaudio", "ExtraIndexURL", "CUDA", "Pythons")}
        for e in _get(raw + FILES["torch"])
        if e.get("CUDA")
        and _ver(e["CUDA"]) >= MIN_CUDA
        and _ver(e["Torch"]) >= MIN_TORCH
    ]
    base_images = [
        {k: e.get(k) for k in ("Tag", "CUDA", "CuDNN", "IsDevel", "Ubuntu")}
        for e in _get(raw + FILES["base_images"])
        if _ver(e["CUDA"]) >= MIN_CUDA and _ver(e["Ubuntu"]) >= MIN_UBUNTU
    ]

    # Default: the newest CUDA that has both a torch build and a devel base image.
    devel = {_ver(b["CUDA"])[:2] for b in base_images if b.get("IsDevel")}
    usable = [e["CUDA"] for e in torch if _ver(e["CUDA"])[:2] in devel]
    default_cuda = max(usable, key=_ver) if usable else None

    matrix = {
        "_source": {
            "repo": f"https://github.com/{COG}",
            "commit": commit,
            "files": list(FILES.values()),
            "license": "Apache-2.0",
            "generated_by": "tools/sync_cuda_matrix_from_cog.py",
            "filter": "CUDA >= 11.8, torch >= 2.0, Ubuntu >= 22.04",
        },
        "default_cuda": default_cuda,
        "torch": sorted(torch, key=lambda e: (_ver(e["Torch"]), _ver(e["CUDA"]))),
        "base_images": sorted(base_images, key=lambda e: (_ver(e["CUDA"]), e["Tag"])),
    }
    with open(OUT, "w", newline="\n") as f:
        json.dump(matrix, f, indent=2)
        f.write("\n")
    print(
        f"wrote {os.path.normpath(OUT)}: cog {commit[:12]}, {len(torch)} torch builds, "
        f"{len(base_images)} base images, default CUDA {default_cuda}"
    )


if __name__ == "__main__":
    main()
