#!/usr/bin/env python3
import argparse
import sys
import torch
import torch.nn as nn
import torch.quantization as tq
import torch.nn.functional as F
from torchvision import datasets, transforms
from torch.utils.data import DataLoader
import os
import collections.abc
import itertools

import inference_model

# ----------------------------------------------------------------------
#  Argumentos CLI principales (ver `--help` para detalles adicionales):
#    --batch-size / --test-batch-size   : tamaños de lote para train/test.
#    --epochs                          : épocas de entrenamiento FP32.
#    --no-cuda                         : fuerza ejecución en CPU.
#    --export-model                    : genera pesos/bias/escala en .hex.
#    --export-images N                 : exporta N imágenes cuantizadas.
#    --run-inference                   : lanza `inference_model` tras exportar.
#    --inference-num-images /          : controla imágenes y logits usados en
#       --inference-export-logits        la inferencia de referencia.
# ----------------------------------------------------------------------

GENERAL_RIGHT_SHIFT = 30  # Q2.30 fixed-point shift applied after MAC accumulation

# ----------------------------------------------------------------------
#  Utilidades para aplanar tensores cuantizados en el orden esperado
#  por el hardware (out_channel -> in_channel -> filas -> columnas).
# ----------------------------------------------------------------------

def flatten_conv_weights_int8(weights_tensor):
    """Devuelve una lista plana con los pesos de una capa conv2d."""
    oc, ic, kh, kw = weights_tensor.shape
    flat_values = []
    for oc_idx in range(oc):
        for ic_idx in range(ic):
            kernel = weights_tensor[oc_idx, ic_idx, :, :]
            flat_values.extend(kernel.reshape(-1).tolist())
    return flat_values


def flatten_linear_weights_int8(weights_tensor):
    """Devuelve una lista plana con los pesos de una capa fully-connected."""
    out_features, in_features = weights_tensor.shape
    flat_values = []
    for of_idx in range(out_features):
        flat_values.extend(weights_tensor[of_idx, :].reshape(-1).tolist())
    return flat_values

# ----------------------------------------------------------------------
#  Definición del Modelo Optimizado para ASIC
# ----------------------------------------------------------------------
class LeNet5_ASIC(nn.Module):
    """
    Arquitectura de CNN inspirada en LeNet-5, diseñada específicamente para una
    implementación eficiente en hardware (ASIC/FPGA).

    Decisiones de diseño clave para eficiencia en hardware:
    - QuantStub/DeQuantStub: Puntos de entrada y salida para el proceso de cuantización
      de PyTorch, que convierte el modelo de FP32 a INT8.
    - nn.Conv2d: Capas convolucionales con kernels pequeños (3x3) y sin padding
      para reducir la complejidad computacional y el área en silicio.
    - nn.ReLU: Función de activación no lineal. Es la más simple de implementar
      en hardware, ya que solo requiere un comparador (max(0, x)).
    - F.max_pool2d: Capa de pooling que reduce la dimensionalidad de los mapas de
      características, disminuyendo la carga computacional de las capas siguientes.
    - nn.AdaptiveAvgPool2d: Global Average Pooling (GAP). Reemplaza a una capa
      densa (Linear) de gran tamaño. Reduce drásticamente el número de parámetros
      y operaciones (MACs), lo que se traduce en un ahorro significativo de
      energía y área. Es una operación de promediado simple.
    - nn.Linear: Capa final densa (fully-connected) para la clasificación. Gracias
      a GAP, esta capa es pequeña y eficiente.
    """
    def __init__(self):
        super().__init__()
        # --- Puntos de Entrada/Salida para Cuantización ---
        self.quant = tq.QuantStub()   # Convierte de FP32 a INT8
        self.dequant = tq.DeQuantStub() # Convierte de INT8 a FP32

        # --- Capa 1: Convolución + ReLU + Max Pooling ---
        self.conv1 = nn.Conv2d(in_channels=1, out_channels=8, kernel_size=3, padding=0)
        self.relu1 = nn.ReLU()
        # MaxPool2d se aplica en el `forward`

        # --- Capa 2: Convolución + ReLU + Max Pooling ---
        self.conv2 = nn.Conv2d(in_channels=8, out_channels=16, kernel_size=3, padding=0)
        self.relu2 = nn.ReLU()
        # MaxPool2d se aplica en el `forward`

        # --- Capa 3: Convolución + ReLU ---
        self.conv3 = nn.Conv2d(in_channels=16, out_channels=32, kernel_size=3, padding=0)
        self.relu3 = nn.ReLU()

        # --- Capa de Pooling Global (GAP) ---
        # Reduce cada mapa de características a un solo valor (promedio).
        # Reemplaza una capa Flatten + Linear grande, ahorrando muchos recursos.
        self.gap = nn.AdaptiveAvgPool2d((1, 1))

        # --- Capa de Clasificación Final (Fully Connected) ---
        self.fc_out = nn.Linear(in_features=32, out_features=10)

    def forward(self, x):
        x = self.quant(x)
        x = self.relu1(self.conv1(x))
        x = F.max_pool2d(x, 2, 2)
        x = self.relu2(self.conv2(x))
        x = F.max_pool2d(x, 2, 2)
        x = self.relu3(self.conv3(x))
        x = self.gap(x)
        x = x.reshape(x.size(0), -1)
        x = self.fc_out(x)
        x = self.dequant(x)
        return x

