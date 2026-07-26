import 'package:flutter/material.dart';
import 'dart:io';
// Assume your package is here
import 'package:native_camera_view/native_camera_view.dart';

void main() {
  // Ensure that Flutter bindings are initialized
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Native Camera View Example',
      theme: ThemeData(
        colorSchemeSeed: Colors.teal,
        useMaterial3: true,
        brightness: Brightness.light,
      ),
      darkTheme: ThemeData(
        colorSchemeSeed: Colors.teal,
        useMaterial3: true,
        brightness: Brightness.dark,
      ),
      home: const MyHomePage(),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

// NEW: Add 'WidgetsBindingObserver' to listen to the app lifecycle
class _MyHomePageState extends State<MyHomePage> with WidgetsBindingObserver {
  // REMOVED: _cameraKey is no longer needed
  // var _cameraKey = UniqueKey();

  CameraController? _cameraController;
  CameraPreviewFit _currentFit = CameraPreviewFit.cover;
  final ValueNotifier<bool> isPaused = ValueNotifier(false);
  bool _isFrontCameraSelected = false;

  @override
  void initState() {
    super.initState();
    // NEW: Register to listen to the app lifecycle
    WidgetsBinding.instance.addObserver(this);
  }

  // NEW: Handle app lifecycle changes
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    // If the controller is not ready yet, skip
    if (_cameraController == null || !mounted) {
      return;
    }

    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      // Pause the camera when the app is not active
      if (!isPaused.value) {
        _cameraController?.pauseCamera();
        isPaused.value = true;
        print("AppLifecycle: Camera paused.");
      }
    } else if (state == AppLifecycleState.resumed) {
      // Resume the camera when the app comes back
      if (isPaused.value) {
        _cameraController?.resumeCamera();
        isPaused.value = false;
        print("AppLifecycle: Camera resumed.");
      }
    }
  }

  @override
  void dispose() {
    // NEW: Unregister the listener
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _onCameraControllerCreated(CameraController controller) {
    if (mounted) {
      setState(() {
        _cameraController = controller;
      });
      print("Example App: CameraController created and received!");
    }
  }

  Future<void> _togglePauseResume() async {
    if (_cameraController == null) return;
    if (isPaused.value) {
      await _cameraController?.resumeCamera();
      isPaused.value = false;
    } else {
      await _cameraController?.pauseCamera();
      isPaused.value = true;
    }
  }

  // MODIFIED: Updated capture logic to pause/resume
  Future<void> _captureImage() async {
    if (_cameraController == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Controller is not ready.')),
      );
      return;
    }

    // Pause the camera before capturing and navigating
    if (!isPaused.value) {
      await _cameraController?.pauseCamera();
      isPaused.value = true;
    }

    final path = await _cameraController?.captureImage();

    if (path != null && mounted) {
      print("Image captured at: $path");

      // Navigate to the image viewer screen
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => DisplayPictureScreen(imagePath: path),
        ),
      );

      // REMOVED: No need to recreate the camera anymore
      // setState(() {
      //   _cameraKey = UniqueKey();
      // });

      // MODIFIED: Resume the camera when the user comes back
      if (mounted && isPaused.value) {
        await _cameraController?.resumeCamera();
        isPaused.value = false;
      }
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Image capture failed.')),
      );
      // If capture failed, resume the camera
      if (isPaused.value) {
        await _cameraController?.resumeCamera();
        isPaused.value = false;
      }
    }
  }

  Future<void> _switchCamera() async {
    if (_cameraController == null || isPaused.value) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(isPaused.value ? 'Resume the camera first.' : 'Controller is not ready.')),
      );
      return;
    }
    final newIsFront = !_isFrontCameraSelected;
    await _cameraController?.switchCamera(newIsFront);
    if (mounted) {
      setState(() {
        _isFrontCameraSelected = newIsFront;
      });
    }
  }

  void _changeCameraFit(CameraPreviewFit? fit) {
    if (fit == null || (isPaused.value)) return;
    if (mounted) {
      setState(() {
        _currentFit = fit;
      });
    }
  }

  Future<void> _deleteAllPhotos() async {
    if (_cameraController == null) return;
    bool? success = await _cameraController?.deleteAllCapturedPhotos();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(success == true ? 'All photos deleted.' : 'Failed to delete photos or there were none.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        elevation: 0,
        title: Text('Camera Plugin (${Platform.operatingSystem})'),
        actions: [
          if (_cameraController != null)
            ValueListenableBuilder<bool>(
              valueListenable: isPaused,
              builder: (context, isPaused, child) {
                return Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: Icon(isPaused ? Icons.play_arrow : Icons.pause),
                      tooltip: isPaused ? 'Resume' : 'Pause',
                      onPressed: _togglePauseResume,
                    ),
                    IconButton(
                      icon: const Icon(Icons.cameraswitch_outlined),
                      tooltip: 'Switch Camera',
                      onPressed: isPaused ? null : _switchCamera,
                    ),
                  ],
                );
              },
            ),
        ],
      ),
      body: Stack(
        children: [
          Positioned.fill(
            child: NativeCameraView(
              onControllerCreated: _onCameraControllerCreated,
              cameraPreviewFit: CameraPreviewFit.cover,
              isFrontCamera: _isFrontCameraSelected,
              // iOS draws the box natively on the preview (see
              // CameraPreview.swift), so the Dart overlay is only used on
              // Android.
              enableDetection: true,
              // Box shows on both platforms (iOS native, Android Dart overlay).
              showDetectionBox: true,
              showGroundGuide: true,
              // App is held in landscape-left, so the ground is toward the left.
              groundGuideEdge: GroundGuideEdge.left,
            ),
          ),
          if (_cameraController != null)
            Positioned(
              top: 16,
              right: 16,
              child: ElevatedButton.icon(
                icon: const Icon(Icons.delete_sweep_outlined, size: 20),
                label: const Text("Delete image"),
                onPressed: _deleteAllPhotos,
                style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.red.withOpacity(0.7),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    textStyle: const TextStyle(fontSize: 12)),
              ),
            ),
          // Framing warnings driven by the controller's detection state.
          if (_cameraController != null)
            Positioned(
              top: 60,
              left: 16,
              right: 16,
              child: AnimatedBuilder(
                animation: Listenable.merge([
                  _cameraController!.isCarDetected,
                  _cameraController!.isCarCropped,
                  _cameraController!.hasEnoughGround,
                ]),
                builder: (context, _) {
                  final detected = _cameraController!.isCarDetected.value;
                  final cropped = _cameraController!.isCarCropped.value;
                  final enoughGround = _cameraController!.hasEnoughGround.value;
                  String? message;
                  if (detected && cropped) {
                    message = 'Car is cut off — move back to fit the whole car';
                  } else if (detected && !enoughGround) {
                    message = 'Leave more ground below the car';
                  }
                  if (message == null) return const SizedBox.shrink();
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: Colors.red.withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      message,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600),
                    ),
                  );
                },
              ),
            ),
          if (_cameraController != null)
            Positioned(
              bottom: 30.0,
              left: 0,
              right: 0,
              child: Align(
                alignment: Alignment.center,
                child: FloatingActionButton(
                  onPressed: isPaused.value ? null : _captureImage,
                  tooltip: 'Take image',
                  backgroundColor: Colors.white.withValues(alpha: 0.8),
                  child: const Icon(Icons.camera_alt, color: Colors.black87, size: 30),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class DisplayPictureScreen extends StatelessWidget {
  final String imagePath;
  const DisplayPictureScreen({super.key, required this.imagePath});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Photo taken')),
      backgroundColor: Colors.black,
      body: Center(
        child: InteractiveViewer(
          maxScale: 4.0,
          minScale: 0.5,
          child: Image.file(File(imagePath)),
        ),
      ),
    );
  }
}
