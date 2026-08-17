// File: lib/camera_controller.dart
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show debugPrint, ValueNotifier;

import 'detection/subject_detection.dart';

/// Global toggle for the plugin's verbose diagnostic logging (Dart side).
///
/// Every line is tagged `NCVDIAG` so you can filter it in one place, e.g.
/// `flutter logs | grep NCVDIAG` (the iOS and Android native layers emit the
/// same tag). Left on by default while chasing the intermittent blank-preview
/// issue; set to `false` to silence.
bool nativeCameraViewDiagnostics = true;

/// Emits a single tagged, timestamped diagnostic line. [area] is a short
/// sub-system label (e.g. `init`, `native`, `watchdog`) to make grepping easier.
void ncvLog(String area, String message) {
  if (!nativeCameraViewDiagnostics) return;
  final ts = DateTime.now().toIso8601String();
  // debugPrint (not print) so the lines are throttled with the rest of Flutter's
  // logging and stripped appropriately in release tooling.
  debugPrint('NCVDIAG $ts [dart/$area] $message');
}

// Enum to define fit modes for camera preview
enum CameraPreviewFit {
  fitWidth,
  fitHeight,
  contain,
  cover,
}

class CameraController {
  final MethodChannel _channel;
  final EventChannel? _detectionChannel;
  StreamSubscription<dynamic>? _detectionSubscription;

  bool _isFrontCamera = false;
  bool get isFrontCamera => _isFrontCamera;

  final ValueNotifier<bool> isPaused = ValueNotifier(false);
  final ValueNotifier<bool> isLoading = ValueNotifier(true);
  final ValueNotifier<String?> errorMessage = ValueNotifier(null);

  /// Latest live subject-detection result. Emits [DetectionFrame.empty] until
  /// the first frame arrives (or when detection is disabled). Only produces
  /// data when the view was created with `enableDetection: true`.
  ///
  /// When [detectionSmoothing] > 0 the primary box is smoothed across frames to
  /// remove jitter.
  final ValueNotifier<DetectionFrame> detections =
      ValueNotifier(DetectionFrame.empty);

  /// Whether a car is currently detected in the frame. Advisory only.
  final ValueNotifier<bool> isCarDetected = ValueNotifier(false);

  /// Whether the detected car touches a frame edge (i.e. it's likely cropped /
  /// cut off in the shot). Always false when no car is detected. Drive a
  /// "move back / center the car" warning from this. Advisory only — it never
  /// blocks capture.
  final ValueNotifier<bool> isCarCropped = ValueNotifier(false);

  /// Which frame edge(s) the detected car is cropped against, for more specific
  /// hints (e.g. "move right — the car's cut off on the left"). Empty when the
  /// car is fully in frame or no car is detected; non-empty exactly when
  /// [isCarCropped] is true.
  ///
  /// Sides are in the fixed/natural (portrait) display orientation, not how the
  /// scene looks to the user — see [CropSide]. Computed natively against the
  /// visible preview, so they agree with what's shown. Advisory only.
  final ValueNotifier<Set<CropSide>> croppedSides =
      ValueNotifier(const <CropSide>{});

  /// Whether there's enough ground/foreground beneath the detected car (per the
  /// view's `groundGuideMinFraction`). True when no car is detected, so drive a
  /// hint from `isCarDetected && !hasEnoughGround`. Advisory only.
  final ValueNotifier<bool> hasEnoughGround = ValueNotifier(true);

  /// Exponential smoothing factor for the primary box, 0.0..1.0. Higher is
  /// snappier (0.0 disables smoothing, 1.0 = no smoothing). ~0.4 is a good
  /// balance between responsiveness and stability.
  final double detectionSmoothing;

  // Smoothing state.
  Rect? _smoothedRect;
  SubjectDetection? _lastPrimary;
  int _missFrames = 0;
  static const int _maxMissFrames = 5;

  // --- Diagnostics (blank-preview watchdog) ---
  // If the native side never reports `onCameraReady`, the preview area shows
  // blank. This watchdog logs loudly while that persists so an intermittent
  // failure leaves a trace.
  Timer? _readyWatchdog;
  final Stopwatch _sinceInit = Stopwatch();
  bool _cameraReadyReceived = false;
  bool _firstDetectionLogged = false;