# ----------------------------------------------------------------------
#  Funciones de Entrenamiento y Evaluación
# ----------------------------------------------------------------------
def train(model, device, loader, optimizer, criterion, epochs):
    model.train()
    print("--- Iniciando Entrenamiento ---")
    for ep in range(1, epochs + 1):
        for batch_idx, (data, tgt) in enumerate(loader):
            data, tgt = data.to(device), tgt.to(device)
            optimizer.zero_grad()
            out = model(data)
            loss = criterion(out, tgt)
            loss.backward()
            optimizer.step()
            if batch_idx > 0 and batch_idx % 200 == 0:
                print(f'\rEpoch {ep}: [{batch_idx * len(data)}/{len(loader.dataset)}] Loss: {loss.item():.4f}', end='')
        print(f'\rEpoch {ep}: [{len(loader.dataset)}/{len(loader.dataset)}] Loss: {loss.item():.4f}')
    print("--- Entrenamiento Finalizado ---")

def evaluate(model, device, loader, model_type="FP32"):
    model.eval()
    model.to(device)
    corr, tot = 0, 0
    with torch.no_grad():
        for data, tgt in loader:
            data, tgt = data.to(device), tgt.to(device)
            pred = model(data).argmax(dim=1)
            corr += pred.eq(tgt).sum().item()
            tot += tgt.size(0)
    accuracy = 100.0 * corr / tot
    print(f'[{model_type} en {device}] Accuracy: {accuracy:.2f}%')
    return accuracy

# ----------------------------------------------------------------------
#  Funciones para Exportar a .HEX para Verilog TB
# ----------------------------------------------------------------------
def save_tensor_to_hex(tensor, filename, is_bias=False):
    with open(filename, 'w') as f:
        tensor_flat = tensor.flatten()
        for val in tensor_flat:
            val_int = int(val.item())
            if is_bias:
                hex_val = f'{val_int & 0xFFFFFFFF:08x}'
            else:
                hex_val = f'{val_int & 0xFF:02x}'
            f.write(hex_val + '\n')


def save_floats_as_fixed_point_hex(values, filename, total_bits, fractional_bits):
    if not isinstance(values, collections.abc.Sequence):
        values = [values]
    scale_factor = 2.0 ** fractional_bits
    mask = (1 << total_bits) - 1
    with open(filename, 'w') as f:
        for val in values:
            fixed_point_val = int(round(val * scale_factor))
            hex_val = f'{fixed_point_val & mask:0{total_bits//4}x}'
            f.write(hex_val + '\n')


def save_scalar_to_hex(value, filename, total_bits=8):
    mask = (1 << total_bits) - 1
    with open(filename, 'w') as f:
        hex_val = f'{int(value) & mask:0{total_bits//4}x}'
        f.write(hex_val + '\n')


def export_images_for_verilog(model, test_loader, num_images, output_dir):
    """Exporta un número `num_images` de imágenes de prueba y sus etiquetas."""
    images_dir = os.path.join(output_dir, "test_images")
    os.makedirs(images_dir, exist_ok=True)
    print(f"\n--- Exportando {num_images} imágenes de prueba a '{images_dir}' ---")

    for i, (image, label) in enumerate(itertools.islice(test_loader, num_images)):
        # Cuantizar la imagen
        quant_image = torch.quantize_per_tensor(image[0], model.quant.scale, model.quant.zero_point, torch.quint8)
        
        # Guardar la imagen en formato .hex
        img_filename = os.path.join(images_dir, f"image_{i}.hex")
        save_tensor_to_hex(quant_image.int_repr(), img_filename)

        # Guardar la etiqueta en un archivo de texto
        label_filename = os.path.join(images_dir, f"image_{i}_label.txt")
        with open(label_filename, 'w') as f:
            f.write(str(label.item()))
            
        if (i + 1) % 10 == 0:
            print(f"Exportadas {i + 1}/{num_images} imágenes...")
    print("--- Exportación de imágenes finalizada. ---")


