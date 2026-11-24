#!/usr/bin/env python3
"""Reproduce y amplía la evaluación de YOLOv8n (float32 e INT8) sobre COCO
val2017, replicando EXACTAMENTE el preprocesamiento/postprocesamiento de la
app AURA en el commit c2749b0 (rama claude/design-tokens), con el fix de
unidades aplicado también al evaluador (commit 86e8126,
claude/fix-evaluator-units-bug) — ver object_detector_native.dart y
detection_evaluator.dart (ya corregido) para el código fuente replicado.

Parámetros replicados byte a byte de la app (NO ajustables desde CLI a
propósito, para que nadie los cambie "para que coincida"):
  - input 320x320x3, RGB, resize PLANO (sin letterbox), normalizado /255.0
  - salida [1,84,2100] float32 (igual para INT8 y float32: "full-integer
    con I/O float", sin cuantización manual de entrada/salida)
  - confianza = max de las 80 clases (sin fila de objectness aparte)
  - NMS: IoU > 0.45, SIN distinguir clase (class-agnostic), greedy por
    confianza descendente (estrictamente igual a _nms() en Dart)
  - matching para precisión/recall/AP: misma clase Y IoU >= 0.5, greedy
    por confianza descendente, un ground-truth consumido por match
  - precisión/recall GLOBALES: TP/(TP+FP) y TP/(TP+FN) sumados sobre
    todas las clases (no promediados por clase)
  - AP por clase: interpolación "all-point" (igual al bucle de Dart)

Dataset: mirror LibreYOLO/coco-val2017 en Hugging Face (ver README.md en
este mismo directorio de resultados para la limitación explícita: no trae
iscrowd ni área por segmentación poligonal, se reconstruye un JSON estilo
COCO desde las etiquetas YOLO con area = w*h del bbox).
"""
import argparse
import json
import os
import time
from pathlib import Path

import numpy as np
from PIL import Image

INPUT_SIZE = 320
NUM_CLASSES = 80
NUM_BOXES = 2100
NUM_FEATURES = 84
CONF_THRESHOLD_DEFAULT = 0.4
NMS_IOU = 0.45
MATCH_IOU = 0.5
CONF_FLOOR = 0.001  # piso práctico solo para no cargar miles de cajas basura; no cambia resultados (ver README)

# cocoLabels en español, mismo orden oficial de YOLOv8 que usa
# object_detector_common.dart (índice 0-79).
COCO_LABELS_ES = [
    "persona", "bicicleta", "auto", "moto", "avion", "bus", "tren", "camion", "bote",
    "semaforo", "hidrante", "senal de alto", "parquimetro", "banca", "ave", "gato",
    "perro", "caballo", "oveja", "vaca", "elefante", "oso", "cebra", "jirafa",
    "mochila", "paraguas", "bolso", "corbata", "maleta", "frisbee", "esquis",
    "snowboard", "pelota", "cometa", "bate", "guante", "patineta", "tabla de surf",
    "raqueta", "botella", "copa", "taza", "tenedor", "cuchillo", "cuchara", "tazon",
    "platano", "manzana", "sandwich", "naranja", "brocoli", "zanahoria", "hot dog",
    "pizza", "donut", "pastel", "silla", "sofa", "planta", "cama", "mesa", "inodoro",
    "televisor", "laptop", "mouse", "control remoto", "teclado", "celular",
    "microondas", "horno", "tostadora", "lavabo", "refrigerador", "libro", "reloj",
    "jarron", "tijeras", "oso de peluche", "secador", "cepillo de dientes",
]

# Mapeo estándar índice-YOLO (0-79, orden darknet/ultralytics) -> category_id
# real de COCO (1-90, con huecos históricos). Es información pública y
# estable del propio dataset COCO/Ultralytics, no una elección nuestra.
YOLO_IDX_TO_COCO_ID = [
    1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23,
    24, 25, 27, 28, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 46, 47,
    48, 49, 50, 51, 52, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 64, 65, 67, 70,
    72, 73, 74, 75, 76, 77, 78, 79, 80, 81, 82, 84, 85, 86, 87, 88, 89, 90,
]