  CameraController({
    required MethodChannel channel,
    EventChannel? detectionChannel,
    this.detectionSmoothing = 0.4,
  })  : _channel = channel,
        _detectionChannel = detectionChannel {
    ncvLog('controller',
        'created (channel=${channel.name}, detection=${detectionChannel != null}, smoothing=$detectionSmoothing)');
    _channel.setMethodCallHandler(_handleNativeMethodCall);
    _subscribeToDetections();
  }

  /// Logs (loudly) while the camera has not reported ready, so an intermittent
  /// "blank preview" that never recovers leaves a trail. Cancelled as soon as
  /// `onCameraReady`/`onCameraError` arrives, or on dispose.
  void _startReadyWatchdog() {
    _readyWatchdog?.cancel();
    int elapsed = 0;
    _readyWatchdog = Timer.periodic(const Duration(seconds: 4), (t) {
      if (_cameraReadyReceived) {
        t.cancel();
        return;
      }
      elapsed += 4;
      ncvLog('watchdog',
          'camera STILL not ready after ${elapsed}s — isLoading=${isLoading.value}, '
          'isPaused=${isPaused.value}, error=${errorMessage.value}. The native '
          'preview likely failed to start/attach (this is the blank-preview case).');
      if (elapsed >= 20) t.cancel();
    });
  }

  void _subscribeToDetections() {
    final channel = _detectionChannel;
    if (channel == null) {
      ncvLog('detect', 'no detection channel (detection disabled)');
      return;
    }
    ncvLog('detect', 'subscribing to detection event stream');
    _detectionSubscription = channel.receiveBroadcastStream().listen(
      (event) {
        if (event is! Map) return;
        if (!_firstDetectionLogged) {
          _firstDetectionLogged = true;
          ncvLog('detect',
              'first detection event received (frames are flowing natively)');
        }
        final frame = DetectionFrame.fromMap(event);
        detections.value =
            detectionSmoothing <= 0 ? frame : _smoothFrame(frame);
        // Framing state, computed natively against the visible preview.
        isCarDetected.value =
            event['isDetected'] as bool? ?? frame.detections.isNotEmpty;
        isCarCropped.value = event['isCropped'] as bool? ?? false;
        croppedSides.value = _parseCroppedSides(event['croppedSides']);
        hasEnoughGround.value = event['hasEnoughGround'] as bool? ?? true;
      },
      onError: (Object error) {
        ncvLog('detect', 'stream error: $error');
        debugPrint("CameraController: detection stream error: $error");
      },
      onDone: () => ncvLog('detect', 'detection stream closed'),
    );
  }

  /// Applies EMA smoothing to the primary (first) box and holds the last box
  /// through a short run of empty frames to avoid flicker.
  DetectionFrame _smoothFrame(DetectionFrame frame) {
    final primary = frame.detections.isNotEmpty ? frame.detections.first : null;

    if (primary == null) {
      _missFrames++;
      if (_missFrames > _maxMissFrames || _smoothedRect == null) {
        _smoothedRect = null;
        _lastPrimary = null;
        return DetectionFrame(
          imageWidth: frame.imageWidth,
          imageHeight: frame.imageHeight,
          isMirrored: frame.isMirrored,
          detections: const <SubjectDetection>[],
        );
      }
      // Hold the last smoothed box briefly.
      return _frameWith(frame, _smoothedRect!, _lastPrimary!);
    }

    _missFrames = 0;
    final target = primary.normalizedRect;
    final prev = _smoothedRect;
    final t = detectionSmoothing.clamp(0.0, 1.0);
    final smoothed = prev == null
        ? target
        : Rect.fromLTRB(
            _lerp(prev.left, target.left, t),
            _lerp(prev.top, target.top, t),
            _lerp(prev.right, target.right, t),
            _lerp(prev.bottom, target.bottom, t),
          );
    _smoothedRect = smoothed;
    _lastPrimary = primary;
    return _frameWith(frame, smoothed, primary);
  }

  DetectionFrame _frameWith(
      DetectionFrame frame, Rect rect, SubjectDetection source) {
    return DetectionFrame(
      imageWidth: frame.imageWidth,
      imageHeight: frame.imageHeight,
      isMirrored: frame.isMirrored,
      detections: <SubjectDetection>[
        SubjectDetection(
          left: rect.left,
          top: rect.top,
          right: rect.right,
          bottom: rect.bottom,
          confidence: source.confidence,
          label: source.label,
          trackingId: source.trackingId,
        ),
      ],
    );
  }

