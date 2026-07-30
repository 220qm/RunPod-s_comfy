#!/usr/bin/env python3
"""Verify an installed torch is usable on every GPU ComfyPod targets.

Used twice during the image build: to accept/reject each candidate version
combination, and as the final gate after all nodes are installed (a node can
downgrade torch, which is the classic way a Blackwell pod dies at its first
CUDA call).

torch.cuda.get_arch_list() reads the compiled binary, so this needs no GPU and
works in CI. Exit 0 = usable, 1 = not usable (reason on stdout).

Usage: verify-torch.py [required_arch ...]      (default: sm_120 sm_89)
"""
import sys

TARGETS = {
    "sm_120": "RTX 5090 / RTX PRO 4500 (Blackwell)",
    "sm_89": "RTX 4090 / RTX 4500 Ada",
    "sm_86": "RTX 3090 / A10",
}
MIN_CUDA = (12, 8)  # Blackwell sm_120 needs CUDA >= 12.8


def main() -> int:
    required = sys.argv[1:] or ["sm_120", "sm_89"]

    try:
        import torch
    except Exception as exc:  # noqa: BLE001 - report anything, never traceback
        print(f"UNUSABLE: torch does not import ({exc})")
        return 1

    cuda = torch.version.cuda
    try:
        archs = torch.cuda.get_arch_list()
    except Exception as exc:  # noqa: BLE001
        print(f"UNUSABLE: cannot read arch list ({exc})")
        return 1

    print(f"torch {torch.__version__} / CUDA {cuda} / archs: {' '.join(archs) or '(none)'}")

    if not cuda:
        print("UNUSABLE: CPU-only build (no CUDA) — this index has no GPU wheel for that version")
        return 1
    if tuple(int(x) for x in cuda.split(".")[:2]) < MIN_CUDA:
        print(f"UNUSABLE: CUDA {cuda} is older than {'.'.join(map(str, MIN_CUDA))}")
        return 1

    missing = [
        a for a in required
        if not any(x in archs for x in (a, a.replace("sm_", "compute_")))
    ]
    if missing:
        for a in missing:
            print(f"UNUSABLE: no {a} kernels — {TARGETS.get(a, a)} would fail at its first CUDA call")
        return 1

    print(f"USABLE: covers {' '.join(required)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