def export_model_params_for_verilog(model, layer_types, output_dir):
    """Exporta los parámetros del modelo (pesos, biases, escalas) a .hex."""
    print("\n--- Exportando parámetros del modelo para simulación en Verilog ---")
    
    input_scales = {
        'conv1': model.quant.scale, 'conv2': model.conv1.scale,
        'conv3': model.conv2.scale, 'fc_out': model.conv3.scale
    }
    ConvLayerType, LinearLayerType = layer_types

    for name, layer in [('conv1', model.conv1), ('conv2', model.conv2), ('conv3', model.conv3), ('fc_out', model.fc_out)]:
        weights_quant = layer.weight().int_repr()
        if isinstance(layer, ConvLayerType):
            flat_weights = flatten_conv_weights_int8(weights_quant)
            save_tensor_to_hex(
                torch.tensor(flat_weights, dtype=torch.int32),
                os.path.join(output_dir, f"{name}_weights.hex")
            )
        elif isinstance(layer, LinearLayerType):
            flat_weights = flatten_linear_weights_int8(weights_quant)
            save_tensor_to_hex(
                torch.tensor(flat_weights, dtype=torch.int32),
                os.path.join(output_dir, f"{name}_weights.hex")
            )

        if hasattr(layer, 'bias') and layer.bias() is not None:
            input_scale = input_scales[name]
            weight_scale = layer.weight().q_per_channel_scales() if layer.weight().qscheme() == torch.per_channel_affine else layer.weight().q_scale()
            bias_scale = input_scale * weight_scale
            bias_tensor = layer.bias()
            if isinstance(bias_scale, torch.Tensor):
                bias_quant = torch.quantize_per_channel(bias_tensor, bias_scale, torch.zeros_like(bias_scale, dtype=torch.int32), 0, torch.qint32)
            else:
                bias_quant = torch.quantize_per_tensor(bias_tensor, bias_scale, 0, torch.qint32)
            save_tensor_to_hex(bias_quant.int_repr(), os.path.join(output_dir, f"{name}_bias.hex"), is_bias=True)

    FIXED_POINT_TOTAL_BITS = 32
    FIXED_POINT_FRACT_BITS = GENERAL_RIGHT_SHIFT
    save_floats_as_fixed_point_hex(model.quant.scale.item(), os.path.join(output_dir, "model_input_scale.hex"), FIXED_POINT_TOTAL_BITS, FIXED_POINT_FRACT_BITS)
    save_tensor_to_hex(torch.tensor(model.quant.zero_point.item()), os.path.join(output_dir, "model_input_zero_point.hex"))

    for name, layer in [('conv1', model.conv1), ('conv2', model.conv2), ('conv3', model.conv3), ('fc_out', model.fc_out)]:
        input_scale = input_scales[name]
        is_per_channel = layer.weight().qscheme() == torch.per_channel_affine
        weight_scale = layer.weight().q_per_channel_scales() if is_per_channel else layer.weight().q_scale()
        output_scale = layer.scale
        output_zp = torch.tensor(layer.zero_point)
        
        requant_multiplier = (input_scale * weight_scale) / output_scale
        
        save_floats_as_fixed_point_hex(requant_multiplier.tolist() if is_per_channel else requant_multiplier.item(), os.path.join(output_dir, f"{name}_requant_multiplier.hex"), FIXED_POINT_TOTAL_BITS, FIXED_POINT_FRACT_BITS)
        save_tensor_to_hex(output_zp, os.path.join(output_dir, f"{name}_output_zero_point.hex"))

    save_scalar_to_hex(GENERAL_RIGHT_SHIFT, os.path.join(output_dir, "general_right_shift.hex"))
    
    print("--- Exportación de parámetros del modelo finalizada. ---")


