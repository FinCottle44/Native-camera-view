# Live Car Detection & Bounding Box

This document describes the live car-detection bounding-box feature in
`native_camera_view`, and lays out options for making it more capable
(outline/segmentation, tracking, custom models).

---

## 1. What ships today

A live, on-device **car bounding box**. When enabled, the plugin runs a trained
object detector on the camera stream and reports a single stable box around the
most prominent car each frame. The box is drawn in `#6E23FE`, turning **red when
the car touches a frame edge** (i.e. it's likely cropped). The purpose is to
help users frame the whole car — it's **advisory only and never blocks capture**.

Key properties:

- **Trained car detector.** Bundled EfficientDet-Lite0 (COCO), filtered to the
  `car` class — a real car detection, not a generic saliency/foreground guess.
- **Bundled model, permissive license.** The `.tflite` ships inside the app
  (~7.3 MB, the **float16** build); EfficientDet-Lite0 is Apache-2.0 (safe for
  closed-source apps). Float16 (not int8) is used so the MediaPipe **GPU/Metal**
  delegate can run it — the int8 build only runs on CPU.
- **Opt-in.** Nothing runs unless you pass `enableDetection: true`.
- **Single, stable box.** When multiple cars are detected, a composite scoring
  function selects the most prominent one — not simply the largest. The score
  combines four weighted factors:
    1. **Relative area (35%)** — larger cars score higher, but size alone won't
       win if the car is off to the side.
    2. **Center proximity (30%)** — cars closer to the frame center are strongly
       preferred, since the user typically points the camera at their subject.
    3. **Detection confidence (15%)** — the model's own confidence score; closer,
       clearer cars tend to score higher.
    4. **Tracking continuity (20%)** — the previously-selected car receives a
       bonus (based on IoU overlap with the last frame's selection), so the box
       doesn't jump between cars frame-to-frame even when scores are close.

  The resulting box is temporally smoothed (EMA + a short hold on missed frames)
  so it tracks smoothly instead of flickering. On iOS the smoothing is native; on
  Android it runs in the Dart controller.
- **Graceful fade-out.** When the car finally leaves the frame, the overlay (box
  + ground guide) fades out over `detectionFadeDuration` (default 200ms) instead
  of vanishing abruptly, and snaps back to full opacity the instant a car is
  reacquired. iOS fades the native layers' opacity; Android fades the Dart
  overlay while holding the last box.
- **Single-orientation detection (configurable).** The consuming app runs
  landscape-left only, where the car is found on the un-rotated frame, so
  detection runs a single pass (`.up`) — no orientation sensing, no wasted
  inference. The rotation-tolerant machinery is still present: adding
  `[.right, .left, .down]` to `detectionOrientationCandidates` restores detection
  in any holding (at the cost of extra inference while acquiring). While tracking,
  only the last winning orientation is re-checked, so it stays one inference.
- **iOS draws the box natively on the preview.** The box is a `CAShapeLayer`
  positioned via the preview layer's own `layerRectConverted(fromMetadataOutputRect:)`,
  so it lands exactly where the preview shows the car (no Dart-side coordinate
  mapping). Path changes are animated (~0.12s) so the box glides at the display
  refresh rate instead of stepping at the ~10fps detection rate. Android draws it
  with the Dart overlay (`CustomPaint`).
- **Advisory only.** Detection never touches the capture path — a missed or
  wrong detection can never prevent taking a photo.

### Platform backends

Both platforms run the **same** bundled EfficientDet-Lite0 model via **MediaPipe
Tasks Vision** `ObjectDetector`, so behaviour is consistent.

| | Android | iOS |
|---|---|---|
| Runtime | MediaPipe `tasks-vision` | MediaPipe `MediaPipeTasksVision` |
| Model | `efficientdet_lite0.tflite` (bundled asset) | same file (bundled resource) |
| Frame source | CameraX `ImageAnalysis` (RGBA) | existing `AVCaptureVideoDataOutput` |
| Min OS | API 24 | iOS 13 |
| Class filter | `car`, filtered in code | `car`, filtered in code |
| Primary box | composite-scored car (area + center + confidence + continuity) | composite-scored car (area + center + confidence + continuity) |
| Orientation | single-pass `.up` (landscape-left; configurable) | single-pass `.up` (landscape-left; configurable) |
| Box drawing | Dart `CustomPaint` overlay | native `CAShapeLayer` on the preview |
| Smoothing | Dart controller (EMA) | native (EMA + grace frames) |

### iOS integration requirement

MediaPipe ships a **static** xcframework, so apps consuming this plugin must set
static linkage in their `ios/Podfile`:

```ruby
target 'Runner' do
  use_frameworks! :linkage => :static
  ...
end
```

Without this the build fails with `Unable to find module dependency:
'MediaPipeTasksVision'`. The example app's Podfile already does this.

### Tuning knobs

All the on-screen helpers are toggleable at widget instantiation:

- `enableDetection` — master switch for the pipeline (default off). Nothing runs
  unless this is on.
- `showDetectionBox` — draw the bounding box (default on).
- `showGroundGuide` — draw the translucent "ground guide" band from the
  ground-side edge toward the car (default off). A cue to leave enough
  ground/foreground beside the car: ~30% purple when there's enough, red when
  not. The band is a gradient that's solid at the phone edge and fades to
  transparent as it meets the car (no hard cutoff), laps a little way up the
  sides of the car, and has the car region punched out so it never paints over
  the car itself.
- `groundGuideMinFraction` — minimum ground beyond the car, as a fraction of the
  relevant preview dimension, to count as sufficient (default 0.15). Below this
  the guide turns red and `controller.hasEnoughGround` is false. (This measures
  the actual clearance edge→car and is independent of `groundGuideOverlap`.)
- `groundGuideEdge` — which edge the ground lies toward: `bottom` (default),
  `top`, `left`, or `right`. A portrait-locked app held in landscape-left should
  use `GroundGuideEdge.left`.
- `groundGuideOverlap` — how far the band laps into the car box, as a fraction
  of the box's size along the ground axis (default 0.15). The band fades to
  transparent as it meets the car and the car region is punched out, so the
  ground appears to lap up around the car's ground-side corners without covering
  the car. Set to 0.0 for a band that stops exactly at the car's edge.
- `detectionBoxColor` — box color when the car is fully in frame (default
  `#6E23FE`). Reused (at 30% alpha) for the "enough ground" band.
- `croppedBoxColor` — box color when the car touches an edge (default red
  `#FF3B30`). Reused (at 30% alpha) for the "not enough ground" band.
- `croppedEdgeMargin` — edge margin for the cropped check, as a fraction of the
  smaller preview dimension (default 0.02).
- `detectionBoxStrokeWidth` — overlay stroke width.
- `detectionSmoothing` — 0.0..1.0 EMA factor (default 0.4; higher = snappier,
  0.0 disables smoothing).
- `detectionFadeDuration` — how long the overlay (box + ground guide) takes to
  fade out when the car leaves the frame (default 200ms). It still snaps in
  immediately on (re)acquisition. Applies to both platforms.
- Native score threshold: `SCORE_THRESHOLD` in `SubjectDetectionAnalyzer.kt` and
  `detectionMinConfidence` in `CameraPreview.swift`.

---

## 2. How it's wired

```
 Android: ImageAnalysis ─▶ MediaPipe ─▶ EventChannel ─▶ Dart Stream ─▶ CustomPaint overlay
 iOS:     captureOutput  ─▶ MediaPipe ─┬▶ native CAShapeLayer on the preview (the visible box)
                                       └▶ EventChannel ─▶ Dart Stream (for consumers/state)
```

On iOS the visible box is drawn natively; the EventChannel is still emitted so
Dart consumers can react to detections (e.g. a cropped-state warning). On Android
the EventChannel drives the `CustomPaint` overlay that draws the box.

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
      "confidence": 0.87,     // detector score
      "label":  "car"         // always "car" (category allowlist)
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

Alongside `detections`, each event carries the natively-computed framing state
(see §5.1): `isDetected` (bool), `isCropped` (bool), `croppedSides` (list of
`"left"`/`"top"`/`"right"`/`"bottom"` — edges of the display/portrait frame), and
`hasEnoughGround` (bool). `croppedSides` is non-empty exactly when `isCropped` is
true.

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
  enableDetection: true,               // turn the pipeline on
  // iOS draws the box natively on the preview, so the Dart overlay is only
  // needed on Android. Setting it true on iOS would draw a second box.
  showDetectionBox: Platform.isAndroid,
  detectionSmoothing: 0.4,             // Android Dart smoothing (iOS smooths natively)
  cameraPreviewFit: CameraPreviewFit.cover,
  onControllerCreated: (controller) {
    _controller = controller;
  },
);
```

The `label` (`"car"`) and `confidence` fields are populated on each
`SubjectDetection`, so a custom overlay can display them.

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

- **Tuned for landscape-left.** Detection runs only the un-rotated pass, which is
  where the car is found in the app's landscape-left usage. Other holdings won't
  detect until you re-enable the extra rotation candidates (see §1). EfficientDet-Lite0
  only recognizes a roughly-upright car, so a re-enabled multi-pass still flickers
  at in-between angles (~45°) — CoreMotion would be the lever for rock-solid odd
  angles.
- **iOS box drawing is native; Android is Dart.** iOS positions the box via the
  preview layer, so it's exact by construction. On Android, Preview + ImageAnalysis
  (+ ImageCapture) are bound in a `UseCaseGroup` with a shared `ViewPort` taken
  from the `PreviewView` (FILL_CENTER), and the analyzer crops each frame to the
  resulting `ImageProxy.cropRect`, so the analyzed field of view matches exactly
  what the preview shows. The Dart `cover` mapping then lands the box correctly
  regardless of the app's preview resolution/layout. (Before this, the analyzer
  ran on the full analysis buffer while the preview showed a different FOV, so
  boxes rendered consistently smaller and the ground thresholds skewed — visible
  in apps that sized/configured the preview differently from the example app.)
- **Android assumes `cover` (FILL_CENTER).** The shared `ViewPort` and the native
  cropped/ground math are all cover-based. A non-`cover` `cameraPreviewFit` on
  Android will misalign the overlay and skew the thresholds; use `cover`, or
  extend the native math + ViewPort fit type to match the chosen fit.
- **Cropped check (iOS) is preview-frame based.** The red/edge check runs against
  the preview bounds (what the user sees), which is what matters for framing.
- **Single class.** Only `car` is reported. Trucks/buses/vans are ignored unless
  you add them to the category allowlist (`SubjectDetectionAnalyzer.kt` /
  `CameraPreview.swift`).
- **Accuracy ceiling.** EfficientDet-Lite0 is a small, fast model. It's solid for
  a clearly-framed car but can miss unusual angles, partial cars, or poor light.
  A larger EfficientDet-Lite variant or a fine-tuned model (§5.2) improves this.
- **iOS Podfile.** Consumers must use `use_frameworks! :linkage => :static` (see
  §1).

---

## 5. Going further

### 5.1 Framing state — DONE

The controller exposes framing signals so apps can drive warnings:

- `controller.isCarDetected` (`ValueNotifier<bool>`) — a car is currently in view.
- `controller.isCarCropped` (`ValueNotifier<bool>`) — the detected car touches a
  frame edge (likely cut off). Always false when no car is detected.
- `controller.croppedSides` (`ValueNotifier<Set<CropSide>>`) — *which* edge(s)
  the car is cropped against, for directional hints. Empty unless `isCarCropped`
  is true (they always agree). **Sides are in the fixed/natural (portrait)
  display orientation, not how the user sees the scene**: `CropSide.left`/`right`
  are the portrait frame's short edges and `top`/`bottom` its long-side edges,
  regardless of how the phone is held. See `CropSide` for the full contract.
- `controller.hasEnoughGround` (`ValueNotifier<bool>`) — enough ground/foreground
  beneath the car (per `groundGuideMinFraction`). True when no car is detected,
  so gate a hint on `isCarDetected && !hasEnoughGround`.

All are computed **natively against the visible preview** (iOS: box vs preview
layer bounds; Android: vs `PreviewView` with `FILL_CENTER`) and sent in the
detection payload (`isDetected` / `isCropped` / `croppedSides` / `hasEnoughGround`),
so they match exactly what the user sees. Advisory only — they never block capture.

```dart
AnimatedBuilder(
  animation: Listenable.merge([
    controller.isCarDetected, controller.croppedSides, controller.hasEnoughGround,
  ]),
  builder: (context, _) {
    if (!controller.isCarDetected.value) return const SizedBox.shrink();
    final sides = controller.croppedSides.value;
    if (sides.isNotEmpty) {
      // Portrait-frame sides. Held in landscape-left, the frame's short edges
      // (left/right) are what the user perceives as up/down, so map them to
      // your own on-screen arrows if you want screen-relative hints.
      if (sides.contains(CropSide.left)) return const Text("Car's cut off — pan toward the frame's left");
      if (sides.contains(CropSide.right)) return const Text("Car's cut off — pan toward the frame's right");
      return const Text('Move back to fit the whole car');
    }
    if (!controller.hasEnoughGround.value) return const Text('Leave more ground below the car');
    return const SizedBox.shrink();
  },
);
```

### 5.1a Ground guide overlay — DONE

`showGroundGuide: true` draws a translucent band from the car toward the
`groundGuideEdge` (e.g. from the car's left edge to the left of the preview for a
landscape-left app) — ~30% purple when there's enough ground, red when not
(threshold `groundGuideMinFraction`). It's drawn natively on iOS (a `CAShapeLayer`
below the box, gliding with it) and via the Dart painter on Android, reusing the
box colors. It reads as a "ground plane" cue so users leave foreground beyond the
car. The band and `hasEnoughGround` share the same edge + threshold, so the
visual and the state agree.

Note: the built-in Dart overlay (box + ground guide) only renders on **Android**;
on **iOS** everything is drawn natively on the preview, so `showDetectionBox` /
`showGroundGuide` can be true on both platforms without double-drawing.

Note: on iOS the state is derived from the smoothed/held box, so it's stable.
On Android it currently tracks raw detections and may flicker more; if needed,
debounce it or move smoothing native on Android too.

### 5.2 Better accuracy (bigger / fine-tuned model)

The detector is a drop-in `.tflite`:

- **Larger stock model:** swap `efficientdet_lite0.tflite` for `lite1`/`lite2`
  (more accurate, slower/larger) — replace the bundled file on both platforms.
- **Fine-tuned model:** train/fine-tune on your own car imagery (e.g. via MediaPipe
  Model Maker) and drop in the resulting `.tflite`. Keep the label the code
  filters on in sync (`car`).
- **More vehicle classes:** add `truck`/`bus` to the category allowlist and
  (optionally) relabel them as "car" for a unified box.

No wire-contract or Dart changes needed for any of these.

### 5.3 Outline / segmentation (the "trace the car" ask)

A box is cheap; an outline needs a segmentation mask.

Since we already depend on MediaPipe Tasks Vision, the natural path is its
**`ImageSegmenter`** (DeepLab-v3 / SelfieMulticlass models) on both platforms —
same dependency, same bundling approach, one code path. A COCO/semantic model
gives a vehicle mask you can trace.

Delivery options for the mask:

1. **Contour polygon** — trace the mask to a polyline natively, send a list of
   normalized points, draw with a `Path` in Dart. Compact, smooth, easy to style.
2. **Mask bitmap** — send a downscaled alpha mask (e.g. base64/byte array) and
   composite in Dart. Heavier on the wire; more faithful.

Extend the contract with e.g. `"contour": [[x,y], ...]` or `"mask": {...}` per
detection. Masks are much heavier than boxes — throttle harder and downscale.

### 5.4 Smoothing & tracking

**Done:** the primary box is EMA-smoothed and held through a short run of empty
frames to avoid flicker on brief misses — natively on iOS (`smoothedBox` /
`detectionMaxMissFrames` in `CameraPreview.swift`) and in the Dart controller on
Android (`detectionSmoothing`).

Further improvements if needed:

- Upgrade the EMA to a one-euro filter (velocity-aware) for less lag on fast
  motion while staying stable when still.
- Switch the detector to MediaPipe's `.video`/`.liveStream` running mode for
  built-in temporal association across frames.

### 5.5 Performance

- Keep `STRATEGY_KEEP_ONLY_LATEST` (Android) and the time-based throttle (iOS,
  ~10 fps) so inference never queues behind the camera.
- Inference runs off the main/UI thread on both platforms.
- The GPU delegate is enabled by default (`baseOptions.delegate = .GPU` on iOS)
  with an automatic CPU fallback. Two GPU gotchas, both handled:
  - It requires a **float** model — the int8 build fails GPU init
    (`quantization.type != kTfLiteAffineQuantization`) and falls back to CPU, so
    the bundled model is float16.
  - A single-category **`categoryAllowlist` crashes the GPU path**
    (`Only all classes >= class 0 or >= class 1`). So no allowlist is set; we
    filter detections to `car` in code instead (`detectLargestCar`).
- Larger models (lite1/lite2) cost more per frame — pair with a lower throttle.

---

## 6. File map

| Concern | File |
|---|---|
| Dart data model + wire contract | `lib/detection/subject_detection.dart` |
| Overlay painter + crop coloring | `lib/detection/bounding_box_painter.dart` |
| Controller stream + smoothing + enable/disable | `lib/camera_controller.dart` |
| Widget params + overlay layer | `lib/camera_preview/native_camera_view.dart` |
| Android detector (MediaPipe) | `android/.../SubjectDetectionAnalyzer.kt` |
| Android use case + EventChannel | `android/.../CameraPreviewFactory.kt` |
| iOS detector + EventChannel | `ios/Classes/CameraPreview.swift` |
| MediaPipe dependency | `android/build.gradle`, `ios/native_camera_view.podspec` |
| Bundled model | `android/src/main/assets/efficientdet_lite0.tflite`, `ios/Resources/efficientdet_lite0.tflite` |
