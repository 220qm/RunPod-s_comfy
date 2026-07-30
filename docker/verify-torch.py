#!/usr/bin/env python3
"""Verify an installed torch can actually run on every GPU ComfyPod targets.

Used twice during the image build: to accept/reject each candidate version
combination, and as the final gate after all nodes are installed (a node can
downgrade torch, which is the classic way a Blackwell pod dies at its first
CUDA call).

torch.cuda.get_arch_list() reads the compiled binary, so this needs no GPU and
works in CI. Exit 0 = usable, 1 = not usable (reason on stdout).

IMPORTANT — this deliberately does NOT require an exact "sm_<cc>" entry per
GPU. Official PyTorch wheels ship e.g. sm_80/sm_86/sm_90/sm_100/sm_120 and no
sm_89, yet run perfectly on an RTX 4090 (sm_89): CUDA cubins are forward
compatible inside a major version, and PTX can be JIT-compiled. See
pytorch/pytorch#95648. So the real rules are applied instead:

  a GPU sm_X.Y is covered when the binary has
    - sm_XY exactly, or
    - sm_XZ with the same major X and Z <= Y   (binary compatible), or
    - compute_AB PTX with AB <= XY             (JIT compatible)

Usage: verify-torch.py [sm_120 sm_89 ...]      (default: sm_120 sm_89)
"""
import sys

GPU_NAMES = {
    "sm_120": "RTX 5090 / RTX PRO 4500 (Blackwell)",
    "sm_89": "RTX 4090 / RTX 4500 Ada",
    "sm_86": "RTX 3090 / A10",
}
MIN_CUDA = (12, 8)  # Blackwell sm_120 needs CUDA >= 12.8


def parse_cc(entry: str):
    """'sm_120' / 'compute_120' -> (12, 0); None if unparseable."""
    for prefix in ("sm_", "compute_"):
        if entry.startswith(prefix):
            digits = entry[len(prefix):]
            if digits.isdigit() and len(digits) >= 2:
                # 120 -> major 12, minor 0;  86 -> major 8, minor 6
                return int(digits[:-1]), int(digits[-1])
    return None


def covered_by(target: str, archs: list) -> str:
    """Return the arch entry that makes `target` runnable, or ''."""
    want = parse_cc(target)
    if want is None:
        return ""
    # exact cubin
    for a in archs:
        if a == target:
            return a
    # closest cubin from the same major, not newer than the GPU
    same_major = [
        (parse_cc(a), a) for a in archs
        if a.startswith("sm_") and parse_cc(a)
        and parse_cc(a)[0] == want[0] and parse_cc(a)[1] <= want[1]
    ]
    if same_major:
        return f"{max(same_major)[1]} (binary compatible)"
    # newest PTX that can be JIT-compiled for this GPU. Restricted to the same
    # major version on purpose: PyTorch refuses a device whose generation is
    # absent from the arch list ("sm_120 is not compatible with the current
    # PyTorch installation"), so older-generation PTX must not count as cover.
    ptx = [
        (parse_cc(a), a) for a in archs
        if a.startswith("compute_") and parse_cc(a)
        and parse_cc(a)[0] == want[0] and parse_cc(a)[1] <= want[1]
    ]
    if ptx:
        return f"{max(ptx)[1]} (PTX JIT)"
    return ""


def main() -> int:
    required = sys.argv[1:] or ["sm_120", "sm_89"]

    try:
        import torch
    except Exception as exc:  # noqa: BLE001 - report anything, never traceback
        print(f"UNUSABLE: torch does not import ({exc})")
        return 1

    cuda = torch.version.cuda
    try:
        archs = list(torch.cuda.get_arch_list())
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

    ok = True
    for target in required:
        via = covered_by(target, archs)
        name = GPU_NAMES.get(target, target)
        if via:
            print(f"  {target:<8} covered by {via:<28} -> {name}")
        else:
            print(f"  {target:<8} NOT COVERED — {name} would fail at its first CUDA call")
            ok = False

    print("USABLE: covers " + " ".join(required) if ok else "UNUSABLE: missing GPU coverage")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