def run_python_reference_inference(data_dir, num_images, export_logits):
    """Ejecuta inference_model.main usando argumentos programáticos."""
    argv_backup = sys.argv
    cli_args = [
        "inference_model.py",
        "--data-dir", data_dir,
        "--num-images", str(num_images),
    ]
    if export_logits:
        cli_args.append("--export-logits")
    cli_args.append("--export-layers-hex")
    sys.argv = cli_args
    try:
        inference_model.main()
    finally:
        sys.argv = argv_backup

# ----------------------------------------------------------------------
#  Función Principal
# ----------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(description="PyTorch MNIST Quantization for ASIC prep")
    parser.add_argument('--batch-size', type=int, default=64, help="Tamaño del lote para entrenamiento")
    parser.add_argument('--test-batch-size', type=int, default=1, help="Tamaño del lote para evaluación y exportación")
    parser.add_argument('--epochs', type=int, default=10, help="Número de épocas de entrenamiento")
    parser.add_argument('--no-cuda', action='store_true', help='Desactiva el uso de CUDA y fuerza la ejecución en CPU')
    parser.add_argument('--export-model', action='store_true', help='Exporta los parámetros del modelo (pesos, biases, etc.) a formato .hex')
    parser.add_argument('--export-images', type=int, metavar='N', default=20, help='Exporta N imágenes de prueba a formato .hex para Verilog TB')
    parser.add_argument('--run-inference', action='store_true', help='Ejecuta el pipeline de inference_model.py tras la exportación del modelo')
    parser.add_argument('--inference-num-images', type=int, default=20, help='Número de imágenes de prueba a usar en la inferencia de referencia')
    parser.add_argument('--inference-export-logits', action='store_true', help='Exporta los logits INT8 desde inference_model.py')
    args = parser.parse_args()

    use_cuda = not args.no_cuda and torch.cuda.is_available()
    device = torch.device('cuda' if use_cuda else 'cpu')
    print(f"Usando dispositivo: {device}")

    transform = transforms.Compose([transforms.ToTensor(), transforms.Normalize((0.1307,), (0.3081,))])
    data_dir = './mnist_data'
    train_ds = datasets.MNIST(data_dir, train=True, download=True, transform=transform)
    test_ds = datasets.MNIST(data_dir, train=False, download=True, transform=transform)
    train_loader = DataLoader(train_ds, batch_size=args.batch_size, shuffle=True)
    test_loader = DataLoader(test_ds, batch_size=args.test_batch_size, shuffle=False)

    output_dir = "datos_hex_std"
    os.makedirs(output_dir, exist_ok=True)

    fp32_model = LeNet5_ASIC().to(device)
    optimizer = torch.optim.Adam(fp32_model.parameters(), lr=1e-3)
    criterion = nn.CrossEntropyLoss()
    train(fp32_model, device, train_loader, optimizer, criterion, args.epochs)
    evaluate(fp32_model, device, test_loader, "FP32 Baseline")

    print("\n--- Iniciando Proceso de Cuantización Estática Post-Entrenamiento ---")
    quantized_model = fp32_model.to('cpu')
    quantized_model.eval()
    tq.fuse_modules(quantized_model, [['conv1', 'relu1'], ['conv2', 'relu2'], ['conv3', 'relu3']], inplace=True)
    quantized_model.qconfig = tq.get_default_qconfig('fbgemm')
    tq.prepare(quantized_model, inplace=True)
    
    print("Calibrando el modelo...")
    evaluate(quantized_model, 'cpu', DataLoader(train_ds, batch_size=1000, shuffle=False), "Calibración")
    
    tq.convert(quantized_model, inplace=True)
    print("Modelo convertido a INT8.")
    evaluate(quantized_model, 'cpu', test_loader, "Quantized INT8")

    should_export_model = args.export_model or args.run_inference
    should_export_images = args.export_images > 0

    if should_export_model or should_export_images:
        layer_types = (type(quantized_model.conv1), type(quantized_model.fc_out))
        if should_export_model:
            export_model_params_for_verilog(
                model=quantized_model,
                layer_types=layer_types,
                output_dir=output_dir
            )
        if should_export_images:
            export_images_for_verilog(
                model=quantized_model,
                test_loader=test_loader,
                num_images=args.export_images,
                output_dir=output_dir
            )

    if args.run_inference:
        run_python_reference_inference(
            data_dir=output_dir,
            num_images=args.inference_num_images,
            export_logits=args.inference_export_logits,
        )

if __name__ == '__main__':
    main()
