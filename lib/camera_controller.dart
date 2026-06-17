// File: lib/camera_controller.dart
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show debugPrint, ValueNotifier;

// Enum to define fit modes for camera preview
enum CameraPreviewFit {
  fitWidth,
  fitHeight,
  contain,
  cover,
}

class CameraController {
  final MethodChannel _channel;

  bool _isFrontCamera = false;
  bool get isFrontCamera => _isFrontCamera;

  final ValueNotifier<bool> isPaused = ValueNotifier(false);
  final ValueNotifier<bool> isLoading = ValueNotifier(true);
  final ValueNotifier<String?> errorMessage = ValueNotifier(null);

  CameraController({required MethodChannel channel}) : _channel = channel {
    _channel.setMethodCallHandler(_handleNativeMethodCall);
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
    isPaused.dispose();
    isLoading.dispose();
    _channel.setMethodCallHandler(null);
  }
}