HOUSEHOLD_LABELS_ES = [
    "botella", "copa", "taza", "tenedor", "cuchillo", "cuchara", "tazon", "silla",
    "sofa", "planta", "cama", "mesa", "televisor", "laptop", "mouse",
    "control remoto", "teclado", "celular", "microondas", "horno", "tostadora",
    "lavabo", "refrigerador", "libro", "reloj", "jarron", "tijeras",
    "oso de peluche", "cepillo de dientes",
]


def load_interpreter(model_path):
    import tensorflow as tf
    it = tf.lite.Interpreter(model_path=str(model_path), num_threads=2)
    it.allocate_tensors()
    return it


def preprocess(image_path):
    """Resize PLANO a 320x320 (sin letterbox) + normalizado [0,1] float32,
    igual que `img.copyResize` + `bytes[i]/255.0` en Dart."""
    img = Image.open(image_path).convert("RGB")
    w0, h0 = img.size
    resized = img.resize((INPUT_SIZE, INPUT_SIZE), Image.BILINEAR)
    arr = np.asarray(resized, dtype=np.float32) / 255.0
    return arr[None, ...], w0, h0


def decode_raw(output):
    """output: (1,84,2100) float32. Devuelve boxes_xyxy_norm (2100,4),
    conf (2100,), cls_idx (2100,) — SIN dividir por inputSize (fix 65a3208)."""
    out = output[0]  # (84, 2100)
    cxcywh = out[0:4, :].T  # (2100,4), ya normalizado [0,1]
    scores = out[4:4 + NUM_CLASSES, :].T  # (2100,80)
    conf = scores.max(axis=1)
    cls_idx = scores.argmax(axis=1)
    cx, cy, w, h = cxcywh[:, 0], cxcywh[:, 1], cxcywh[:, 2], cxcywh[:, 3]
    x1 = cx - w / 2
    y1 = cy - h / 2
    x2 = cx + w / 2
    y2 = cy + h / 2
    boxes = np.stack([x1, y1, x2, y2], axis=1)
    return boxes, conf, cls_idx


def nms_class_agnostic(boxes, scores, iou_thr):
    """Greedy NMS SIN distinguir clase, idéntico a `_nms()` en Dart:
    ordena por confianza descendente, suprime si IoU > iou_thr (estricto)."""
    order = np.argsort(-scores)
    keep = []
    suppressed = np.zeros(len(boxes), dtype=bool)
    b = boxes[order]
    areas = (b[:, 2] - b[:, 0]).clip(0) * (b[:, 3] - b[:, 1]).clip(0)
    for i in range(len(order)):
        if suppressed[i]:
            continue
        keep.append(order[i])
        if i + 1 >= len(order):
            break
        xx1 = np.maximum(b[i, 0], b[i + 1:, 0])
        yy1 = np.maximum(b[i, 1], b[i + 1:, 1])
        xx2 = np.minimum(b[i, 2], b[i + 1:, 2])
        yy2 = np.minimum(b[i, 3], b[i + 1:, 3])
        inter = np.clip(xx2 - xx1, 0, None) * np.clip(yy2 - yy1, 0, None)
        union = areas[i] + areas[i + 1:] - inter
        iou = np.where(union > 0, inter / union, 0.0)
        newly = iou > iou_thr
        suppressed[i + 1:][newly] = True
    return np.array(keep, dtype=int)


def box_iou(a, b):
    xx1 = max(a[0], b[0]); yy1 = max(a[1], b[1])
    xx2 = min(a[2], b[2]); yy2 = min(a[3], b[3])
    inter = max(0.0, xx2 - xx1) * max(0.0, yy2 - yy1)
    area_a = max(0.0, a[2] - a[0]) * max(0.0, a[3] - a[1])
    area_b = max(0.0, b[2] - b[0]) * max(0.0, b[3] - b[1])
    union = area_a + area_b - inter
    return inter / union if union > 0 else 0.0


def load_yolo_labels(label_path):
    boxes = []
    if label_path.exists():
        for line in label_path.read_text().splitlines():
            parts = line.split()
            if len(parts) < 5:
                continue
            cls_idx = int(parts[0])
            cx, cy, w, h = map(float, parts[1:5])
            boxes.append((cls_idx, cx - w / 2, cy - h / 2, cx + w / 2, cy + h / 2))
    return boxes


