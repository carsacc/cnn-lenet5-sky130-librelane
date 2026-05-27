#!/usr/bin/env python3
"""Normalize Magic abstract-pad SPICE before Netgen LVS.

Magic extracts the sky130 I/O pads from abstract LEF/maglef views in this
flow. The real pad CDL shorts several pad-internal supply terminals, but the
abstract layout netlist exposes them as separate local nets. This script only
normalizes the top-level extracted circuit so Netgen compares the abstract
layout against the same logical pad connectivity present in the reference CDL.
"""

from __future__ import annotations

import argparse
import re
from pathlib import Path


DEFAULT_TOP_PORTS = (
    "pad_clk",
    "pad_reset",
    "pad_spi_cs_n",
    "pad_spi_miso",
    "pad_spi_mosi",
    "pad_spi_sclk",
    "vccd1",
    "vdda",
    "vddio",
    "vssa",
    "vssd1",
    "vssio",
)

UQ_NETS = {
    "vccd1": re.compile(r"^vccd1_uq\d+$"),
    "vssd1": re.compile(r"^vssd1_uq\d+$"),
    "vddio": re.compile(r"^vddio_uq\d+$"),
    "vssio": re.compile(r"^vssio_uq\d+$"),
}

PIN_NET_MAP = {
    "AMUXBUS_A": "amuxbus_a",
    "AMUXBUS_B": "amuxbus_b",
    "VCCD": "vccd1",
    "VCCHIB": "vccd1",
    "VCCD_PAD": "vccd1",
    "VSSD": "vssd1",
    "VSSD_PAD": "vssd1",
    "VDDIO": "vddio",
    "VDDIO_Q": "vddio",
    "VDDIO_PAD": "vddio",
    "VSWITCH": "vddio",
    "VSSIO": "vssio",
    "VSSIO_Q": "vssio",
    "VSSIO_PAD": "vssio",
    "VDDA": "vdda",
    "VSSA": "vssa",
}


def normalize_token(token: str) -> str:
    for net, pattern in UQ_NETS.items():
        if pattern.match(token):
            return net

    if "/" in token:
        pin = token.rsplit("/", 1)[1]
        return PIN_NET_MAP.get(pin, token)

    return token


def normalize_top_line(line: str) -> str:
    if line.lstrip().startswith("*"):
        return line
    return re.sub(r"\S+", lambda match: normalize_token(match.group(0)), line)


def format_top_subckt(top_cell: str, ports: tuple[str, ...]) -> list[str]:
    head = f".subckt {top_cell}"
    lines: list[str] = []
    current = head
    for port in ports:
        candidate = f"{current} {port}"
        if len(candidate) > 92 and current != head:
            lines.append(current + "\n")
            current = "+ " + port
        else:
            current = candidate
    lines.append(current + "\n")
    return lines


def normalize_spice(text: str, top_cell: str, ports: tuple[str, ...]) -> str:
    out: list[str] = []
    in_top = False
    skipping_top_header_continuations = False
    seen_top = False

    for line in text.splitlines(keepends=True):
        stripped = line.strip()

        if stripped.startswith(f".subckt {top_cell}"):
            out.extend(format_top_subckt(top_cell, ports))
            in_top = True
            skipping_top_header_continuations = True
            seen_top = True
            continue

        if skipping_top_header_continuations:
            if stripped.startswith("+"):
                continue
            skipping_top_header_continuations = False

        if in_top:
            if stripped.startswith(".ends"):
                out.append(line)
                in_top = False
            else:
                out.append(normalize_top_line(line))
        else:
            out.append(line)

    if not seen_top:
        raise ValueError(f"Top subckt '{top_cell}' was not found")

    return "".join(out)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("input_spice", type=Path)
    parser.add_argument("output_spice", type=Path)
    parser.add_argument("--top-cell", default="chip_top_spi")
    parser.add_argument(
        "--top-ports",
        nargs="+",
        default=list(DEFAULT_TOP_PORTS),
        help="Canonical top-level port list for the extracted layout SPICE.",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    normalized = normalize_spice(
        args.input_spice.read_text(),
        args.top_cell,
        tuple(args.top_ports),
    )
    args.output_spice.parent.mkdir(parents=True, exist_ok=True)
    args.output_spice.write_text(normalized)
    print(f"Wrote {args.output_spice}")


if __name__ == "__main__":
    main()