  static double _lerp(double a, double b, double t) => a + (b - a) * t;

  /// Parses the native `croppedSides` payload (a list of edge names) into a
  /// [CropSide] set. Unknown/missing values are ignored.
  static Set<CropSide> _parseCroppedSides(Object? raw) {
    if (raw is! List || raw.isEmpty) return const <CropSide>{};
    final sides = <CropSide>{};
    for (final s in raw) {
      switch (s) {
        case 'left':
          sides.add(CropSide.left);
          break;
        case 'top':
          sides.add(CropSide.top);
          break;
        case 'right':
          sides.add(CropSide.right);
          break;
        case 'bottom':
          sides.add(CropSide.bottom);
          break;
      }
    }
    return sides;
  }

  /// Turns live subject detection on or off at runtime. The view must have been
  /// created with `enableDetection: true` for the native analyzer to be wired.
  Future<void> setDetectionEnabled(bool enabled) async {
    ncvLog('detect', 'setDetectionEnabled($enabled)');
    try {
      await _channel.invokeMethod('setDetectionEnabled', enabled);
      if (!enabled) {
        _smoothedRect = null;
        _lastPrimary = null;
        _missFrames = 0;
        detections.value = DetectionFrame.empty;
        isCarDetected.value = false;
        isCarCropped.value = false;
        croppedSides.value = const <CropSide>{};
        hasEnoughGround.value = true;
      }
    } on PlatformException catch (e) {
      debugPrint("CameraController: Error setting detection enabled: '${e.message}'.");
    }
  }

