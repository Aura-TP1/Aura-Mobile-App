# Evaluación COCO val2017 — YOLOv8n (INT8 vs. float32)

## Qué es esto y qué NO es

Esto reproduce de forma independiente los números de detección que el paper
reporta para el modelo YOLOv8n cuantizado INT8 que va embebido en la app
(`assets/yolov8n_int8.tflite`), usando **exactamente** el mismo
preprocesamiento/postprocesamiento que usa la app en producción, y además
corre un barrido de confianza, un desglose por clase de objetos del hogar, y
una comparación contra el modelo float32 sin cuantizar.

No se ajustó ningún parámetro (umbral de NMS, umbral de confianza, forma de
decodificar las cajas) para intentar acercarse a los números del paper. Los
parámetros son los que ya están en el código de la app (`object_detector_native.dart`)
y en el evaluador corregido (`detection_evaluator.dart`). Cualquier diferencia
>0.01 contra los números del paper se reporta tal cual, no se oculta.

## Código y commit exactos evaluados

- **Commit base**: `c2749b0f809cdae47bcd74cdc99e6f1a5e402945` (rama
  `origin/claude/design-tokens`) — es el commit que el usuario confirmó
  explícitamente como el que hay que evaluar.
- **Fix aplicado encima, en commit separado**: `86e8126d12b8dfa4c8001af506af5978c3d2076c`
  (rama `claude/fix-evaluator-units-bug`). Este commit corrige **solo**
  `lib/services/eval/detection_evaluator.dart`: antes de este fix, el
  evaluador dividía `cx,cy,w,h` por 320 una segunda vez, cuando la salida del
  modelo ya viene normalizada en [0,1] — una divergencia heredada de un bug
  que ya había sido corregido en el detector real de la app
  (`object_detector_native.dart`, commit `65a3208`) pero que nunca se replicó
  en el evaluador. Sin este fix, el evaluador no podía estar produciendo las
  métricas correctas del paper porque estaba decodificando las cajas mal.
  **No se tocó ningún otro archivo**: ni `object_detector_native.dart`, ni el
  preprocesamiento, ni los umbrales de confianza/NMS. El diff de ese commit
  se mostró y se confirmó con el usuario antes de correr esta evaluación.
- Este script (`scripts/coco_eval.py`) y esta carpeta de resultados se
  commitean en un commit aparte, también sobre `claude/fix-evaluator-units-bug`.

## Modelos evaluados

Extraídos directamente del repo en el commit `c2749b0` (no de un APK):

| Variante | Archivo | MD5 | Tamaño | Entrada | Salida |
|---|---|---|---|---|---|
| INT8 | `assets/yolov8n_int8.tflite` | `7f434ec635852d93b20ac4ce15d26cfd` | 3,356,568 B | `[1,320,320,3]` float32 | `[1,84,2100]` float32 |
| float32 | `assets/yolov8n_float32.tflite` | `33ec6661371ee6bc758abab60e260bc9` | 12,714,646 B | `[1,320,320,3]` float32 | `[1,84,2100]` float32 |

Verificado con `tf.lite.Interpreter.get_input_details()/get_output_details()`
sobre ambos archivos: los dos tienen entrada/salida en float32 sin cuantización
expuesta (confirma que el INT8 es "full-integer con I/O float", como dice el
comentario del propio código Dart).

## Dataset: de dónde viene y qué limitación tiene

