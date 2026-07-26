// File: lib/camera_controller.dart
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show debugPrint, ValueNotifier;

import 'detection/subject_detection.dart';

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

  CameraController({
    required MethodChannel channel,
    EventChannel? detectionChannel,
    this.detectionSmoothing = 0.4,
  })  : _channel = channel,
        _detectionChannel = detectionChannel {
    _channel.setMethodCallHandler(_handleNativeMethodCall);
    _subscribeToDetections();
  }

  void _subscribeToDetections() {
    final channel = _detectionChannel;
    if (channel == null) return;
    _detectionSubscription = channel.receiveBroadcastStream().listen(
      (event) {
        if (event is! Map) return;
        final frame = DetectionFrame.fromMap(event);
        detections.value =
            detectionSmoothing <= 0 ? frame : _smoothFrame(frame);
        // Framing state, computed natively against the visible preview.
        isCarDetected.value =
            event['isDetected'] as bool? ?? frame.detections.isNotEmpty;
        isCarCropped.value = event['isCropped'] as bool? ?? false;
        hasEnoughGround.value = event['hasEnoughGround'] as bool? ?? true;
      },
      onError: (Object error) {
        debugPrint("CameraController: detection stream error: $error");
      },
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

  /// Turns live subject detection on or off at runtime. The view must have been
  /// created with `enableDetection: true` for the native analyzer to be wired.
  Future<void> setDetectionEnabled(bool enabled) async {
    try {
      await _channel.invokeMethod('setDetectionEnabled', enabled);
      if (!enabled) {
        _smoothedRect = null;
        _lastPrimary = null;
        _missFrames = 0;
        detections.value = DetectionFrame.empty;
        isCarDetected.value = false;
        isCarCropped.value = false;
        hasEnoughGround.value = true;
      }
    } on PlatformException catch (e) {
      debugPrint("CameraController: Error setting detection enabled: '${e.message}'.");
    }
  }

  Future<void> _handleNativeMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onCameraReady':
        if (isLoading.value) isLoading.value = false;
        break;
      case 'onCameraError':
        if (isLoading.value) isLoading.value = false;
        final Map? args = call.arguments as Map?;
        errorMessage.value = args?['message'] ?? "Unknown camera error";
        break;
    }
  }

  Future<void> initialize() async {
    try {
      await _channel.invokeMethod('initialize');
    } on PlatformException catch (e) {
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
    try {
      await _channel.invokeMethod('pauseCamera');
      isPaused.value = true;
      debugPrint('CameraController: Pause command sent.');
    } on PlatformException catch (e) {
      debugPrint("CameraController: Error pausing camera: '${e.message}'.");
    }
  }

  /// Resumes the camera preview.
  Future<void> resumeCamera() async {
    try {
      await _channel.invokeMethod('resumeCamera');
      isPaused.value = false;
      debugPrint('CameraController: Resume command sent.');
    } on PlatformException catch (e) {
      debugPrint("CameraController: Error resuming camera: '${e.message}'.");
    }
  }

  /// Switches between front and back cameras.
  Future<void> switchCamera(bool useFrontCamera) async {
    try {
      await _channel.invokeMethod('switchCamera', {'useFrontCamera': useFrontCamera});
      debugPrint('CameraController: Switch camera (useFront: $useFrontCamera) sent.');
      _isFrontCamera = useFrontCamera;
    } on PlatformException catch (e) {
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
    _detectionSubscription?.cancel();
    _detectionSubscription = null;
    isPaused.dispose();
    isLoading.dispose();
    errorMessage.dispose();
    detections.dispose();
    isCarDetected.dispose();
    isCarCropped.dispose();
    hasEnoughGround.dispose();
    _channel.setMethodCallHandler(null);
  }
}
