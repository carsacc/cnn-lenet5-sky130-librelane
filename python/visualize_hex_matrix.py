#!/usr/bin/env python3
"""
Visualiza archivos .hex como matrices coloreadas, infiriendo parámetros automáticamente.

Características:
- Acepta uno o varios archivos .hex.
- Infere bits (8/16/32/...) a partir del ancho de los dígitos hex.
- Infere signo automáticamente: si hay valores >= 2^(bits-1) se interpreta como signed;
  si el nombre contiene "relu" o "pool" se prefiere unsigned; se puede forzar con flags.
- Reorganiza en matriz (H x W). Si no se especifica, intenta cuadrado (sqrt(n));
  si no es cuadrado, usa heurística por nombre de archivo (conv1/2/3, pool1/2) y si no,
  cae a 1xN.
- Dibuja con matplotlib usando un colormap configurable y colorbar.
- Opción de escala común (vmin/vmax) para múltiples archivos.
- Guarda PNGs opcionalmente en un directorio de salida.

Ejemplos:
- Conv1 RTL (26x26), sin parámetros manuales:
  python3 python/visualize_hex_matrix.py rtl/sim/rtl_conv1_image_0_oc0.hex --title "RTL Conv1 OC0" --save-dir layer_figs
- Golden por canal (auto-detección de 26x26):
  python3 python/visualize_hex_matrix.py datos_hex_std/golden/conv1_relu_image_0_oc*.hex --common-scale --cols 8 --save-dir layer_figs
"""

import argparse
import os
import re
from typing import List, Tuple, Optional

try:
    import numpy as np
    import matplotlib.pyplot as plt
except ImportError as exc:
    raise SystemExit("Este script requiere numpy y matplotlib. Instálalos e inténtalo de nuevo.") from exc


def hex_to_int(value_hex: str, bits: int = 8, signed: bool = True) -> int:
    v = int(value_hex, 16)
    if not signed:
        return v
    # two's complement to signed
    sign_bit = 1 << (bits - 1)
    mask = (1 << bits) - 1
    v &= mask
    return v - (1 << bits) if (v & sign_bit) else v


def _read_hex_lines(path: str) -> List[str]:
    with open(path, 'r', encoding='utf-8') as fh:
        # Filtra líneas no vacías; acepta formatos tipo "0xAA" o "aa".
        lines = []
        for raw in fh:
            s = raw.strip()
            if not s:
                continue
            # ignora etiquetas tipo '@00000100' (no presentes en este repo, pero común en mem files)
            if s.startswith('@'):
                continue
            # quita prefijo 0x si aparece
            if s.lower().startswith('0x'):
                s = s[2:]
            # valida que sean solo dígitos hex
            if not re.fullmatch(r"[0-9a-fA-F]+", s):
                continue
            lines.append(s)
    return lines