def run_model_on_dataset(interpreter, image_paths, labels_dir):
    """Corre inferencia + NMS (piso de confianza CONF_FLOOR) UNA sola vez por
    imagen. Las métricas a distintos umbrales de confianza se calculan
    después filtrando esta misma lista — es matemáticamente equivalente a
    filtrar-y-luego-NMS para este NMS greedy ordenado por confianza
    descendente (una caja de menor confianza nunca puede suprimir a una de
    mayor confianza en este algoritmo), así que no hace falta repetir NMS
    por cada umbral del barrido."""
    in_details = interpreter.get_input_details()[0]
    out_details = interpreter.get_output_details()[0]
    per_image = []
    t0 = time.time()
    for idx, img_path in enumerate(image_paths):
        arr, w0, h0 = preprocess(img_path)
        interpreter.set_tensor(in_details["index"], arr)
        interpreter.invoke()
        output = interpreter.get_tensor(out_details["index"])
        boxes, conf, cls_idx = decode_raw(output)
        mask = conf >= CONF_FLOOR
        boxes, conf, cls_idx = boxes[mask], conf[mask], cls_idx[mask]
        if len(boxes) > 0:
            keep = nms_class_agnostic(boxes, conf, NMS_IOU)
            boxes, conf, cls_idx = boxes[keep], conf[keep], cls_idx[keep]
        label_path = labels_dir / (img_path.stem + ".txt")
        gt = load_yolo_labels(label_path)
        per_image.append({
            "file": img_path.name, "w0": w0, "h0": h0,
            "boxes": boxes, "conf": conf, "cls": cls_idx, "gt": gt,
        })
        if (idx + 1) % 500 == 0:
            el = time.time() - t0
            print(f"  [{idx+1}/{len(image_paths)}] {el:.1f}s ({el/(idx+1)*1000:.1f} ms/img)")
    return per_image


def match_at_threshold(per_image, conf_threshold):
    """Replica el matching greedy de detection_evaluator.dart (ya
    corregido) para un umbral de confianza dado. Devuelve stats por clase
    y globales."""
    stats = {c: {"tp": 0, "fp": 0, "fn": 0, "confidences": [], "is_tp": [], "total_gt": 0}
              for c in range(NUM_CLASSES)}
    for rec in per_image:
        mask = rec["conf"] >= conf_threshold
        boxes, conf, cls_idx = rec["boxes"][mask], rec["conf"][mask], rec["cls"][mask]
        gt = [list(g) + [False] for g in rec["gt"]]  # [cls,x1,y1,x2,y2,matched]
        for g in gt:
            stats[g[0]]["total_gt"] += 1
        order = np.argsort(-conf)
        for i in order:
            c, b = int(cls_idx[i]), boxes[i]
            best_iou, best_gt = 0.0, None
            for g in gt:
                if g[5] or g[0] != c:
                    continue
                iou = box_iou(b, g[1:5])
                if iou > best_iou:
                    best_iou, best_gt = iou, g
            is_tp = best_gt is not None and best_iou >= MATCH_IOU
            stats[c]["confidences"].append(float(conf[i]))
            stats[c]["is_tp"].append(bool(is_tp))
            if is_tp:
                best_gt[5] = True
                stats[c]["tp"] += 1
            else:
                stats[c]["fp"] += 1
        for g in gt:
            if not g[5]:
                stats[g[0]]["fn"] += 1
    return stats


def ap_all_point(stats_c):
    """Interpolación all-point, idéntica al bucle de Dart."""
    total_gt = stats_c["total_gt"]
    if total_gt == 0 or not stats_c["confidences"]:
        return 0.0
    order = np.argsort(-np.array(stats_c["confidences"]))
    cum_tp = cum_fp = 0
    recalls, precisions = [], []
    is_tp = stats_c["is_tp"]
    for idx in order:
        if is_tp[idx]:
            cum_tp += 1
        else:
            cum_fp += 1
        recalls.append(cum_tp / total_gt)
        precisions.append(cum_tp / (cum_tp + cum_fp))
    ap, prev_r = 0.0, 0.0
    for r, p in zip(recalls, precisions):
        if r <= prev_r:
            continue
        max_p = max((pp for rr, pp in zip(recalls, precisions) if rr >= r), default=0.0)
        ap += (r - prev_r) * max_p
        prev_r = r
    return ap


