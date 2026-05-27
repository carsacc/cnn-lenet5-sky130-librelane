#!/usr/bin/env python3
"""Visualiza dumps de capas JSON como mapas de calor o gráficos de barras."""

import argparse
import json
import os

try:
    import numpy as np
    import matplotlib.pyplot as plt
except ImportError as exc:
    raise SystemExit(
        "Este script requiere numpy y matplotlib. Instálalos e inténtalo de nuevo."
    ) from exc


def _as_numpy(array_like):
    """Convierte listas anidadas a ndarray y detecta dimensiones útiles."""
    return np.asarray(array_like)


def _visualize_1d(ax, values, layer_name):
    ax.bar(range(len(values)), values)
    ax.set_title(layer_name)
    ax.set_xlabel("Índice")
    ax.set_ylabel("Valor")


def _visualize_2d(ax, matrix, layer_name, cmap):
    im = ax.imshow(matrix, cmap=cmap, aspect="auto")
    ax.set_title(layer_name)
    plt.colorbar(im, ax=ax, fraction=0.046, pad=0.04)


def _visualize_3d(fig, tensor, layer_name, cmap):
    channels = tensor.shape[0]
    cols = min(8, channels)
    rows = int(np.ceil(channels / cols))
    for idx in range(channels):
        ax = fig.add_subplot(rows, cols, idx + 1)
        ax.imshow(tensor[idx], cmap=cmap, aspect="auto")
        ax.set_title(f"{layer_name}[{idx}]")
        ax.axis("off")
    fig.tight_layout()


def visualize_dump(path, save_dir=None, cmap="RdBu", show=False):
    with open(path, "r", encoding="utf-8") as fh:
        payload = json.load(fh)

    for layer_name, values in payload.items():
        array = _as_numpy(values)
        if array.ndim == 1:
            fig, ax = plt.subplots(figsize=(8, 4))
            _visualize_1d(ax, array, layer_name)
            fig.tight_layout()
        elif array.ndim == 2:
            fig, ax = plt.subplots(figsize=(6, 6))
            _visualize_2d(ax, array, layer_name, cmap)
        elif array.ndim == 3:
            fig = plt.figure(figsize=(8, 3 * np.ceil(array.shape[0] / 4)))
            _visualize_3d(fig, array, layer_name, cmap)
        else:
            print(f"[WARN] Saltando {layer_name}: forma no soportada {array.shape}")
            continue

        if save_dir:
            os.makedirs(save_dir, exist_ok=True)
            outfile = os.path.join(save_dir, f"{os.path.basename(path)}_{layer_name}.png")
            fig.savefig(outfile, dpi=150)
            print(f"Guardado: {outfile}")

        if show:
            plt.show()
        else:
            plt.close(fig)


def main():
    parser = argparse.ArgumentParser(description="Visualiza capas desde layer_dump_*.json")
    parser.add_argument("paths", nargs="+", help="Rutas a archivos JSON a visualizar")
    parser.add_argument("--save-dir", help="Directorio para guardar PNG por capa")
    parser.add_argument("--show", action="store_true", help="Muestra las figuras en pantalla")
    parser.add_argument("--cmap", default="RdBu", help="Colormap de matplotlib para mapas de calor")
    args = parser.parse_args()

    for path in args.paths:
        visualize_dump(path, save_dir=args.save_dir, cmap=args.cmap, show=args.show)


if __name__ == "__main__":
    main()

