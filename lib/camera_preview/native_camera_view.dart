// lib/camera/native_camera_view.dart

import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../camera_controller.dart';
import '../detection/subject_detection.dart';
import '../detection/bounding_box_painter.dart';

//sets the resolution
enum CameraResolutionPreset { low, medium, high, max }

//photo capture mode
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

  /// Stroke color of the box when the car is fully in frame.
  final Color detectionBoxColor;

  /// Stroke color of the box when the car touches a frame edge (likely cropped).
  final Color croppedBoxColor;

  /// Fraction of the smaller preview dimension used as the edge margin for the
  /// cropped check. Defaults to 0.02 (2%).
  final double croppedEdgeMargin;

  /// Stroke width of the built-in bounding box.
  final double detectionBoxStrokeWidth;

  /// Temporal smoothing for the detection box, 0.0..1.0. Higher is snappier;
  /// 0.0 disables smoothing. Defaults to 0.4.
  final double detectionSmoothing;

  /// When true and [enableDetection] is on, shows a translucent "ground guide"
  /// band below the detected car — a cue to leave enough ground/foreground
  /// beneath the car. Purple (~30% opacity) when there's enough ground, red when
  /// not. Defaults to false.
  final bool showGroundGuide;

  /// Minimum ground beyond the car, as a fraction of the relevant preview
  /// dimension, for the ground to count as sufficient (guide drawn purple rather
  /// than red, and `controller.hasEnoughGround` true). Defaults to 0.15 (15%).
  final double groundGuideMinFraction;

  /// Which edge the ground guide extends from. For a portrait-locked app used in
  /// landscape-left, set this to [GroundGuideEdge.left]. Defaults to
  /// [GroundGuideEdge.bottom].
  final GroundGuideEdge groundGuideEdge;

  /// How far the ground guide laps into the car box, as a fraction of the box's
  /// size along the ground axis. The band fades out as it approaches the car
  /// and the car itself is punched out, so this controls how far the ground
  /// "wraps" up around the car's ground-side corners. Defaults to 0.15 (15%).
  final double groundGuideOverlap;

  /// How long the detection overlay (box + ground guide) takes to fade out when
  /// the car leaves the frame, instead of vanishing abruptly. The overlay still
  /// snaps in immediately when a car is (re)acquired. Defaults to 200ms.
  final Duration detectionFadeDuration;

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
    this.detectionBoxColor = const Color(0xFF6E23FE),
    this.croppedBoxColor = const Color(0xFFFF3B30),
    this.croppedEdgeMargin = 0.02,
    this.detectionBoxStrokeWidth = 3.0,
    this.detectionSmoothing = 0.4,
    this.showGroundGuide = false,
    this.groundGuideMinFraction = 0.15,
    this.groundGuideEdge = GroundGuideEdge.bottom,
    this.groundGuideOverlap = 0.15,
    this.detectionFadeDuration = const Duration(milliseconds: 200),
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

    // Use setState to assign the controller and rebuild the widget
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
    // ✨ Re-add Stack and ValueListenableBuilder to manage the loading UI ✨
    return Stack(
      alignment: Alignment.center,
      children: [
        // Layer 1: Camera View is always built at the bottom
        _buildPlatformCameraView(),

        // Layer 1.5: Detection overlay (box + ground guide) — Android only.
        // iOS draws these natively on the preview, so the Dart painter is never
        // used there (its coordinate mapping wouldn't match the iOS preview).
        if (Platform.isAndroid &&
            _controller != null &&
            widget.enableDetection &&
            (widget.showDetectionBox || widget.showGroundGuide))
          Positioned.fill(
            child: _DetectionOverlay(
              controller: _controller!,
              fit: widget.cameraPreviewFit ?? CameraPreviewFit.cover,
              color: widget.detectionBoxColor,
              croppedColor: widget.croppedBoxColor,
              edgeMargin: widget.croppedEdgeMargin,
              strokeWidth: widget.detectionBoxStrokeWidth,
              showBox: widget.showDetectionBox,
              showGroundGuide: widget.showGroundGuide,
              groundMinFraction: widget.groundGuideMinFraction,
              groundEdge: widget.groundGuideEdge,
              groundOverlap: widget.groundGuideOverlap,
              fadeDuration: widget.detectionFadeDuration,
            ),
          ),

        // Layer 2: The loading layer sits on top
        // Only build this layer once the controller has been created
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
      'showDetectionBox': widget.showDetectionBox,
      'showGroundGuide': widget.showGroundGuide,
      'groundGuideMinFraction': widget.groundGuideMinFraction,
      'groundGuideEdge': widget.groundGuideEdge.name,
      'groundGuideOverlap': widget.groundGuideOverlap,
      'detectionFadeMillis': widget.detectionFadeDuration.inMilliseconds,
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

    return const Center(child: Text("Platform not supported."));
  }
}

