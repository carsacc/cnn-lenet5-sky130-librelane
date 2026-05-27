#!/usr/bin/env python3
import os
from pathlib import Path

# Configuración
DEPTH_WORDS = 2048
DATA_DIR = Path(__file__).resolve().parent.parent / "datos_hex_std"
DATA_DIR.mkdir(parents=True, exist_ok=True)
OUT_FILE = DATA_DIR / "PARAM_MEM_32x2048.hex"
IN_DIR = DATA_DIR

def load_hex(filename, expected_len):
    path = IN_DIR / filename
    if not path.exists():
        raise FileNotFoundError(f"Falta {path}")
    lines = [ln.strip() for ln in path.read_text().splitlines() if ln.strip()]
    if len(lines) != expected_len:
        # Algunos archivos de ZP pueden venir con un solo valor pero se usan para todos los canales
        if len(lines) == 1:
            return [int(lines[0], 16)] * expected_len
        raise ValueError(f"{filename}: líneas={len(lines)}, se esperaban {expected_len}")
    return [int(x, 16) for x in lines]

def pack_bytes(b0, b1=0, b2=0, b3=0):
    return ( (b3 & 0xFF) << 24 | (b2 & 0xFF) << 16 | (b1 & 0xFF) << 8 | (b0 & 0xFF) )

def main():
    mem = [0] * DEPTH_WORDS
    ptr = 0 # Word pointer

    # --- 1. METADATOS GLOBALES ---
    # Word 0: Scale
    scale = load_hex("model_input_scale.hex", 1)[0]
    mem[ptr] = scale
    ptr += 1
    # Word 1: [RSVD(16) | Shift(8) | Input_ZP(8)]
    input_zp = load_hex("model_input_zero_point.hex", 1)[0]
    right_shift = load_hex("general_right_shift.hex", 1)[0]
    mem[ptr] = pack_bytes(input_zp, right_shift, 0, 0)
    ptr += 1

    # --- 2. CONV1 (8 OC, 1 IC) - Intercalado por OC ---
    # Pesos (18 words)
    w1 = load_hex("conv1_weights.hex", 72) # 8 OC * 9
    for block in range(2): # 2 bloques de 4 OC
        for k in range(9): # 9 posiciones del kernel
            # Word: [W_k_OC3, W_k_OC2, W_k_OC1, W_k_OC0]
            mem[ptr] = pack_bytes(w1[(block*4+0)*9+k], w1[(block*4+1)*9+k], w1[(block*4+2)*9+k], w1[(block*4+3)*9+k])
            ptr += 1
    # Metadatos
    for b in load_hex("conv1_bias.hex", 8): mem[ptr] = b; ptr += 1
    for m in load_hex("conv1_requant_multiplier.hex", 8): mem[ptr] = m; ptr += 1
    zps1 = load_hex("conv1_output_zero_point.hex", 8)
    mem[ptr] = pack_bytes(zps1[0], zps1[1], zps1[2], zps1[3]); ptr += 1
    mem[ptr] = pack_bytes(zps1[4], zps1[5], zps1[6], zps1[7]); ptr += 1

    # --- 3. CONV2 (16 OC, 8 IC) - Intercalado por IC ---
    # Pesos (288 words)
    w2 = load_hex("conv2_weights.hex", 1152) # 16 OC * 8 IC * 9
    for oc in range(16):
        for k in range(9):
            # Word 0: IC 0-3
            mem[ptr] = pack_bytes(w2[oc*72+0*9+k], w2[oc*72+1*9+k], w2[oc*72+2*9+k], w2[oc*72+3*9+k])
            ptr += 1
            # Word 1: IC 4-7
            mem[ptr] = pack_bytes(w2[oc*72+4*9+k], w2[oc*72+5*9+k], w2[oc*72+6*9+k], w2[oc*72+7*9+k])
            ptr += 1
    # Metadatos
    for b in load_hex("conv2_bias.hex", 16): mem[ptr] = b; ptr += 1
    for m in load_hex("conv2_requant_multiplier.hex", 16): mem[ptr] = m; ptr += 1
    zps2 = load_hex("conv2_output_zero_point.hex", 16)
    for i in range(0, 16, 4):
        mem[ptr] = pack_bytes(zps2[i], zps2[i+1], zps2[i+2], zps2[i+3])
        ptr += 1

    # --- 4. CONV3 (32 OC, 16 IC) - Intercalado por IC ---
    # Pesos (1152 words)
    w3 = load_hex("conv3_weights.hex", 4608) # 32 OC * 16 IC * 9
    for oc in range(32):
        for k in range(9):
            for block in range(4): # 16 IC / 4 = 4 words
                mem[ptr] = pack_bytes(w3[oc*144+(block*4+0)*9+k], w3[oc*144+(block*4+1)*9+k], w3[oc*144+(block*4+2)*9+k], w3[oc*144+(block*4+3)*9+k])
                ptr += 1
    # Metadatos
    for b in load_hex("conv3_bias.hex", 32): mem[ptr] = b; ptr += 1
    for m in load_hex("conv3_requant_multiplier.hex", 32): mem[ptr] = m; ptr += 1
    zps3 = load_hex("conv3_output_zero_point.hex", 32)
    for i in range(0, 32, 4):
        mem[ptr] = pack_bytes(zps3[i], zps3[i+1], zps3[i+2], zps3[i+3])
        ptr += 1

    # --- 5. FC_OUT (10 OC, 32 IC) - Intercalado por OC ---
    # Pesos (96 words)
    wfc = load_hex("fc_out_weights.hex", 320) # 10 OC * 32 IC
    for block in range(3): # 3 bloques: OC 0-3, 4-7, 8-9
        num_oc = 4 if block < 2 else 2
        for ic in range(32):
            if num_oc == 4:
                mem[ptr] = pack_bytes(wfc[(block*4+0)*32+ic], wfc[(block*4+1)*32+ic], wfc[(block*4+2)*32+ic], wfc[(block*4+3)*32+ic])
            else:
                mem[ptr] = pack_bytes(wfc[8*32+ic], wfc[9*32+ic], 0, 0)
            ptr += 1
    # Metadatos
    for b in load_hex("fc_out_bias.hex", 10): mem[ptr] = b; ptr += 1
    for m in load_hex("fc_out_requant_multiplier.hex", 10): mem[ptr] = m; ptr += 1
    zpsfc = load_hex("fc_out_output_zero_point.hex", 10)
    mem[ptr] = pack_bytes(zpsfc[0], zpsfc[1], zpsfc[2], zpsfc[3]); ptr += 1
    mem[ptr] = pack_bytes(zpsfc[4], zpsfc[5], zpsfc[6], zpsfc[7]); ptr += 1
    mem[ptr] = pack_bytes(zpsfc[8], zpsfc[9], 0, 0); ptr += 1

    # Escritura final
    OUT_FILE.write_text("\n".join(f"{w & 0xFFFFFFFF:08x}" for w in mem) + "\n")
    print(f"OK -> {OUT_FILE} (Final Ptr: {ptr} words used)")

if __name__ == "__main__":
    main()