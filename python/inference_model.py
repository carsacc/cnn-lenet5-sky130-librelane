import os
import math
import argparse
import json

# ==============================================================================
# 1. FUNCIONES AUXILIARES PARA CARGA DE DATOS (sin cambios)
# ==============================================================================

def hex_to_signed_int(hex_str, bits=8):
    val = int(hex_str, 16)
    if (val & (1 << (bits - 1))) != 0:
        val = val - (1 << bits)
    return val

def load_hex_data(file_path, signed=False, bits=8):
    with open(file_path, 'r') as f:
        lines = f.read().splitlines()
    if signed:
        return [hex_to_signed_int(line, bits) for line in lines]
    else:
        return [int(line, 16) for line in lines]

def write_hex_file(values, path):
    with open(path, 'w', encoding='utf-8') as fh:
        for val in values:
            fh.write(f"{(val & 0xFF):02x}\n")

def write_layer_maps_hex(layer_maps, out_dir, prefix):
    """Escribe mapas de características (C x H x W) a archivos HEX por canal.
    Cada archivo se llama f"{prefix}_oc{c}.hex" y contiene H*W líneas de dos dígitos hex.
    """
    os.makedirs(out_dir, exist_ok=True)
    channels = len(layer_maps)
    for c in range(channels):
        flat = [v for row in layer_maps[c] for v in row]
        path = os.path.join(out_dir, f"{prefix}_oc{c}.hex")
        write_hex_file(flat, path)


def load_model_parameters(data_dir):
    params = {
        'conv1': {'weights': [], 'bias': [], 'requant_multiplier': [], 'output_zp': 0},
        'conv2': {'weights': [], 'bias': [], 'requant_multiplier': [], 'output_zp': 0},
        'conv3': {'weights': [], 'bias': [], 'requant_multiplier': [], 'output_zp': 0},
        'fc_out': {'weights': [], 'bias': [], 'requant_multiplier': [], 'output_zp': 0}
    }
    
    conv_layer_shapes = {
        'conv1': {'out_channels': 8, 'in_channels': 1,  'kernel': 3},
        'conv2': {'out_channels': 16, 'in_channels': 8,  'kernel': 3},
        'conv3': {'out_channels': 32, 'in_channels': 16, 'kernel': 3},
    }

    for layer, shape in conv_layer_shapes.items():
        flat_weights = load_hex_data(os.path.join(data_dir, f"{layer}_weights.hex"), signed=True, bits=8)
        kernel_elems = shape['kernel'] * shape['kernel']
        expected_len = shape['out_channels'] * shape['in_channels'] * kernel_elems
        if len(flat_weights) != expected_len:
            raise ValueError(
                f"Unexpected weight length for {layer}: got {len(flat_weights)}, expected {expected_len}."
            )

        idx = 0
        for oc in range(shape['out_channels']):
            oc_weights = []
            for ic in range(shape['in_channels']):
                kernel_slice = flat_weights[idx:idx + kernel_elems]
                idx += kernel_elems
                oc_weights.append(kernel_slice)
            params[layer]['weights'].append(oc_weights)

    fc_out_features = 10
    fc_in_features = 32
    fc_flat_weights = load_hex_data(os.path.join(data_dir, "fc_out_weights.hex"), signed=True, bits=8)
    expected_fc_len = fc_out_features * fc_in_features
    if len(fc_flat_weights) != expected_fc_len:
        raise ValueError(
            f"Unexpected FC weight length: got {len(fc_flat_weights)}, expected {expected_fc_len}."
        )

    idx = 0
    for of in range(fc_out_features):
        row = fc_flat_weights[idx:idx + fc_in_features]
        idx += fc_in_features
        params['fc_out']['weights'].append(row)

    for layer in params:
        params[layer]['bias'] = load_hex_data(os.path.join(data_dir, f"{layer}_bias.hex"), signed=True, bits=32)
        params[layer]['requant_multiplier'] = load_hex_data(os.path.join(data_dir, f"{layer}_requant_multiplier.hex"), signed=True, bits=32)
        params[layer]['output_zp'] = load_hex_data(os.path.join(data_dir, f"{layer}_output_zero_point.hex"), signed=False, bits=8)[0]

    params['model_input_zp'] = load_hex_data(os.path.join(data_dir, "model_input_zero_point.hex"), signed=False, bits=8)[0]
    try:
        params['general_right_shift'] = load_hex_data(os.path.join(data_dir, "general_right_shift.hex"), signed=False, bits=8)[0]
    except FileNotFoundError as exc:
        raise FileNotFoundError("Missing general_right_shift.hex. Rerun train_cnn_mnist_std.py with --export-model to regenerate quantization metadata.") from exc

    return params

# ==============================================================================
# 2. FUNCIONES QUE SIMULAN OPERACIONES DE HARDWARE (sin cambios)
# ==============================================================================