def summarize(stats):
    per_class = {}
    ap_values = []
    for c, s in stats.items():
        if s["total_gt"] == 0 and s["tp"] == 0 and s["fp"] == 0:
            continue
        precision = s["tp"] / (s["tp"] + s["fp"]) if (s["tp"] + s["fp"]) else 0.0
        recall = s["tp"] / (s["tp"] + s["fn"]) if (s["tp"] + s["fn"]) else 0.0
        ap = ap_all_point(s)
        if s["total_gt"] > 0:
            ap_values.append(ap)
        per_class[COCO_LABELS_ES[c]] = {
            "classId": c, "n_gt": s["total_gt"], "tp": s["tp"], "fp": s["fp"],
            "fn": s["fn"], "precision": precision, "recall": recall, "ap": ap,
        }
    tp = sum(s["tp"] for s in stats.values())
    fp = sum(s["fp"] for s in stats.values())
    fn = sum(s["fn"] for s in stats.values())
    precision = tp / (tp + fp) if (tp + fp) else 0.0
    recall = tp / (tp + fn) if (tp + fn) else 0.0
    mAP50 = float(np.mean(ap_values)) if ap_values else 0.0
    return {
        "overall": {"tp": tp, "fp": fp, "fn": fn, "precision": precision,
                     "recall": recall, "false_discovery_rate": 1 - precision,
                     "mAP50_custom": mAP50},
        "perClass": per_class,
    }


def build_coco_gt(per_image, out_path):
    images, annotations = [], []
    ann_id = 1
    for img_id, rec in enumerate(per_image, start=1):
        images.append({"id": img_id, "file_name": rec["file"], "width": rec["w0"], "height": rec["h0"]})
        for (cls_idx, x1, y1, x2, y2) in rec["gt"]:
            w = (x2 - x1) * rec["w0"]
            h = (y2 - y1) * rec["h0"]
            x = x1 * rec["w0"]
            y = y1 * rec["h0"]
            annotations.append({
                "id": ann_id, "image_id": img_id,
                "category_id": YOLO_IDX_TO_COCO_ID[cls_idx],
                "bbox": [x, y, w, h], "area": w * h, "iscrowd": 0,
            })
            ann_id += 1
    categories = [{"id": cid, "name": COCO_LABELS_ES[i]} for i, cid in enumerate(YOLO_IDX_TO_COCO_ID)]
    coco = {"images": images, "annotations": annotations, "categories": categories}
    out_path.write_text(json.dumps(coco))
    return coco


def build_coco_dt(per_image, conf_threshold=CONF_FLOOR):
    dets = []
    for img_id, rec in enumerate(per_image, start=1):
        mask = rec["conf"] >= conf_threshold
        boxes, conf, cls_idx = rec["boxes"][mask], rec["conf"][mask], rec["cls"][mask]
        for b, s, c in zip(boxes, conf, cls_idx):
            x1, y1, x2, y2 = b
            w = (x2 - x1) * rec["w0"]
            h = (y2 - y1) * rec["h0"]
            x = x1 * rec["w0"]
            y = y1 * rec["h0"]
            dets.append({
                "image_id": img_id, "category_id": YOLO_IDX_TO_COCO_ID[int(c)],
                "bbox": [float(x), float(y), float(w), float(h)], "score": float(s),
            })
    return dets


