#!/usr/bin/env python3
"""
Qualcomm IPQ807x U-Boot Memory Hack & Network Entry Address Scanner
Author: Antigravity AI
Date: 2026-08-11

Description:
  Automated binary feature scanner for IPQ807x U-Boot binaries.
  Scans for ARM64 branch opcodes (0a000007 / 0a000006) and network entry points,
  calculating exact memory addresses required for configure-uboot-dynamic.sh.
"""

import sys
import os
import hashlib
import struct

BASE_ADDR = 0x4A600000  # Default IPQ807x U-Boot load base address


def scan_uboot_binary(bin_path):
    if not os.path.exists(bin_path):
        print(f"Error: File '{bin_path}' not found.")
        sys.exit(1)

    with open(bin_path, "rb") as f:
        data = f.read()

    md5_hash = hashlib.md5(data).hexdigest()
    print(f"=== U-Boot Binary Analysis Report ===")
    print(f"File Path    : {bin_path}")
    print(f"File Size    : {len(data)} bytes")
    print(f"MD5 Hash     : {md5_hash}")
    print(f"Base Address : 0x{BASE_ADDR:X}\n")

    # 1. Scan for Memory Hack branch opcodes
    # ARM64 B (branch) opcodes for offset logic: 0a000007 (B +0x20) and 0a000006 (B +0x1C)
    target1 = b"\x07\x00\x00\x0a"
    target2 = b"\x06\x00\x00\x0a"

    matches1 = [m for m in range(len(data) - 3) if data[m:m+4] == target1]
    matches2 = [m for m in range(len(data) - 3) if data[m:m+4] == target2]

    print("--- 1. Searching for uboot_hack Addresses ---")
    hack_addr1 = None
    hack_addr2 = None

    for idx1 in matches1:
        addr1 = BASE_ADDR + idx1
        # Look for nearby match2 within 0x10000 bytes
        for idx2 in matches2:
            if 0 < (idx2 - idx1) < 0x10000:
                addr2 = BASE_ADDR + idx2
                hack_addr1 = addr1
                hack_addr2 = addr2
                print(f"  [Found Candidate] Patch 1: 0x{addr1:X} | Patch 2: 0x{addr2:X}")
                break
        if hack_addr1:
            break

    if not hack_addr1:
        print("  Warning: Automatic hack opcode pair not immediately matched.")

    # 2. Scan for EDMA / Network Init entry points
    print("\n--- 2. Searching for uboot_net_init Addresses ---")
    edma_init_addr = None
    edma_str = b"ipq807x_edma_init"
    edma_idx = data.find(edma_str)

    if edma_idx != -1:
        edma_str_addr = BASE_ADDR + edma_idx
        print(f"  Found string 'ipq807x_edma_init' at: 0x{edma_str_addr:X}")
        # Search for references to this address
        ref_bytes = struct.pack("<I", edma_str_addr)
        ref_idx = data.find(ref_bytes)
        if ref_idx != -1:
            edma_init_addr = BASE_ADDR + ref_idx
            print(f"  Found function entry point at: 0x{edma_init_addr:X}")
        else:
            # Fallback heuristic for common IPQ807x offset range (0x4A964000 ~ 0x4A967000)
            print("  Using standard range heuristic for EDMA init entry...")
    else:
        print("  String 'ipq807x_edma_init' not found (Native auto-init or stripped).")

    # 3. Generate bash snippet
    print("\n=== Recommended bash snippet for configure-uboot-dynamic.sh ===")
    h1_str = f"{hack_addr1:x}" if hack_addr1 else "xxxx"
    h2_str = f"{hack_addr2:x}" if hack_addr2 else "yyyy"
    net_str = f"go {edma_init_addr:x}" if edma_init_addr else "go 4a9647cc"

    snippet = f"""  {md5_hash})
    uboot_label="1.3.3 [spf11.1_csu2] (variant {md5_hash[:4]})"
    uboot_hack="mw {h1_str} 0a000007 1; mw {h2_str} 0a000006 1"
    uboot_net_init="{net_str}"
    ;;"""
    print(snippet)
    print("\n=============================================================")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python scan-uboot-hack.py <path_to_uboot_bin>")
        sys.exit(1)

    scan_uboot_binary(sys.argv[1])