def requantize(accumulator, multiplier, shift, output_zp):
    multiplied = accumulator * multiplier
    shifted = multiplied >> shift
    with_zp = shifted + output_zp
    return max(-128, min(127, with_zp))

def conv2d(input_maps, weights, bias, requant_mult, output_zp, shift):
    in_channels, in_h, in_w = len(input_maps), len(input_maps[0]), len(input_maps[0][0])
    if not weights or not weights[0]:
        raise ValueError('Weights tensor is empty; verify exported parameter files.')
    kernel_elems = len(weights[0][0])
    kernel_size = int(math.isqrt(kernel_elems))
    if kernel_size * kernel_size != kernel_elems:
        raise ValueError(f'Expected square kernel, got {kernel_elems} elements per channel')
    kernel_h = kernel_w = kernel_size
    out_channels = len(weights)
    out_h = in_h - kernel_h + 1
    out_w = in_w - kernel_w + 1
    output_maps = [[[0] * out_w for _ in range(out_h)] for _ in range(out_channels)]
    for oc in range(out_channels):
        for r_out in range(out_h):
            for c_out in range(out_w):
                accumulator = 0
                for ic in range(in_channels):
                    kernel = weights[oc][ic]
                    for r_k in range(kernel_h):
                        for c_k in range(kernel_w):
                            pixel = input_maps[ic][r_out + r_k][c_out + c_k]
                            weight = kernel[r_k * kernel_w + c_k]
                            accumulator += pixel * weight
                accumulator += bias[oc]
                output_maps[oc][r_out][c_out] = requantize(accumulator, requant_mult[oc], shift, output_zp)
    return output_maps

def relu(feature_maps):
    for i in range(len(feature_maps)):
        for j in range(len(feature_maps[i])):
            for k in range(len(feature_maps[i][j])):
                if feature_maps[i][j][k] < 0:
                    feature_maps[i][j][k] = 0
    return feature_maps

def max_pool2d(input_maps):
    channels, in_h, in_w = len(input_maps), len(input_maps[0]), len(input_maps[0][0])
    out_h, out_w = in_h // 2, in_w // 2
    output_maps = [[[0] * out_w for _ in range(out_h)] for _ in range(channels)]
    for c in range(channels):
        for r in range(out_h):
            for col in range(out_w):
                r_start, c_start = r * 2, col * 2
                window = [
                    input_maps[c][r_start][c_start],
                    input_maps[c][r_start][c_start + 1],
                    input_maps[c][r_start + 1][c_start],
                    input_maps[c][r_start + 1][c_start + 1]
                ]
                output_maps[c][r][col] = max(window)
    return output_maps

def global_avg_pool2d(input_maps):
    output_vector = []
    for channel_map in input_maps:
        total = sum(sum(row) for row in channel_map)
        count = len(channel_map) * len(channel_map[0])
        output_vector.append(round(total / count))
    return output_vector

def linear(input_vector, weights, bias, requant_mult, output_zp, shift):
    output_vector = []
    for oc in range(len(weights)):
        accumulator = 0
        for ic in range(len(input_vector)):
            accumulator += input_vector[ic] * weights[oc][ic]
        accumulator += bias[oc]
        output_vector.append(requantize(accumulator, requant_mult[oc], shift, output_zp))
    return output_vector

# ==============================================================================
# 3. FLUJO PRINCIPAL DE INFERENCIA (CON SALIDA VERBOSA)
# ==============================================================================

def print_verbose(stage_name, data):
    """Imprime información de una etapa para depuración."""
    print(f"\n--- Salida de {stage_name} ---")
    if not data:
        print("  Datos vacíos.")
        return

    try:
        if isinstance(data[0], list):
            # Es un mapa de características (lista de listas de listas)
            dims = f"{len(data)}x{len(data[0])}x{len(data[0][0])}"
            print(f"Dimensiones: {dims}")
            print(f"Valores completos:")
            for i, channel in enumerate(data):
                print(f"  Canal {i}:")
                for row in channel:
                    print(f"    {row}")
        else:
            # Es un vector (lista de números)
            dims = f"{len(data)}"
            print(f"Dimensiones: {dims}")
            print(f"Valores completos: {data}")
    except (TypeError, IndexError):
        print(f"  No se pudo mostrar la muestra para la estructura de datos: {data}") 