def run_pycocotools(coco_gt_path, dt_list, out_dt_path):
    from pycocotools.coco import COCO
    from pycocotools.cocoeval import COCOeval
    out_dt_path.write_text(json.dumps(dt_list))
    coco_gt = COCO(str(coco_gt_path))
    coco_dt = coco_gt.loadRes(str(out_dt_path))
    ev = COCOeval(coco_gt, coco_dt, "bbox")
    ev.evaluate()
    ev.accumulate()
    ev.summarize()
    return {"mAP_50_95": float(ev.stats[0]), "mAP_50": float(ev.stats[1])}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--images", required=True)
    ap.add_argument("--labels", required=True)
    ap.add_argument("--int8", required=True)
    ap.add_argument("--float32", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--limit", type=int, default=0, help="0 = las 5000 completas")
    args = ap.parse_args()

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    images_dir = Path(args.images)
    labels_dir = Path(args.labels)
    image_paths = sorted(images_dir.glob("*.jpg"))
    if args.limit:
        image_paths = image_paths[: args.limit]
    print(f"Imagenes a evaluar: {len(image_paths)}")

    results = {}
    coco_gt_built = False
    for variant, model_path in [("int8", args.int8), ("float32", args.float32)]:
        print(f"\n=== {variant}: {model_path} ===")
        interpreter = load_interpreter(model_path)
        per_image = run_model_on_dataset(interpreter, image_paths, labels_dir)

        if not coco_gt_built:
            coco_gt_path = out_dir / "coco_gt_from_yolo_labels.json"
            build_coco_gt(per_image, coco_gt_path)
            coco_gt_built = True

        # Reproduccion + barrido de confianza (una sola pasada de inferencia,
        # el filtrado por umbral es post-hoc, ver docstring de match_at_threshold).
        sweep_rows = []
        for thr in [0.20, 0.25, 0.30, 0.35, 0.40, 0.45, 0.50, 0.55, 0.60]:
            stats = match_at_threshold(per_image, thr)
            summ = summarize(stats)
            o = summ["overall"]
            n_det = sum(s["tp"] + s["fp"] for s in stats.values())
            f1 = (2 * o["precision"] * o["recall"] / (o["precision"] + o["recall"])
                  if (o["precision"] + o["recall"]) else 0.0)
            sweep_rows.append({"conf_threshold": thr, "precision": o["precision"],
                                 "recall": o["recall"], "f1": f1, "n_detections": n_det,
                                 "tp": o["tp"], "fp": o["fp"], "fn": o["fn"]})
            if abs(thr - 0.4) < 1e-9:
                reproduction = summ

        import pandas as pd
        df = pd.DataFrame(sweep_rows)
        df.to_csv(out_dir / f"sweep_{variant}.csv", index=False)

        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        plt.figure()
        plt.plot(df["conf_threshold"], df["precision"], marker="o", label="precision")
        plt.plot(df["conf_threshold"], df["recall"], marker="o", label="recall")
        plt.plot(df["conf_threshold"], df["f1"], marker="o", label="F1")
        plt.xlabel("umbral de confianza"); plt.ylabel("valor"); plt.legend()
        plt.title(f"YOLOv8n {variant} — barrido de confianza (IoU NMS=0.45, IoU match=0.5)")
        plt.grid(True, alpha=0.3)
        plt.savefig(out_dir / f"sweep_{variant}.png", dpi=150, bbox_inches="tight")
        plt.close()

        household_rows = []
        for label in HOUSEHOLD_LABELS_ES:
            pc = reproduction["perClass"].get(label)
            if pc:
                household_rows.append({"label": label, **pc, "pocos_ejemplos": pc["n_gt"] < 30})
        household_rows.sort(key=lambda r: r["recall"])
        pd.DataFrame(household_rows).to_csv(out_dir / f"household_recall_{variant}.csv", index=False)

        dt_floor = build_coco_dt(per_image, conf_threshold=CONF_FLOOR)
        pyco = run_pycocotools(coco_gt_path, dt_floor, out_dir / f"dt_{variant}.json")

        results[variant] = {
            "reproduction_at_0.4": reproduction["overall"],
            "pycocotools": pyco,
            "sweep_csv": f"sweep_{variant}.csv",
            "household_csv": f"household_recall_{variant}.csv",
            "n_images": len(per_image),
        }
        print(json.dumps(results[variant], indent=2, ensure_ascii=False))

    (out_dir / "summary.json").write_text(json.dumps(results, indent=2, ensure_ascii=False))
    print("\n=== LISTO ===")
    print(json.dumps(results, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
