# Live Subject Detection & Bounding Box

This document describes the live subject/foreground bounding-box feature shipped
in `native_camera_view`, and lays out the options for making it more capable
(car-specific detection, outline/segmentation, tracking, custom models).

---

## 1. What ships today

A live, on-device **foreground/subject bounding box**. When enabled, the plugin
runs a lightweight detector on the camera stream and reports a single stable box
around the prominent subject each frame. The plugin draws it as an overlay, or
you can draw your own.

Key properties:

- **No model files.** Both platforms use OS/SDK-bundled detectors.
- **Opt-in.** Nothing runs unless you pass `enableDetection: true`. No ML work,
  no analysis frames, no battery cost otherwise.
- **Single, stable box.** Native selects one primary subject (largest box above
  size/confidence thresholds) and Dart applies temporal smoothing, so you get
  one box that tracks smoothly instead of a flickering swarm.
- **Orientation-aware.** Boxes stay aligned in portrait and landscape (Android
  tracks display rotation; iOS orients the Vision request to the device).
- **Not car-specific.** It finds the prominent *foreground subject*, not "a car"
  by identity. Point it at a car and the car is the subject, but a person or a
  chair in frame would be boxed too. See §5.2 for car-specific detection.

### Platform backends

| | Android | iOS |
|---|---|---|
| Runtime | ML Kit Object Detection (bundled) | Vision framework (`VNGenerateObjectnessBasedSaliencyImageRequest`) |
| Frame source | CameraX `ImageAnalysis` use case | existing `AVCaptureVideoDataOutput` |
| Min OS | API 21 | iOS 13 (no-op below) |
| Primary box | largest object above thresholds | largest salient region above thresholds |
| Labels | none (classification off) | none (saliency has no class) |
| Confidence | not provided | provided per salient region |
| Tracking id | provided (stream mode) | not provided |
| Orientation | `targetRotation` follows the device | Vision orientation follows the device |

The two backends are not identical: ML Kit returns the prominent *object*,
Vision returns *visually salient* regions. Both are a reasonable "subject box";
the difference is documented rather than hidden.

### Tuning knobs

- `enableDetection` — turn the pipeline on (default off).
- `showDetectionBox` — draw the built-in overlay (default on).
- `detectionBoxColor` / `detectionBoxStrokeWidth` — overlay style.
- `detectionSmoothing` — 0.0..1.0 EMA factor (default 0.4; higher = snappier,
  0.0 disables smoothing).
- Native filter thresholds live in `SubjectDetectionAnalyzer.kt`
  (`MIN_RELATIVE_AREA`, `MIN_LABEL_CONFIDENCE`) and `CameraPreview.swift`
  (`detectionMinRelativeArea`, `detectionMinConfidence`).

---

## 2. How it's wired

```
 Camera frame ─▶ native detector ─▶ EventChannel ─▶ Dart Stream ─▶ CustomPaint overlay
   Android: ImageAnalysis          per-view       ValueNotifier    BoundingBoxPainter
   iOS:     captureOutput          channel        <DetectionFrame>
```

### The wire contract (EventChannel)

Channel name (per view): `com.plugin.camera_native.native_camera_view/camera_detections_$viewId`
(Android) / `..._camera_detections_ios_$viewId` (iOS).

Each event is a map:

```jsonc
{
  "imageWidth":  1280,        // analyzed frame width, DISPLAY orientation (px)
  "imageHeight": 720,         // analyzed frame height, DISPLAY orientation (px)
  "isMirrored":  false,       // true when coords must be X-flipped to match preview
  "detections": [
    {
      "left":   0.31,         // all edges normalized 0..1, TOP-LEFT origin
      "top":    0.22,
      "right":  0.78,
      "bottom": 0.91,
      "confidence": 0.87,     // optional
      "label":  "car",        // optional (absent in v1)
      "trackingId": 4          // optional
    }
  ]
}
```

**Coordinate rules (important):**

- Edges are normalized `0.0..1.0`, **top-left origin**, in the frame's **display
  (upright) orientation**. All sensor-rotation math is done natively so Dart
  never touches it.
- `isMirrored = true` means the coordinates are in a non-mirrored space while the
  preview is mirrored (Android front camera). Consumers flip X
  (`left' = 1 - right`) before mapping. iOS mirrors natively and reports `false`.

### Dart types

- `SubjectDetection` — one box + optional confidence/label/trackingId.
- `DetectionFrame` — `imageWidth`, `imageHeight`, `isMirrored`, `detections`.
- `mapDetectionToWidget(...)` — converts a normalized box to widget pixels for a
  given fit mode + mirroring. Handles `cover`/`contain`/`fitWidth`/`fitHeight`.
- `BoundingBoxPainter` — draws boxes (+ optional label chips).

---

## 3. Usage

```dart
NativeCameraView(
  enableDetection: true,          // turn the pipeline on
  showDetectionBox: true,         // draw the built-in overlay (default)
  detectionBoxColor: Colors.cyan,
  detectionSmoothing: 0.4,        // EMA smoothing (0 disables, higher = snappier)
  cameraPreviewFit: CameraPreviewFit.cover,
  onControllerCreated: (controller) {
    _controller = controller;
  },
);
```

Toggle at runtime:

```dart
await controller.setDetectionEnabled(false);
```

Draw your own overlay instead of the built-in one — set `showDetectionBox: false`
and listen to the stream:

