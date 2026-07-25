import 'package:flutter/material.dart';
import 'dart:io';
// Giả sử package của bạn ở đây
import 'package:native_camera_view/native_camera_view.dart';

void main() {
  // Đảm bảo rằng các binding của Flutter đã được khởi tạo
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

// NEW: Thêm 'WidgetsBindingObserver' để lắng nghe vòng đời ứng dụng
class _MyHomePageState extends State<MyHomePage> with WidgetsBindingObserver {
  // REMOVED: _cameraKey không còn cần thiết
  // var _cameraKey = UniqueKey();

  CameraController? _cameraController;
  CameraPreviewFit _currentFit = CameraPreviewFit.cover;
  final ValueNotifier<bool> isPaused = ValueNotifier(false);
  bool _isFrontCameraSelected = false;

  @override
  void initState() {
    super.initState();
    // NEW: Đăng ký lắng nghe vòng đời ứng dụng
    WidgetsBinding.instance.addObserver(this);
  }

  // NEW: Xử lý các thay đổi vòng đời ứng dụng
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);

    // Nếu controller chưa sẵn sàng, bỏ qua
    if (_cameraController == null || !mounted) {
      return;
    }

    if (state == AppLifecycleState.inactive || state == AppLifecycleState.paused) {
      // Tạm dừng camera khi ứng dụng không active
      if (!isPaused.value) {
        _cameraController?.pauseCamera();
        isPaused.value = true;
        print("AppLifecycle: Camera paused.");
      }
    } else if (state == AppLifecycleState.resumed) {
      // Tiếp tục camera khi ứng dụng quay trở lại
      if (isPaused.value) {
        _cameraController?.resumeCamera();
        isPaused.value = false;
        print("AppLifecycle: Camera resumed.");
      }
    }
  }

  @override
  void dispose() {
    // NEW: Hủy đăng ký lắng nghe
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

  // MODIFIED: Cập nhật logic chụp ảnh để pause/resume
  Future<void> _captureImage() async {
    if (_cameraController == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Controller chưa sẵn sàng.')),
      );
      return;
    }

    // Tạm dừng camera trước khi chụp và điều hướng
    if (!isPaused.value) {
      await _cameraController?.pauseCamera();
      isPaused.value = true;
    }

    final path = await _cameraController?.captureImage();

    if (path != null && mounted) {
      print("Image captured at: $path");

      // Điều hướng sang màn hình xem ảnh
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => DisplayPictureScreen(imagePath: path),
        ),
      );

      // REMOVED: Không cần tạo lại camera nữa
      // setState(() {
      //   _cameraKey = UniqueKey();
      // });

      // MODIFIED: Tiếp tục camera khi người dùng quay lại
      if (mounted && isPaused.value) {
        await _cameraController?.resumeCamera();
        isPaused.value = false;
      }
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Chụp ảnh thất bại.')),
      );
      // Nếu chụp thất bại, resume lại camera
      if (isPaused.value) {
        await _cameraController?.resumeCamera();
        isPaused.value = false;
      }
    }
  }

  Future<void> _switchCamera() async {
    if (_cameraController == null || isPaused.value) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(isPaused.value ? 'Resume camera trước.' : 'Controller chưa sẵn sàng.')),
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
        SnackBar(content: Text(success == true ? 'Đã xóa tất cả ảnh.' : 'Xóa ảnh thất bại hoặc không có ảnh.')),
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
              // Live subject/foreground bounding box (new feature under test).
              enableDetection: true,
              showDetectionBox: true,
              detectionBoxColor: Colors.cyanAccent,
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
