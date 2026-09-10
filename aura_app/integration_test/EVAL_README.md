# Cómo correr la evaluación de mAP/precision/recall (float32 vs INT8)

Esto genera los números reales de Table I para AMBAS variantes del modelo
YOLOv8n, corridas bajo exactamente el mismo dataset y umbrales que usa la
app en vivo (320×320, conf 0.4, NMS IoU 0.45, mAP@0.5).

## 1. Conseguir el dataset

Necesitás imágenes + anotaciones de bounding boxes. Lo más simple es un
subconjunto de COCO val2017 (no hace falta el set completo de 5,000
imágenes si no lo tenían ya armado — con unos pocos cientos alcanza para
un número honesto, siempre que lo digas en el paper).

- Imágenes: cualquier subconjunto de `val2017/*.jpg`.
- Anotaciones: formato YOLO/darknet, un `.txt` por imagen
  (`classId cx cy w h`, todo normalizado 0-1, cx/cy = centro de la caja).
  Si ya tenían las anotaciones que usaron para el número original de Table I
  (el 0.272 mAP@0.5), **usá exactamente esas mismas** — así la comparación
  float32 vs INT8 es limpia y no se confunde con un cambio de dataset.

## 2. Copiar el dataset al dispositivo/emulador

```bash
adb push /ruta/local/val2017_subset/images   /sdcard/aura_eval/images
adb push /ruta/local/val2017_subset/labels   /sdcard/aura_eval/annotations
```

(Los nombres de carpeta deben coincidir con `_imagesDir`/`_annotationsPath`
en `evaluate_detector_test.dart` — ya están puestos así por defecto.)

## 3. Instalar la dependencia nueva

Agregué `integration_test` a `pubspec.yaml`. Solo falta:

```bash
cd aura_app
flutter pub get
```

## 4. Correr el test

Con un dispositivo Android conectado (o el mismo Galaxy A30s usado para las
otras pruebas técnicas — usá el mismo dispositivo si querés que Table I y
Table II sean comparables entre sí):

```bash
flutter devices                # confirmar el <device-id>
flutter test integration_test/evaluate_detector_test.dart -d <device-id>
```

Esto corre la evaluación completa DOS VECES (float32 primero, INT8
después) y va a tardar un rato si el dataset es grande — es inferencia real
sobre cada imagen, sin atajos.

## 5. Recuperar los resultados

```bash
adb pull /sdcard/aura_eval/eval_report_float32.json
adb pull /sdcard/aura_eval/eval_report_int8.json
```

También vas a ver un resumen impreso en la consola de `flutter test`
(`report['overall']` de cada variante) apenas termine cada una.

## 6. Qué hacer con los resultados

Pegame acá los dos JSON completos (o al menos la sección `"overall"` y
`"householdRelevantSummary"` de cada uno). Con eso:
- Confirmo/corrijo Table I con el número real de la variante que
  finalmente esté activa en la app (recordá: `useYoloInt8 = true` por
  default en `AppSettings`, así que si el paper describe "el modelo
  desplegado", probablemente corresponda reportar INT8, no float32).
- Si hay una diferencia notable entre ambas, la reportamos también —
  es un dato legítimo y hasta interesante para el paper (costo de la
  cuantización en mAP real, no solo en tamaño/latencia).

## Si algo falla

- `ArgumentError: imagesDir no existe` / `annotationsPath no existe`: las
  rutas del paso 2 no coinciden con las de `evaluate_detector_test.dart`,
  o el `adb push` no llegó a completarse.
- El test tarda demasiado / se cuelga: probá primero con un subconjunto
  chico (50-100 imágenes) para validar que todo el flujo funciona antes de
  correr el dataset completo.
