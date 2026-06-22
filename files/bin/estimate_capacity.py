#!/usr/bin/env python3
"""
Rough pre-flight estimate of how many concurrent users (vLLM sequences) fit at a
given context length, for a model on this GPU.

This is an ESTIMATE to help you pick MAX_LEN / MAX_NUM_SEQS — vLLM's own boot
log ("Maximum concurrency for N tokens per request: X") is the authority. The
estimate can be off (CUDA-graph/activation overhead, paged-KV rounding, quant
weight layout), so it deliberately keeps a safety margin and rounds down.

Model used:  MAX_NUM_SEQS x MAX_LEN tokens must fit the KV-cache pool, where
    KV pool        ~= gpu_util * VRAM - weights - overhead
    KV bytes/token  = 2 (K,V) * layers * kv_heads * head_dim * 2 bytes (fp16)
    users(ctx)      = floor(KV pool / (ctx * KV bytes/token))

Weights are taken from the model's actual *.safetensors sizes on the Hub, so MoE
experts and quantization are accounted for. Best-effort; any failure prints a
notice and exits 0 so it never blocks setup.
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys


def _vram_gb_from_nvidia_smi() -> float | None:
    try:
        out = subprocess.check_output(
            ["nvidia-smi", "--query-gpu=memory.total", "--format=csv,noheader,nounits"],
            text=True, timeout=15,
        )
        return int(out.strip().splitlines()[0]) / 1024.0  # MiB -> GiB
    except Exception:
        return None


def _weights_bytes(model: str) -> int | None:
    """Sum of the model's *.safetensors file sizes on the Hub (~= VRAM weights)."""
    try:
        from huggingface_hub import HfApi
        info = HfApi().model_info(model, files_metadata=True)
        total = 0
        for sib in info.siblings or []:
            name = getattr(sib, "rfilename", "") or ""
            size = getattr(sib, "size", None)
            if name.endswith(".safetensors") and isinstance(size, int):
                total += size
        return total or None
    except Exception:
        return None


def _config(model: str) -> dict | None:
    try:
        from huggingface_hub import hf_hub_download
        with open(hf_hub_download(model, "config.json"), encoding="utf-8") as fh:
            return json.load(fh)
    except Exception:
        return None


def _kv_bytes_per_token(cfg: dict) -> int | None:
    try:
        layers = int(cfg["num_hidden_layers"])
        n_heads = int(cfg.get("num_attention_heads"))
        kv_heads = int(cfg.get("num_key_value_heads", n_heads))
        head_dim = int(cfg.get("head_dim", cfg["hidden_size"] // n_heads))
        # K and V, fp16/bf16 KV cache (2 bytes), per layer.
        return 2 * layers * kv_heads * head_dim * 2
    except Exception:
        return None


def main() -> int:
    p = argparse.ArgumentParser(description="Estimate concurrent-user capacity for a vLLM model.")
    p.add_argument("--model", required=True)
    p.add_argument("--gpu-util", type=float, default=0.90)
    p.add_argument("--vram-gb", type=float, default=None, help="Override total VRAM (GiB).")
    p.add_argument("--overhead-gb", type=float, default=2.0, help="Activation/CUDA-graph headroom.")
    args = p.parse_args()

    vram = args.vram_gb if args.vram_gb is not None else _vram_gb_from_nvidia_smi()
    weights = _weights_bytes(args.model)
    cfg = _config(args.model)
    kv_per_tok = _kv_bytes_per_token(cfg) if cfg else None

    if vram is None or weights is None or kv_per_tok is None:
        print("    (capacity estimate unavailable — vLLM's boot report will be authoritative)")
        return 0

    gib = 1024 ** 3
    kv_pool_bytes = args.gpu_util * vram * gib - weights - args.overhead_gb * gib
    model_max = int(cfg.get("max_position_embeddings", 32768)) if cfg else 32768

    print(f"    GPU VRAM ~{vram:.0f} GiB | weights ~{weights / gib:.1f} GiB | "
          f"gpu_util {args.gpu_util} | model max ctx {model_max}")
    if kv_pool_bytes <= 0:
        print("    Weights + overhead already exceed the GPU budget — needs a bigger GPU.")
        return 0

    max_tokens = kv_pool_bytes / kv_per_tok
    print(f"    KV pool ~{kv_pool_bytes / gib:.1f} GiB  (~{max_tokens / 1000:.0f}K tokens)")
    print("    Estimated concurrent users (rounded down, keep some headroom):")
    for ctx in (8192, 16384, 32768, 65536, 131072):
        if ctx > model_max:
            continue
        users = int(max_tokens // ctx)
        print(f"      context {ctx:>6}  ->  ~{users} user(s)")
    print("    NOTE: estimate only. Confirm with capacity_report.sh after the pod boots.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