def main():
    parser = argparse.ArgumentParser(description="Simulador de inferencia de CNN en Python")
    parser.add_argument('--num-images', type=int, default=5, help="Número de imágenes de prueba a procesar.")
    parser.add_argument('--data-dir', type=str, default='datos_hex_std', help="Directorio que contiene los datos del modelo exportado.")
    parser.add_argument('--export-logits', action='store_true', help="Guarda los logits INT8 en archivos .hex por imagen.")
    parser.add_argument('--export-conv1-hex', action='store_true', help="Exporta mapas de salida de Conv1 (tras ReLU) por canal a HEX.")
    parser.add_argument('--export-layers-hex', action='store_true', help='Exporta salidas de todas las capas a subcarpeta golden/.')
    args = parser.parse_args()

    IMAGE_DIR = os.path.join(args.data_dir, 'test_images')
    
    print(f"Cargando parámetros del modelo desde: {args.data_dir}")
    params = load_model_parameters(args.data_dir)
    print("Parámetros cargados.")

    correct_predictions = 0
    total_images = 0

    for i in range(args.num_images):
        image_path = os.path.join(IMAGE_DIR, f'image_{i}.hex')
        label_path = os.path.join(IMAGE_DIR, f'image_{i}_label.txt')
        
        if not os.path.exists(image_path):
            continue
        
        total_images += 1
        print(f"\n{'='*40}\nProcesando {image_path}\n{'='*40}")
        
        image_flat = load_hex_data(image_path, signed=False, bits=8)
        image_2d = [image_flat[j*28:(j+1)*28] for j in range(28)]
        
        input_map = [[pixel - params['model_input_zp'] for pixel in row] for row in image_2d]
        print_verbose("Entrada (Imagen - ZP)", [input_map])
        
        # --- Capa 1 ---
        x = conv2d([input_map], params['conv1']['weights'], params['conv1']['bias'], params['conv1']['requant_multiplier'], params['conv1']['output_zp'], params['general_right_shift'])
        print_verbose("Conv1", x)
        x = relu(x)
        print_verbose("ReLU1", x)
        golden_dir = os.path.join(args.data_dir, "golden")
        if args.export_conv1_hex or args.export_layers_hex:
            write_layer_maps_hex(x, golden_dir, f"conv1_relu_image_{i}")
        x = max_pool2d(x)
        print_verbose("MaxPool1", x)
        if args.export_layers_hex:
            write_layer_maps_hex(x, golden_dir, f"pool1_image_{i}")
        
        # --- Capa 2 ---
        x = conv2d(x, params['conv2']['weights'], params['conv2']['bias'], params['conv2']['requant_multiplier'], params['conv2']['output_zp'], params['general_right_shift'])
        print_verbose("Conv2", x)
        x = relu(x)
        print_verbose("ReLU2", x)
        if args.export_layers_hex:
            write_layer_maps_hex(x, golden_dir, f"conv2_relu_image_{i}")
        x = max_pool2d(x)
        print_verbose("MaxPool2", x)
        if args.export_layers_hex:
            write_layer_maps_hex(x, golden_dir, f"pool2_image_{i}")
        
        # --- Capa 3 ---
        x = conv2d(x, params['conv3']['weights'], params['conv3']['bias'], params['conv3']['requant_multiplier'], params['conv3']['output_zp'], params['general_right_shift'])
        print_verbose("Conv3", x)
        x = relu(x)
        print_verbose("ReLU3", x)
        if args.export_layers_hex:
            write_layer_maps_hex(x, golden_dir, f"conv3_relu_image_{i}")
        
        # --- Pooling y Aplanado ---
        x = global_avg_pool2d(x)
        print_verbose("GlobalAvgPool", x)
        if args.export_layers_hex:
            write_hex_file(x, os.path.join(golden_dir, f"gap_image_{i}.hex"))
        
        # --- Capa 4 (FC) ---
        output_scores = linear(x, params['fc_out']['weights'], params['fc_out']['bias'], params['fc_out']['requant_multiplier'], params['fc_out']['output_zp'], params['general_right_shift'])
        
        if args.export_logits:
            logits_path = os.path.join(args.data_dir, f"logits_image_{i}.hex")
            write_hex_file(output_scores, logits_path)
        if args.export_layers_hex:
            write_hex_file(output_scores, os.path.join(golden_dir, f"fc_logits_image_{i}.hex"))
        
        # --- Resultado Final ---
        print("\n--- Resultado Final ---")
        predicted_class = output_scores.index(max(output_scores))
        with open(label_path, 'r') as f:
            true_label = int(f.read().strip())
            
        print(f"Salidas finales (scores): {output_scores}")
        is_correct = predicted_class == true_label
        if is_correct: correct_predictions += 1
        print(f"Predicción: {predicted_class}, Etiqueta Verdadera: {true_label} -> {'¡CORRECTO!' if is_correct else 'INCORRECTO'}")

    print(f"\n{'='*40}\nResumen Final\n{'='*40}")
    accuracy = (correct_predictions / total_images) * 100 if total_images > 0 else 0
    print(f"Imágenes procesadas: {total_images}")
    print(f"Predicciones correctas: {correct_predictions}")
    print(f"Exactitud (Accuracy): {accuracy:.2f}%")

if __name__ == "__main__":
    main()
