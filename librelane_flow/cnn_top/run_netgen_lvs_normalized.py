#!/usr/bin/env python3
"""Run Netgen LVS using a normalized Magic abstract-pad SPICE netlist."""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
from pathlib import Path

from normalize_magic_lvs_spice import DEFAULT_TOP_PORTS, normalize_spice


DEFAULT_NETGENS = (
    "/nix/store/d55q9bly3qrnbkif0sc6nmmvba3law57-netgen/bin/netgen",
    "/nix/store/kw3frc6fbv3zi2m9n0wv93y1nfiyjiy6-netgen-1.5.316/bin/netgen",
)


def find_netgen(explicit: str | None) -> str:
    if explicit:
        return explicit
    path_netgen = shutil.which("netgen")
    if path_netgen:
        return path_netgen
    for candidate in DEFAULT_NETGENS:
        if Path(candidate).exists():
            return candidate
    raise FileNotFoundError("netgen was not found in PATH or known Nix paths")


def rewrite_lvs_script(
    lvs_script: Path,
    original_layout_spice: Path,
    normalized_layout_spice: Path,
    normalized_report: Path,
    output_script: Path,
) -> None:
    text = lvs_script.read_text()
    original = str(original_layout_spice)
    normalized = str(normalized_layout_spice)

    if original in text:
        text = text.replace(original, normalized)
    else:
        text = re.sub(
            r"^set circuit1 \[readnet spice .*\]$",
            f"set circuit1 [readnet spice {normalized}]",
            text,
            count=1,
            flags=re.MULTILINE,
        )

    text = re.sub(
        r"\S+/reports/lvs\.netgen\.rpt",
        str(normalized_report),
        text,
        count=1,
    )

    output_script.write_text(text)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("run_dir", type=Path, help="LibreLane run directory")
    parser.add_argument("--top-cell", default="chip_top_spi")
    parser.add_argument("--netgen")
    parser.add_argument(
        "--top-ports",
        nargs="+",
        default=list(DEFAULT_TOP_PORTS),
        help="Canonical top-level port list for the extracted layout SPICE.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    run_dir = args.run_dir.resolve()
    top_cell = args.top_cell

    magic_spice = run_dir / "63-magic-spiceextraction" / f"{top_cell}.spice"
    lvs_dir = run_dir / "65-netgen-lvs"
    lvs_script = lvs_dir / "lvs_script.lvs"
    step_env = lvs_dir / "_env.tcl"
    normalized_spice = lvs_dir / f"{top_cell}.magic_normalized.spice"
    normalized_script = lvs_dir / "lvs_script.normalized.lvs"
    normalized_report = lvs_dir / "reports" / "lvs.normalized.rpt"

    for path in (magic_spice, lvs_script, step_env):
        if not path.exists():
            raise FileNotFoundError(path)

    normalized_spice.write_text(
        normalize_spice(magic_spice.read_text(), top_cell, tuple(args.top_ports))
    )
    rewrite_lvs_script(
        lvs_script,
        magic_spice,
        normalized_spice,
        normalized_report,
        normalized_script,
    )

    netgen = find_netgen(args.netgen)
    print(f"Normalized SPICE: {normalized_spice}")
    print(f"Normalized LVS script: {normalized_script}")
    print(f"Normalized report: {normalized_report}")
    print(f"Running: {netgen} -batch source {normalized_script}")

    env = os.environ.copy()
    env["_TCL_ENV_IN"] = str(step_env)
    result = subprocess.run(
        [netgen, "-batch", "source", str(normalized_script)],
        cwd=run_dir.parent.parent,
        env=env,
        text=True,
    )
    return result.returncode


if __name__ == "__main__":
    raise SystemExit(main())
