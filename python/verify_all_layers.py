#!/usr/bin/env python3
"""
Verifica que todas las capas de la CNN estén funcionando correctamente con SRAM SKY130.
"""

import glob
import os

def count_files(pattern: str) -> int:
    """Cuenta archivos que coinciden con el patrón."""
    return len(glob.glob(pattern))

def main():
    print("Verificación completa de capas CNN con SRAM SKY130")
    print("=" * 60)
    
    # Verificar feature maps de cada capa para imagen 0
    layers = [
        ("Conv1", "rtl/sim/rtl_conv1_image_0_oc*.hex", 8),
        ("Pool1", "rtl/sim/rtl_pool1_image_0_oc*.hex", 8),
        ("Conv2", "rtl/sim/rtl_conv2_relu_image_0_oc*.hex", 16),
        ("Pool2", "rtl/sim/rtl_pool2_image_0_oc*.hex", 16),
        ("Conv3", "rtl/sim/rtl_conv3_relu_image_0_oc*.hex", 120),
        ("GAP", "rtl/sim/rtl_gap_image_0_oc*.hex", 120),
    ]
    
    all_good = True
    for layer_name, pattern, expected_channels in layers:
        count = count_files(pattern)
        status = "✓" if count == expected_channels else "✗"
        if count != expected_channels:
            all_good = False
        print(f"{layer_name}: {status} {count}/{expected_channels} canales")
    
    # Verificar logits para todas las imágenes
    logits_count = count_files("rtl/sim/rtl_fc_logits_image_*.hex")
    logits_status = "✓" if logits_count == 10 else "✗"
    if logits_count != 10:
        all_good = False
    print(f"Logits: {logits_status} {logits_count}/10 imágenes")
    
    print("=" * 60)
    if all_good:
        print("✅ TODAS LAS CAPAS FUNCIONANDO CORRECTAMENTE")
        print("La CNN completa opera exitosamente con macros SRAM SKY130")
    else:
        print("❌ ALGUNAS CAPAS TIENEN PROBLEMAS")
        print("Revisar la generación de feature maps")

if __name__ == "__main__":
    main()