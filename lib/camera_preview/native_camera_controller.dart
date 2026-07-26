// lib/camera/native_camera_controller.dart

import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

// Import the service class that communicates with your native MethodChannel
import '../camera_controller.dart';

/// Manages the state and logic for NativeCameraView.
class NativeCameraController {
  /// Controller for communicating with native code via MethodChannel.
  /// Will be initialized in `onPlatformViewCreated`.
  CameraController? _nativeServiceController;

  /// Callback to pass the initialized `CameraController` up to the parent widget.
  final Function(CameraController controller) onControllerCreated;

  // --- ValueNotifiers for managing state ---
  final ValueNotifier<bool> isLoading = ValueNotifier(true);
  final ValueNotifier<bool> isPermissionGranted = ValueNotifier(false);

  /// Used for one-time events, for example showing a SnackBar.
  final ValueNotifier<String?> snackbarMessage = ValueNotifier(null);

  /// Constructor: receives the callback and starts requesting permission immediately.
  NativeCameraController({required this.onControllerCreated}) {
    // requestCameraPermission();
  }

  // --- Logic methods ---

  /// Called from the view when the native PlatformView is ready.
  void onPlatformViewCreated(int id) {
    const String baseChannelName = "com.plugin.camera_native.native_camera_view/camera_method_channel";
    final String channelName = Platform.isIOS ? '${baseChannelName}_ios_$id' : '${baseChannelName}_$id';

    final platformChannel = MethodChannel(channelName);
    _nativeServiceController = CameraController(channel: platformChannel);

    platformChannel.setMethodCallHandler(_handleNativeMethodCall);

    onControllerCreated(_nativeServiceController!);

    _nativeServiceController!.initialize();

    debugPrint('PlatformView (id: $id) created. CameraController initialized on channel: $channelName');
  }

  Future<void> _handleNativeMethodCall(MethodCall call) async {
    switch (call.method) {
      case 'onCameraReady':
        // Native reports the camera is ready -> hide loading
        if (isLoading.value) {
          isLoading.value = false;
          debugPrint("Native camera is ready. Hiding loading indicator.");
        }
        break;
      case 'onCameraError':
        // Native reports an error -> hide loading and show a message
        if (isLoading.value) {
          isLoading.value = false;
        }
        final Map? args = call.arguments as Map?;
        final String message = args?['message'] ?? "Unknown camera error";
        snackbarMessage.value = "Camera Error: $message";
        debugPrint("Native camera failed to initialize: $message");
        break;
      default:
        // Ignore unknown methods
        break;
    }
  }

  /// MODIFY THIS FUNCTION TO HANDLE PERMISSIONS CORRECTLY
  /// Requests camera access permission from the user.
  Future<void> requestCameraPermission() async {
    // isLoading.value = true;
    //
    // // For BOTH iOS and Android, we let the native view handle
    // // checking permissions and showing the dialog. Flutter's role is only to build the native view.
    // debugPrint("[Flutter Permission] Skipping Dart permission request. Native will handle it.");
    // isPermissionGranted.value = true;
    //
    // isLoading.value = false;
  }

  /// Clears the snackbar message after it has been shown.
  void clearSnackbarMessage() {
    snackbarMessage.value = null;
  }

  /// Cleans up resources to avoid memory leaks.
  void dispose() {
    isLoading.dispose();
    isPermissionGranted.dispose();
    snackbarMessage.dispose();
    _nativeServiceController = null;
    debugPrint("NativeCameraController disposed.");
  }
}