```dart
ValueListenableBuilder<DetectionFrame>(
  valueListenable: controller.detections,
  builder: (context, frame, _) {
    // frame.detections -> your own widgets / painter
  },
);
```

---

## 4. Known limitations

- **Orientation (iOS landscape).** iOS now orients the Vision request from the
  live device orientation. The portrait mapping is verified; the landscape and
  upside-down (and front-camera) mappings are *derived* from it, not yet
  device-verified. If a specific orientation is off, it's a one-line change in
  `visionOrientation()` in `CameraPreview.swift`. Android tracks display rotation
  via `OrientationEventListener` and is more robust.
- **Fit modes.** `cover` and `contain` map exactly. `fitWidth`/`fitHeight` map to
  the start/end alignment used natively (`FILL_START`/`FILL_END`); verify against
  your layout if you rely on them.
- **Backend divergence.** Android (object) vs iOS (saliency) can box slightly
  different regions for the same scene.
- **No labels.** It cannot tell you *what* the subject is (see §5.1 / §5.2).
- **Accuracy.** It boxes the *prominent subject*, which is only as good as the
  generic detector. For reliably accurate car boxes, a trained model (§5.2) is
  required.

---

## 5. Going further

Roughly ordered from least to most effort.

### 5.1 Enable coarse classification (small step)

ML Kit object detection can classify into 5 broad categories (fashion good, food,
home good, place, plant). Turn on `enableClassification()` in
`SubjectDetectionAnalyzer` and the `label`/`confidence` fields populate
automatically (the wire contract and painter already support them). Note: **there
is no "vehicle"/"car" category** in the base classifier, so this helps filter
people/plants but does not identify cars.

### 5.2 Car-specific detection (custom model)

To actually detect "car" you need a model trained on vehicle classes (COCO
includes car/truck/bus). Two paths:

- **Android:** ship a TFLite detector (EfficientDet-Lite / YOLO) either via ML
  Kit's custom-model object detection API (keeps the tracking infra) or directly
  with the TFLite Task Library `ObjectDetector`.
- **iOS:** ship a Core ML model (YOLOv3 and others are available from Apple's
  model gallery) and run it with `VNCoreMLRequest` in place of the saliency
  request. `VNRecognizedObjectObservation` already gives box + label + confidence.

The EventChannel contract does not change: emit `label: "car"` and `confidence`.
Filter to vehicle classes natively (cheap) or in Dart (flexible).

Model management to decide: bundle in the app (larger binary, offline) vs download
on first use (smaller binary, needs network + caching).

### 5.3 Outline / segmentation (the "trace the car" ask)

A box is cheap; an outline needs a segmentation mask.

- **Android:** DeepLabv3 (TFLite) for semantic segmentation, or ML Kit **Subject
  Segmentation** for a class-agnostic foreground mask.
- **iOS:** DeepLabV3 Core ML, or Vision `VNGeneratePersonSegmentationRequest`
  (people only). For a class-agnostic subject, the saliency request already
  returns a low-res mask (`VNSaliencyImageObservation.pixelBuffer`).

Delivery options for the mask:

1. **Contour polygon** — trace the mask to a polyline natively, send a list of
   normalized points, draw with a `Path` in Dart. Compact, smooth, easy to style.
2. **Mask bitmap** — send a downscaled alpha mask (e.g. base64/byte array) and
   composite in Dart. Heavier on the wire; more faithful.

Extend the contract with e.g. `"contour": [[x,y], ...]` or `"mask": {...}` per
detection. Masks are much heavier than boxes — throttle harder and downscale.

### 5.4 Smoothing & tracking

**Done:** the primary box is EMA-smoothed in Dart (`detectionSmoothing`) and held
through a short run of empty frames (`_maxMissFrames`) to avoid flicker on brief
misses.

Further improvements if needed:

- Upgrade the EMA to a one-euro filter (velocity-aware) for less lag on fast
  motion while staying stable when still.
- Key smoothing by ML Kit's `trackingId` (already on the wire) once multiple
  boxes are re-enabled, and add iOS tracking via `VNTrackObjectRequest`.

### 5.5 Performance

- Keep `STRATEGY_KEEP_ONLY_LATEST` (Android) and the time-based throttle (iOS,
  currently ~10 fps) so inference never queues behind the camera.
- Run inference off the main/UI thread (already the case on both platforms).
- For TFLite, enable GPU/NNAPI delegates; for Core ML, prefer the Neural Engine.
- Segmentation: downscale input aggressively (e.g. 256px) before inference.
- Expose a target FPS / min-confidence knob so apps can trade accuracy for battery.

---

## 6. File map

| Concern | File |
|---|---|
| Dart data model + wire contract | `lib/detection/subject_detection.dart` |
| Overlay painter + coordinate mapping | `lib/detection/bounding_box_painter.dart` |
| Controller stream + enable/disable | `lib/camera_controller.dart` |
| Widget params + overlay layer | `lib/camera_preview/native_camera_view.dart` |
| Android analyzer (ML Kit) | `android/.../SubjectDetectionAnalyzer.kt` |
| Android use case + EventChannel | `android/.../CameraPreviewFactory.kt` |
| iOS saliency + EventChannel | `ios/Classes/CameraPreview.swift` |
| ML Kit dependency | `android/build.gradle` |
