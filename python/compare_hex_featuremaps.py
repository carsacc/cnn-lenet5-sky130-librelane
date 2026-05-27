#!/usr/bin/env python3
"""
Comparador de mapas de características en HEX entre dos fuentes (golden vs RTL).

Uso:
  python3 python/compare_hex_featuremaps.py \
      --golden 'datos_hex_std/golden/conv1_relu_image_0_oc*.hex' \
      --rtl 'rtl/sim/rtl_conv1_image_0_oc*.hex' \
      --save-csv layer_figs/conv1_diff.csv --verbose

Genera métricas por canal: MAE, MSE, máximo absoluto, y conteo de elementos
distintos. Opcionalmente guarda un CSV.
"""

import argparse
import glob
import os
import re
from typing import Dict, List, Tuple

import numpy as np


def load_hex(path: str) -> np.ndarray:
    vals = [int(l.strip(), 16) for l in open(path) if l.strip()]
    return np.array(vals, dtype=np.uint8)


def oc_from_name(path: str) -> int:
    m = re.search(r"oc(\d+)", os.path.basename(path))
    return int(m.group(1)) if m else -1


def compare_sets(golden_glob: str, rtl_glob: str) -> Tuple[List[int], np.ndarray]:
    g_files = sorted(glob.glob(golden_glob))
    r_files = sorted(glob.glob(rtl_glob))
    g_map: Dict[int, str] = {oc_from_name(p): p for p in g_files}
    r_map: Dict[int, str] = {oc_from_name(p): p for p in r_files}
    ocs = sorted(set(g_map.keys()) & set(r_map.keys()))
    if not ocs:
        raise SystemExit("No se encontraron canales comunes (ocX) en los patrones dados.")
    metrics = []
    for oc in ocs:
        g = load_hex(g_map[oc])
        r = load_hex(r_map[oc])
        if g.size != r.size:
            raise SystemExit(f"Tamaños diferentes para oc{oc}: golden={g.size}, rtl={r.size}")
        d = r.astype(int) - g.astype(int)
        mae = float(np.mean(np.abs(d)))
        mse = float(np.mean(d * d))
        maxabs = int(np.max(np.abs(d)))
        nz = int(np.count_nonzero(d))
        metrics.append([mae, mse, maxabs, nz, int(g.size)])
    return ocs, np.array(metrics)


def main():
    ap = argparse.ArgumentParser(description="Compara dos conjuntos de HEX (golden vs RTL)")
    ap.add_argument('--golden', required=True, help="Patrón glob de los HEX golden (e.g., datos_hex_std/golden/conv1_relu_image_0_oc*.hex)")
    ap.add_argument('--rtl', required=True, help="Patrón glob de los HEX RTL (e.g., rtl/sim/rtl_conv1_image_0_oc*.hex)")
    ap.add_argument('--save-csv', help="Ruta para guardar un CSV con métricas")
    ap.add_argument('--verbose', action='store_true', help="Imprime métricas por canal")
    args = ap.parse_args()

    ocs, M = compare_sets(args.golden, args.rtl)
    if args.verbose:
        for oc, (mae, mse, maxabs, nz, n) in zip(ocs, M):
            print(f"oc{oc}: MAE={mae:.3f} MSE={mse:.3f} max|d|={int(maxabs)} nz={int(nz)}/{int(n)}")
    print(f"Resumen: canales={len(ocs)}  MAE_med={M[:,0].mean():.3f}  MSE_med={M[:,1].mean():.3f}  max|d|_max={int(M[:,2].max())}")

    if args.save_csv:
        os.makedirs(os.path.dirname(args.save_csv), exist_ok=True)
        with open(args.save_csv, 'w', encoding='utf-8') as fh:
            fh.write('oc,mae,mse,maxabs,nz,total\n')
            for oc, (mae, mse, maxabs, nz, n) in zip(ocs, M):
                fh.write(f"{oc},{mae:.6f},{mse:.6f},{int(maxabs)},{int(nz)},{int(n)}\n")
        print(f"CSV guardado en: {args.save_csv}")

if __name__ == '__main__':
    main()