/// Android detection overlay (box + ground guide) with a quick fade-out.
///
/// The native [BoundingBoxPainter] draws nothing for an empty frame, so a lost
/// car would otherwise vanish abruptly. This widget retains the last frame that
/// had a detection and fades a [FadeTransition] out over [fadeDuration] when the
/// car leaves, then snaps back to full opacity the instant a car is reacquired.
///
/// (iOS draws the overlay natively and fades there; this is the Android path.)
class _DetectionOverlay extends StatefulWidget {
  const _DetectionOverlay({
    required this.controller,
    required this.fit,
    required this.color,
    required this.croppedColor,
    required this.edgeMargin,
    required this.strokeWidth,
    required this.showBox,
    required this.showGroundGuide,
    required this.groundMinFraction,
    required this.groundEdge,
    required this.groundOverlap,
    required this.fadeDuration,
  });

  final CameraController controller;
  final CameraPreviewFit fit;
  final Color color;
  final Color croppedColor;
  final double edgeMargin;
  final double strokeWidth;
  final bool showBox;
  final bool showGroundGuide;
  final double groundMinFraction;
  final GroundGuideEdge groundEdge;
  final double groundOverlap;
  final Duration fadeDuration;

  @override
  State<_DetectionOverlay> createState() => _DetectionOverlayState();
}

class _DetectionOverlayState extends State<_DetectionOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fade = AnimationController(
    vsync: this,
    duration: widget.fadeDuration,
    value: 0.0,
  );

  /// The most recent frame that contained a detection. Kept while fading out so
  /// the box/ground guide stay painted (dimming) rather than disappearing.
  DetectionFrame _lastNonEmpty = DetectionFrame.empty;

  @override
  void initState() {
    super.initState();
    widget.controller.detections.addListener(_onDetections);
    // Seed directly (no setState during initState) in case a car is already
    // detected when the overlay mounts.
    final frame = widget.controller.detections.value;
    if (frame.detections.isNotEmpty) {
      _lastNonEmpty = frame;
      _fade.value = 1.0;
    }
  }

  void _onDetections() {
    final frame = widget.controller.detections.value;
    if (frame.detections.isNotEmpty) {
      // Car present: repaint at the new position and make sure we're visible,
      // cancelling any in-flight fade-out (snap in).
      _lastNonEmpty = frame;
      if (_fade.value != 1.0) _fade.value = 1.0;
      if (mounted) setState(() {});
    } else if (_fade.value > 0.0 && !_fade.isAnimating) {
      // Car lost: fade the retained box out. The FadeTransition drives the
      // repaint as it dims, so no setState is needed here.
      _fade.reverse(from: _fade.value);
    }
  }

  @override
  void didUpdateWidget(covariant _DetectionOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.detections.removeListener(_onDetections);
      widget.controller.detections.addListener(_onDetections);
    }
    _fade.duration = widget.fadeDuration;
  }

  @override
  void dispose() {
    widget.controller.detections.removeListener(_onDetections);
    _fade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: CustomPaint(
        painter: BoundingBoxPainter(
          frame: _lastNonEmpty,
          fit: widget.fit,
          color: widget.color,
          croppedColor: widget.croppedColor,
          edgeMargin: widget.edgeMargin,
          strokeWidth: widget.strokeWidth,
          showLabel: false,
          showBox: widget.showBox,
          showGroundGuide: widget.showGroundGuide,
          groundMinFraction: widget.groundMinFraction,
          groundEdge: widget.groundEdge,
          groundOverlap: widget.groundOverlap,
        ),
      ),
    );
  }
}
