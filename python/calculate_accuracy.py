#!/usr/bin/env python3
"""
Calcula la accuracy del modelo CNN comparando logits RTL vs golden.
"""

import numpy as np

def load_hex(path: str) -> np.ndarray:
    vals = [int(l.strip(), 16) for l in open(path) if l.strip()]
    return np.array(vals, dtype=np.uint8)

def load_label(path: str) -> int:
    with open(path, 'r') as f:
        return int(f.read().strip())

def main():
    correct_predictions = 0
    total_images = 10
    
    print("Calculating accuracy with SRAM SKY130 results:")
    print("=" * 50)
    
    for i in range(total_images):
        # Load golden logits and label
        golden_logits = load_hex(f"datos_hex_std/logits_image_{i}.hex")
        golden_label = load_label(f"datos_hex_std/test_images/image_{i}_label.txt")
        
        # Load RTL logits
        rtl_logits = load_hex(f"rtl/sim/rtl_fc_logits_image_{i}.hex")
        
        # Get predictions (argmax)
        golden_pred = np.argmax(golden_logits)
        rtl_pred = np.argmax(rtl_logits)
        
        # Check if predictions match
        prediction_correct = (golden_pred == rtl_pred)
        label_match = (rtl_pred == golden_label)
        
        if prediction_correct and label_match:
            correct_predictions += 1
            status = "✓ CORRECT"
        else:
            status = "✗ WRONG"
        
        print(f"Image {i}: Golden={golden_pred}, RTL={rtl_pred}, Label={golden_label} - {status}")
    
    accuracy = (correct_predictions / total_images) * 100
    print("=" * 50)
    print(f"FINAL ACCURACY: {accuracy:.1f}% ({correct_predictions}/{total_images})")
    
    # Verify bit-exact match
    all_exact = True
    for i in range(total_images):
        golden_logits = load_hex(f"datos_hex_std/logits_image_{i}.hex")
        rtl_logits = load_hex(f"rtl/sim/rtl_fc_logits_image_{i}.hex")
        if not np.array_equal(golden_logits, rtl_logits):
            all_exact = False
            break
    
    if all_exact:
        print("✓ BIT-EXACT MATCH: All logits files are identical")
    else:
        print("⚠ LOGITS DIFFER: Some logits files have differences")

if __name__ == "__main__":
    main()