  Future<void> _handleNativeMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onCameraReady':
        _cameraReadyReceived = true;
        _readyWatchdog?.cancel();
        ncvLog('native',
            'onCameraReady (${_sinceInit.isRunning ? '${_sinceInit.elapsedMilliseconds}ms after initialize' : 'no init timing'})');
        if (isLoading.value) {
          isLoading.value = false;
          ncvLog('state', 'isLoading -> false (preview should now be visible)');
        }
        break;
      case 'onCameraError':
        _readyWatchdog?.cancel();
        final Map? args = call.arguments as Map?;
        final msg = args?['message'] ?? "Unknown camera error";
        ncvLog('native',
            'onCameraError: $msg (${_sinceInit.elapsedMilliseconds}ms after initialize)');
        if (isLoading.value) isLoading.value = false;
        errorMessage.value = msg;
        break;
      default:
        ncvLog('native', 'unhandled native call: ${call.method}');
    }
  }

  Future<void> initialize() async {
    _cameraReadyReceived = false;
    _sinceInit
      ..reset()
      ..start();
    _startReadyWatchdog();
    ncvLog('init', 'sending initialize to native');
    try {
      await _channel.invokeMethod('initialize');
      ncvLog('init', 'initialize invokeMethod returned (awaiting onCameraReady)');
    } on PlatformException catch (e) {
      ncvLog('init', 'initialize FAILED: ${e.code} / ${e.message}');
      debugPrint("CameraController: Failed to send initialize command: '${e.message}'.");
    }
  }

  /// Captures a still image and returns the file path.
  Future<String?> captureImage() async {
    try {
      final String? filePath = await _channel.invokeMethod('captureImage');
      debugPrint('CameraController: Image captured at: $filePath');
      return filePath;
    } on PlatformException catch (e) {
      debugPrint("CameraController: Capture failed: '${e.message}'.");
      return null;
    }
  }

  /// Pauses the camera preview.
  Future<void> pauseCamera() async {
    ncvLog('lifecycle', 'pauseCamera requested');
    try {
      await _channel.invokeMethod('pauseCamera');
      isPaused.value = true;
      ncvLog('lifecycle', 'pauseCamera sent (isPaused -> true)');
    } on PlatformException catch (e) {
      ncvLog('lifecycle', 'pauseCamera FAILED: ${e.message}');
      debugPrint("CameraController: Error pausing camera: '${e.message}'.");
    }
  }

  /// Resumes the camera preview.
  Future<void> resumeCamera() async {
    ncvLog('lifecycle', 'resumeCamera requested');
    // A blank preview after resume is a common failure mode, so re-arm the
    // readiness watchdog: native re-binds and should emit onCameraReady again.
    _cameraReadyReceived = false;
    _sinceInit
      ..reset()
      ..start();
    _startReadyWatchdog();
    try {
      await _channel.invokeMethod('resumeCamera');
      isPaused.value = false;
      ncvLog('lifecycle', 'resumeCamera sent (isPaused -> false, awaiting re-ready)');
    } on PlatformException catch (e) {
      ncvLog('lifecycle', 'resumeCamera FAILED: ${e.message}');
      debugPrint("CameraController: Error resuming camera: '${e.message}'.");
    }
  }

  /// Switches between front and back cameras.
  Future<void> switchCamera(bool useFrontCamera) async {
    ncvLog('lifecycle', 'switchCamera requested (useFront=$useFrontCamera)');
    try {
      await _channel.invokeMethod('switchCamera', {'useFrontCamera': useFrontCamera});
      _isFrontCamera = useFrontCamera;
      ncvLog('lifecycle', 'switchCamera sent (useFront=$useFrontCamera)');
    } on PlatformException catch (e) {
      ncvLog('lifecycle', 'switchCamera FAILED: ${e.message}');
      debugPrint("CameraController: Error switching camera: '${e.message}'.");
    }
  }

  /// Sets the camera zoom level.
  /// [zoomLevel] should be >= 1.0. The maximum depends on the device hardware.
  /// Use [getMaxZoom] to query the device's maximum supported zoom.
  Future<void> setZoom(double zoomLevel) async {
    try {
      await _channel.invokeMethod('setZoom', {'zoom': zoomLevel});
    } on PlatformException catch (e) {
      debugPrint("CameraController: Error setting zoom: '${e.message}'.");
    }
  }

  /// Sets the target rotation for photo capture.
  /// Use 0 for portrait, 90 for landscape-right, 180 for portrait upside-down,
  /// 270 for landscape-left. This ensures the captured photo is oriented correctly
  /// without needing post-capture rotation in Dart.
  Future<void> setTargetRotation(int rotation) async {
    try {
      await _channel.invokeMethod('setTargetRotation', {'rotation': rotation});
    } on PlatformException catch (e) {
      debugPrint("CameraController: Error setting target rotation: '${e.message}'.");
    }
  }

  /// Returns the maximum zoom level supported by the current camera.
  /// Returns 1.0 if the value cannot be determined.
  Future<double> getMaxZoom() async {
    try {
      final double? maxZoom = await _channel.invokeMethod<double>('getMaxZoom');
      return maxZoom ?? 1.0;
    } on PlatformException catch (e) {
      debugPrint("CameraController: Error getting max zoom: '${e.message}'.");
      return 1.0;
    }
  }

  /// Returns the minimum zoom level supported by the current camera.
  /// Typically 1.0 on most devices.
  Future<double> getMinZoom() async {
    try {
      final double? minZoom = await _channel.invokeMethod<double>('getMinZoom');
      return minZoom ?? 1.0;
    } on PlatformException catch (e) {
      debugPrint("CameraController: Error getting min zoom: '${e.message}'.");
      return 1.0;
    }
  }

  /// Deletes all photos captured by this plugin from the cache directory.
  Future<bool> deleteAllCapturedPhotos() async {
    try {
      final bool? success = await _channel.invokeMethod('deleteAllCapturedPhotos');
      if (success == true) {
        debugPrint('CameraController: All captured photos deleted.');
        return true;
      } else {
        debugPrint('CameraController: Delete photos failed or no response.');
        return false;
      }
    } on PlatformException catch (e) {
      debugPrint("CameraController: Error deleting photos: '${e.message}'.");
      return false;
    }
  }

  void dispose() {
    ncvLog('controller', 'dispose');
    _readyWatchdog?.cancel();
    _readyWatchdog = null;
    _detectionSubscription?.cancel();
    _detectionSubscription = null;
    isPaused.dispose();
    isLoading.dispose();
    errorMessage.dispose();
    detections.dispose();
    isCarDetected.dispose();
    isCarCropped.dispose();
    croppedSides.dispose();
    hasEnoughGround.dispose();
    _channel.setMethodCallHandler(null);
  }
}