def _infer_bits_from_lines(hex_lines: List[str]) -> int:
    if not hex_lines:
        return 8
    # Usa la longitud típica de dígitos hex (mediana) para ser robusto.
    lengths = sorted(len(x) for x in hex_lines)
    mid = lengths[len(lengths) // 2]
    bits = max(4, mid * 4)
    return bits


def _infer_signed_from_lines(hex_lines: List[str], bits: int, filename: str) -> bool:
    if not hex_lines:
        return True
    # Si hay valores en el rango negativo (>= 2^(bits-1)) asumimos signed.
    threshold = 1 << (bits - 1)
    try:
        if any(int(s, 16) >= threshold for s in hex_lines):
            return True
    except ValueError:
        pass
    # Heurística por nombre
    name = filename.lower()
    if 'relu' in name or 'pool' in name:
        return False
    # Por defecto, signed en capas intermedias; unsigned si parece claramente vector de clases.
    if 'logit' in name or 'softmax' in name:
        return True
    return True


def load_hex_file_with_inference(path: str, bits_opt: Optional[int], signed_opt: Optional[bool]) -> Tuple[List[int], int, bool]:
    hex_lines = _read_hex_lines(path)
    bits = bits_opt if bits_opt is not None else _infer_bits_from_lines(hex_lines)
    signed = signed_opt if signed_opt is not None else _infer_signed_from_lines(hex_lines, bits, os.path.basename(path))
    values = [hex_to_int(s, bits=bits, signed=signed) for s in hex_lines]
    return values, bits, signed


def infer_shape(length: int, width: Optional[int], height: Optional[int], filename: str = "") -> Tuple[int, int]:
    if width and height:
        if width * height != length:
            raise ValueError(f"Dimensiones no coinciden: {width}x{height} != {length}")
        return height, width
    # intentar cuadrado perfecto
    r = int(round(length ** 0.5))
    if r * r == length:
        return r, r
    # heurística basada en el nombre de archivo para tamaños típicos
    name = filename.lower()
    known = [
        ("conv1", 26, 26),
        ("pool1", 13, 13),
        ("conv2", 11, 11),
        ("pool2", 5, 5),
        ("conv3", 3, 3),
    ]
    for key, h, w in known:
        if key in name and h * w == length:
            return h, w
    # vectores típicos
    if any(k in name for k in ("fc", "logit", "gap")):
        return 1, length
    # fallback: matriz de 1 x N
    return 1, length


def visualize_matrix(ax, matrix: np.ndarray, title: str, cmap: str, vmin: Optional[float], vmax: Optional[float]):
    im = ax.imshow(matrix, cmap=cmap, aspect='equal', vmin=vmin, vmax=vmax, interpolation='nearest')
    ax.set_title(title)
    ax.set_xticks([])
    ax.set_yticks([])
    return im


def main():
    p = argparse.ArgumentParser(description="Visualiza .hex como matrices coloreadas (autodetección de parámetros)")
    p.add_argument('paths', nargs='+', help="Rutas de archivos .hex (1 byte por línea)")
    p.add_argument('--width', type=int, help="Ancho de la matriz (columnas)")
    p.add_argument('--height', type=int, help="Alto de la matriz (filas)")
    p.add_argument('--bits', type=int, help="Tamaño en bits. Si se omite, se infiere del archivo")
    sign_grp = p.add_mutually_exclusive_group()
    sign_grp.add_argument('--signed', dest='signed', action='store_true', help="Forzar interpretación con signo (two's complement)")
    sign_grp.add_argument('--unsigned', dest='signed', action='store_false', help="Forzar interpretación sin signo")
    p.set_defaults(signed=None)
    p.add_argument('--cmap', default='RdBu', help="Colormap de matplotlib (p. ej. RdBu, viridis)")
    p.add_argument('--common-scale', action='store_true', help="Usar vmin/vmax comunes para todos los archivos")
    p.add_argument('--save-dir', help="Directorio donde guardar PNGs")
    p.add_argument('--show', action='store_true', help="Mostrar en pantalla")
    p.add_argument('--cols', type=int, default=8, help="Columnas del grid cuando hay múltiples archivos")
    p.add_argument('--title', help="Título (si un solo archivo)")
    p.add_argument('--verbose', action='store_true', help="Imprime los parámetros inferidos por archivo")
    args = p.parse_args()

    # Carga todos los archivos
    matrices = []
    titles = []
    inferred_params = []  # (bits, signed, h, w)
    for path in args.paths:
        vals, bits_used, signed_used = load_hex_file_with_inference(path, bits_opt=args.bits, signed_opt=args.signed)
        h, w = infer_shape(len(vals), args.width, args.height, filename=os.path.basename(path))
        mat = np.array(vals, dtype=np.int16).reshape(h, w)
        matrices.append(mat)
        titles.append(os.path.basename(path))
        inferred_params.append((bits_used, signed_used, h, w))

    if args.verbose:
        for t, (b, s, h, w) in zip(titles, inferred_params):
            print(f"{t}: bits={b}, signed={s}, shape={h}x{w}")

    # Escala común
    vmin = vmax = None
    if args.common_scale and matrices:
        vmin = min(int(m.min()) for m in matrices)
        vmax = max(int(m.max()) for m in matrices)

    # Visualización
    if len(matrices) == 1:
        fig, ax = plt.subplots(figsize=(6, 6))
        title = args.title or titles[0]
        im = visualize_matrix(ax, matrices[0], title, args.cmap, vmin, vmax)
        plt.colorbar(im, ax=ax, fraction=0.046, pad=0.04)
        fig.tight_layout()
        if args.save_dir:
            os.makedirs(args.save_dir, exist_ok=True)
            out = os.path.join(args.save_dir, f"{os.path.splitext(titles[0])[0]}.png")
            fig.savefig(out, dpi=150)
            print(f"Guardado: {out}")
        if args.show:
            plt.show()
        else:
            plt.close(fig)
        return

    # Grid para múltiples
    N = len(matrices)
    cols = max(1, args.cols)
    rows = int(np.ceil(N / cols))
    fig, axes = plt.subplots(rows, cols, figsize=(cols * 3, rows * 3))
    axes = np.atleast_2d(axes)
    ims = []
    for i, (mat, title) in enumerate(zip(matrices, titles)):
        r = i // cols
        c = i % cols
        ax = axes[r, c]
        im = visualize_matrix(ax, mat, title, args.cmap, vmin, vmax)
        ims.append(im)
    # Apagar axes vacíos
    for j in range(N, rows * cols):
        r = j // cols
        c = j % cols
        axes[r, c].axis('off')
    # Colorbar común si hay escala común
    if args.common_scale and ims:
        fig.colorbar(ims[0], ax=axes.ravel().tolist(), fraction=0.02, pad=0.02)
    fig.tight_layout()
    if args.save_dir:
        os.makedirs(args.save_dir, exist_ok=True)
        base = os.path.commonprefix([os.path.splitext(t)[0] for t in titles]) or "hex_grid"
        out = os.path.join(args.save_dir, f"{base}_grid.png")
        fig.savefig(out, dpi=150)
        print(f"Guardado: {out}")
    if args.show:
        plt.show()
    else:
        plt.close(fig)


if __name__ == '__main__':
    main()
