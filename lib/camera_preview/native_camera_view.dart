// lib/camera/native_camera_view.dart

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../camera_controller.dart';
import '../detection/subject_detection.dart';
import '../detection/bounding_box_painter.dart';

//đặt độ phân giải
enum CameraResolutionPreset { low, medium, high, max }

//chế độ chụp ảnh
enum CameraCaptureMode { minimizeLatency, maximizeQuality }

class NativeCameraView extends StatefulWidget {
  final CameraPreviewFit? cameraPreviewFit;
  final bool? isFrontCamera;
  final Function(CameraController controller) onControllerCreated;
  final bool? bypassPermissionCheck;
  final Widget? loadingWidget;

  final CameraResolutionPreset? previewPreset;
  final CameraResolutionPreset? capturePreset;
  final CameraCaptureMode? captureMode;

  /// Enables the live subject/foreground detection pipeline natively. When
  /// false (default) no ML work runs and no analysis frames are produced.
  final bool enableDetection;

  /// When true (default) and [enableDetection] is on, the plugin draws the
  /// built-in bounding-box overlay. Set to false to consume
  /// `controller.detections` yourself and draw a custom overlay.
  final bool showDetectionBox;

  /// Stroke color of the built-in bounding box.
  final Color detectionBoxColor;

  /// Stroke width of the built-in bounding box.
  final double detectionBoxStrokeWidth;

  /// Temporal smoothing for the detection box, 0.0..1.0. Higher is snappier;
  /// 0.0 disables smoothing. Defaults to 0.4.
  final double detectionSmoothing;

  const NativeCameraView({
    super.key,
    required this.onControllerCreated,
    this.cameraPreviewFit,
    this.isFrontCamera,
    this.bypassPermissionCheck,
    this.loadingWidget,
    this.previewPreset,
    this.capturePreset,
    this.captureMode,
    this.enableDetection = false,
    this.showDetectionBox = true,
    this.detectionBoxColor = const Color(0xFF00E5FF),
    this.detectionBoxStrokeWidth = 3.0,
    this.detectionSmoothing = 0.4,
  });

  @override
  State<NativeCameraView> createState() => _NativeCameraViewState();
}

class _NativeCameraViewState extends State<NativeCameraView> {
  CameraController? _controller;

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  void _onPlatformViewCreated(int id) {
    const String baseChannelName = "com.plugin.camera_native.native_camera_view/camera_method_channel";
    final String channelName = Platform.isIOS ? '${baseChannelName}_ios_$id' : '${baseChannelName}_$id';
    final platformChannel = MethodChannel(channelName);

    EventChannel? detectionChannel;
    if (widget.enableDetection) {
      const String detectionBase =
          "com.plugin.camera_native.native_camera_view/camera_detections";
      final String detectionChannelName =
          Platform.isIOS ? '${detectionBase}_ios_$id' : '${detectionBase}_$id';
      detectionChannel = EventChannel(detectionChannelName);
    }

    // Dùng setState để gán controller và build lại widget
    setState(() {
      _controller = CameraController(
        channel: platformChannel,
        detectionChannel: detectionChannel,
        detectionSmoothing: widget.detectionSmoothing,
      );
    });

    widget.onControllerCreated(_controller!);
    _controller!.initialize();
  }

  @override
  Widget build(BuildContext context) {
    // ✨ Thêm lại Stack và ValueListenableBuilder để quản lý UI loading ✨
    return Stack(
      alignment: Alignment.center,
      children: [
        // Lớp 1: Camera View luôn được build ở dưới cùng
        _buildPlatformCameraView(),

        // Lớp 1.5: Detection bounding-box overlay
        if (_controller != null && widget.enableDetection && widget.showDetectionBox)
          Positioned.fill(
            child: ValueListenableBuilder<DetectionFrame>(
              valueListenable: _controller!.detections,
              builder: (context, frame, _) {
                return CustomPaint(
                  painter: BoundingBoxPainter(
                    frame: frame,
                    fit: widget.cameraPreviewFit ?? CameraPreviewFit.cover,
                    color: widget.detectionBoxColor,
                    strokeWidth: widget.detectionBoxStrokeWidth,
                  ),
                );
              },
            ),
          ),

        // Lớp 2: Lớp loading nằm đè lên trên
        // Chỉ build lớp này khi controller đã được tạo
        if (_controller != null)
          ValueListenableBuilder<bool>(
            valueListenable: _controller!.isLoading,
            builder: (context, isLoading, _) {
              if (isLoading) {
                return Positioned.fill(
                  child: widget.loadingWidget ?? const Center(child: CircularProgressIndicator()),
                );
              } else {
                return const SizedBox.shrink();
              }
            },
          ),
      ],
    );
  }

  Widget _buildPlatformCameraView() {
    const String androidViewType = 'com.plugin.camera_native.native_camera_view/camera_preview_android';
    const String iosViewType = 'com.plugin.camera_native.native_camera_view/camera_preview_ios';

    final creationParams = <String, dynamic>{
      'cameraPreviewFit': widget.cameraPreviewFit?.name ?? 'cover',
      'isFrontCamera': widget.isFrontCamera ?? false,
      'bypassPermissionCheck': widget.bypassPermissionCheck ?? false,
      'previewPreset': widget.previewPreset?.name,
      'capturePreset': widget.capturePreset?.name,
      'captureMode': widget.captureMode?.name,
      'enableDetection': widget.enableDetection,
    };

    final key = ValueKey("native_camera_platform_view_${creationParams['isFrontCamera']}");

    if (Platform.isAndroid) {
      return AndroidView(
        key: key,
        viewType: androidViewType,
        creationParams: creationParams,
        creationParamsCodec: const StandardMessageCodec(),
        onPlatformViewCreated: _onPlatformViewCreated,
      );
    } else if (Platform.isIOS) {
      return UiKitView(
        key: key,
        viewType: iosViewType,
        creationParams: creationParams,
        creationParamsCodec: const StandardMessageCodec(),
        onPlatformViewCreated: _onPlatformViewCreated,
      );
    }

    return const Center(child: Text("Nền tảng không được hỗ trợ."));
  }
}