El host oficial (`images.cocodataset.org` / `cocodataset.org`) no es
alcanzable desde este entorno: la conexión TLS falla ("no alternative
certificate subject name matches target host name") contra el proxy de este
sandbox, en los 3 clientes HTTP probados (curl por defecto, curl con
`--cacert` explícito, `urllib` de Python). No es un bloqueo de política (el
proxy no devolvió 403 para ese host) ni un error de configuración de mi lado;
es un fallo TLS del lado del proxy/host que no se pudo resolver.

Ante eso, y con aprobación explícita del usuario ("opción 1"), se usó un
mirror de Hugging Face: **`LibreYOLO/coco-val2017`**
(`https://huggingface.co/datasets/LibreYOLO/coco-val2017`), que trae las 5000
imágenes de val2017 ya en formato YOLO (`.txt` por imagen, clase + bbox
normalizado) en vez del `instances_val2017.json` oficial.

**Limitación documentada, no oculta**: no fue posible verificar este mirror
byte a byte contra el `instances_val2017.json` oficial (no se pudo descargar
ese archivo de referencia por el mismo bloqueo de red). Al reconstruir un
JSON estilo-COCO desde las etiquetas YOLO para poder usar `pycocotools`:

- **No hay flag `iscrowd`** en el formato YOLO — se asume `iscrowd=0` para
  todas las anotaciones. Si el oficial tiene instancias `iscrowd=1` (objetos
  en multitud, sin cajas individuales), `pycocotools` las trata distinto en
  el matching, así que los números de `pycocotools` de este reporte pueden
  diferir ligeramente de una corrida contra el JSON oficial por esta razón,
  no por un error de implementación.
- **`area` se calcula como `w × h` del bounding box**, no como el área del
  polígono de segmentación (que el formato YOLO no incluye). El criterio
  oficial de COCO para las métricas por tamaño (`area=small/medium/large`)
  usa el área de la segmentación poligonal, así que esas métricas por tamaño
  (incluidas en la salida de `pycocotools.summarize()` pero no en el resumen
  principal de este reporte) tienen el mismo tipo de desviación esperada.
- Las imágenes (`.jpg`) sí son los archivos reales de val2017 (mismos
  nombres de archivo que el dataset oficial, 5000 imágenes, 4952 con al
  menos una anotación — 48 sin objetos, consistente con val2017 oficial).

En resumen: las cajas, clases y las 5000 imágenes son reales y confiables;
lo que no se pudo verificar 1:1 es el archivo de anotaciones oficial completo
(`iscrowd` y área por segmentación). Esto afecta sobre todo a
`pycocotools`/mAP oficial, no a la reproducción "estilo Dart" con matching
simple IoU≥0.5, que no usa esos dos campos.

## Metodología (idéntica a la app, ver `scripts/coco_eval.py`)

- **Preprocesamiento**: resize plano a 320×320 (sin letterbox/padding),
  RGB, normalizado a `[0,1]` dividiendo por 255.0 — igual que
  `object_detector_native.dart`.
- **Decodificación de cajas**: `cx,cy,w,h` tomados directamente de la salida
  del modelo (ya normalizados en `[0,1]`, **sin volver a dividir por 320**:
  este es exactamente el fix de `86e8126`).
- **Confianza**: máximo de las 80 puntuaciones de clase por caja (no hay fila
  de "objectness" separada).
- **NMS**: greedy por confianza descendente, **sin distinguir clase**
  (class-agnostic), se suprime si IoU > 0.45 — igual que `_nms()` en Dart.
- **Matching para precisión/recall/AP "estilo Dart"**: greedy por confianza
  descendente, requiere misma clase Y IoU ≥ 0.5, cada ground-truth se
  consume una sola vez.
- **AP por clase "estilo Dart"**: interpolación *all-point* (no 101-point),
  igual que el bucle de `detection_evaluator.dart`.
- **Precisión/recall globales**: TP/FP/FN sumados sobre todas las clases
  (no promediados por clase) — esto es lo que el código Dart llama
  `overall precision/recall`.
- **mAP oficial (`pycocotools`)**: corrido por separado, con el estándar
  COCOeval (10 umbrales de IoU de 0.50 a 0.95 para `mAP@0.5:0.95`,
  interpolación 101-point), usando todas las detecciones por encima de un
  piso de confianza de 0.001 (no filtradas a 0.4) — así `pycocotools`
  puede construir su propia curva precisión-recall completa. Por diseño,
  **no es el mismo número** que la reproducción "estilo Dart" a confianza
  fija 0.4: son dos protocolos de medición distintos, reportados ambos
  para que quede claro cuál es cuál.

Nota de eficiencia: el NMS se corre **una sola vez por imagen**, con un piso
de confianza bajo (0.001), y los distintos umbrales del barrido (0.20 a 0.60)
se obtienen filtrando esa misma lista de detecciones después. Esto es
matemáticamente equivalente a correr NMS de nuevo a cada umbral, porque el
NMS es greedy por confianza descendente: una caja de menor confianza nunca
puede suprimir a una de mayor confianza, así que subir el umbral solo quita
cajas, nunca cambia cuáles sobreviven entre las que quedan.

## Resultados

Corrida sobre las **5000 imágenes completas** de val2017 (mirror HF).

### Hallazgo previo importante: los números de Table I no tenían fuente verificable

Antes de esta evaluación, el repo no tenía NINGÚN registro de cómo se habían
obtenido los números actuales del paper (mAP@0.5=0.270, mAP@0.5:0.95=0.202,
precisión=0.775, recall=0.287). El propio mensaje del commit `c2749b0`
(que agregó el test de integración Dart que se está reproduciendo acá) lo
dice explícitamente: *"Table I's detection numbers had no verifiable source
in the repo — no call site for evaluateDetector() and no report on disk"*.
Es decir: hasta esta corrida, esos 4 números eran **no verificables**, no
una reproducción de un resultado real conocido. Lo que sigue es la primera
vez que se calculan con trazabilidad completa (commit, dataset, código).

### 1) Reproducción exacta de la metodología del paper (conf. fija 0.4)

Esto es lo que el test de integración Dart (`evaluate_detector_test.dart` →
`evaluateDetector()`) calcula: TP/FP/FN globales (sumados sobre clases, no
promediados) a un único umbral de confianza = 0.4, con AP@0.5 por
interpolación *all-point*. **Es la comparación más directa posible contra
los 4 números del paper**, porque usa el mismo código que el paper dice usar.

| Métrica | Paper (Table I actual) | Obtenido (INT8, 5000 img) | Diferencia | ¿Coincide (±0.01)? |
|---|---|---|---|---|
| mAP@0.5 | 0.270 | **0.2716** | +0.0016 | ✅ Sí |
| recall | 0.287 | **0.2924** | +0.0054 | ✅ Sí |
| precisión | 0.775 | **0.8590** | +0.084 | ❌ **No** — diferencia notable, no se fuerza a coincidir |
| tasa de descubrimiento falso (1−precisión) | 0.225 (impl.) | **0.1410** | −0.084 | ❌ No (espejo de precisión) |

float32, para comparación: mAP@0.5=0.2732, precisión=0.8572, recall=0.2938.

`detection_evaluator.dart` **no calcula mAP@0.5:0.95** (solo AP@0.5), así que
ese número del paper no puede venir de este mismo evaluador — ver el punto 3.

**Sobre la diferencia de precisión**: no se encontró una explicación verificable
en el código — es un hallazgo honesto, no una conjetura forzada a calzar. Puede
deberse a que el 0.775 original se calculó sobre un subconjunto distinto de
imágenes (el `EVAL_README.md` del propio commit `c2749b0` sugiere explícitamente
"si ya tenían las anotaciones que usaron para el número original... usá
exactamente esas mismas", lo cual implica que probablemente nunca se corrió
sobre las 5000 imágenes completas de val2017), o a un cálculo manual/estimado
en vez de una corrida real. Con los datos disponibles no se puede determinar
cuál de las dos cosas pasó.

### 2) mAP estándar completo (pycocotools, curva completa de confianza)

Esta es la forma convencional de calcular mAP (integrando sobre toda la curva
precisión-recall, sin fijar un umbral de confianza, 101-point interpolation,
promedio sobre 10 umbrales de IoU para `mAP@0.5:0.95`). Es un número más
informativo sobre la calidad real del detector, pero **no es comparable
directamente** contra el 0.270/0.202 del paper, que —ver punto 3— vienen de
una curva recortada a conf≥0.4, no de la curva completa.

| Modelo | mAP@0.5 | mAP@0.5:0.95 |
|---|---|---|
| INT8 | 0.4021 | 0.2709 |
| float32 | 0.4019 | 0.2716 |

### 3) Replicando el recorte a conf≥0.4 dentro del protocolo oficial

Se probó la hipótesis de que el paper calculó mAP@0.5 / mAP@0.5:0.95 con el
protocolo oficial de `pycocotools` pero **filtrando antes las detecciones a
confianza≥0.4** (el umbral real de la app), en vez de usar la curva completa.
Resultado, INT8:

| Métrica | Paper | Obtenido (conf≥0.4, pycocotools) | Diferencia |
|---|---|---|---|
| mAP@0.5 | 0.270 | **0.2740** | +0.004 ✅ |
| mAP@0.5:0.95 | 0.202 | **0.2070** | +0.005 ✅ |

Esto coincide casi exactamente, y es consistente con el punto 1 (mismo
umbral de confianza). Conclusión: **los números de mAP del paper sí son
reproducibles** con esta metodología (filtrar a conf≥0.4, luego aplicar el
protocolo estándar de IoU múltiple) — la pieza que no logró reproducirse es
la precisión (0.775 vs 0.859 obtenido).

### 4) Barrido de confianza (0.20–0.60, paso 0.05)

Ver `sweep_int8.csv`/`sweep_float32.csv` y `sweep_int8.png`/`sweep_float32.png`.
Resumen INT8:

| conf | precisión | recall | F1 | detecciones |
|---|---|---|---|---|
| 0.20 | 0.721 | 0.377 | 0.495 | 18994 |
| 0.25 | 0.769 | 0.355 | 0.485 | 16743 |
| 0.30 | 0.802 | 0.333 | 0.471 | 15082 |
| 0.35 | 0.832 | 0.313 | 0.454 | 13651 |
| **0.40** | **0.859** | **0.292** | **0.436** | 12370 |
| 0.45 | 0.879 | 0.273 | 0.416 | 11274 |
| 0.50 | 0.897 | 0.253 | 0.394 | 10232 |
| 0.55 | 0.913 | 0.233 | 0.371 | 9259 |
| 0.60 | 0.929 | 0.212 | 0.346 | 8304 |

float32 es prácticamente idéntico en todo el barrido (diferencias <0.01 en
precisión/recall en cada punto) — la cuantización a INT8 no está costando
precisión de detección medible en este dataset.

### 5) Recall por clase — libro, cuchillo, cuchara, control remoto (INT8, conf=0.4)

| Clase | n (ground truth) | TP | recall | AP@0.5 | ¿Pocos ejemplos (n<30)? |
|---|---|---|---|---|---|
| libro | 1129 | 12 | **0.0106** | 0.0095 | No |
| cuchara | 253 | 11 | **0.0435** | 0.0317 | No |
| cuchillo | 325 | 17 | **0.0523** | 0.0463 | No |
| control remoto | 283 | 22 | **0.0777** | 0.0615 | No |

**Confirmado, no es ruido estadístico**: las 4 clases tienen entre 253 y 1129
ejemplos en val2017 (muy por encima del piso de 30), así que estos recalls
bajos (1%–8%) son una medición confiable del comportamiento real del modelo,
no un artefacto de muestra chica. Son, de hecho, las 4 clases con peor recall
de las 29 clases "de hogar" evaluadas (ver `household_recall_int8.csv` para
las 29 completas) — consistente con lo que se esperaba: son objetos chicos,
delgados o con mucha variación de pose/forma (libro visto de canto, cuchillo/
cuchara en una mesa junto a otros cubiertos, control remoto parcialmente
tapado por una mano) que YOLOv8n a 320×320 de entrada estructuralmente
detecta peor que objetos grandes y de forma estable (TV, laptop, refrigerador,
que están entre 0.47–0.49 de recall en el mismo reporte). La única clase peor
que estas 4 es "tostadora" (recall=0, pero con solo 9 ejemplos — sí señalada
como "pocos ejemplos" y no comparable a estas 4).

float32, mismas 4 clases (para contraste): libro 0.0097, cuchara 0.0474,
cuchillo 0.0523, control remoto 0.0707 — esencialmente igual que INT8.

## Cómo reproducir

```bash
python3 -m venv venv && source venv/bin/activate
pip install numpy pillow matplotlib pandas pycocotools tensorflow-cpu

python scripts/coco_eval.py \
  --images /ruta/a/coco-val2017/images/val2017 \
  --labels /ruta/a/coco-val2017/labels/val2017 \
  --int8 assets/yolov8n_int8.tflite \
  --float32 assets/yolov8n_float32.tflite \
  --out results/coco
```

Librerías usadas en esta corrida: `numpy==2.4.6`, `pillow==13.0.0`,
`matplotlib==3.11.2`, `pandas==3.1.1`, `pycocotools==2.0.11`,
`tensorflow_cpu==2.21.0`, Python 3.11.
