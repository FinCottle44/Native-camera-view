// File: lib/detection/bounding_box_painter.dart
//
// Maps normalized detection rects onto the preview widget (accounting for the
// active fit mode + front-camera mirroring) and paints them.

import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../camera_controller.dart' show CameraPreviewFit;
import 'subject_detection.dart';

/// Converts a single [SubjectDetection] (normalized, image space) into a pixel
/// [Rect] in the coordinate space of a preview widget of [widgetSize], applying
/// the same scaling/cropping that the native preview uses for [fit], plus
/// mirroring when [isMirrored] is true.
///
/// Returns null when the frame dimensions or widget size are degenerate.
Rect? mapDetectionToWidget({
  required SubjectDetection detection,
  required Size widgetSize,
  required int imageWidth,
  required int imageHeight,
  required bool isMirrored,
  required CameraPreviewFit fit,
}) {
  if (widgetSize.width <= 0 ||
      widgetSize.height <= 0 ||
      imageWidth <= 0 ||
      imageHeight <= 0) {
    return null;
  }

  double left = detection.left;
  double right = detection.right;
  double top = detection.top;
  double bottom = detection.bottom;

  // The preview mirrors the front camera; flip X so the box lands on the
  // mirrored subject.
  if (isMirrored) {
    final double flippedLeft = 1.0 - right;
    final double flippedRight = 1.0 - left;
    left = flippedLeft;
    right = flippedRight;
  }

  final double imgW = imageWidth.toDouble();
  final double imgH = imageHeight.toDouble();
  final double viewW = widgetSize.width;
  final double viewH = widgetSize.height;

  final double scaleX = viewW / imgW;
  final double scaleY = viewH / imgH;

  // Pick the scale that matches the native ScaleType for this fit mode.
  //   cover      -> FILL_CENTER  (scale to cover, center-crop)
  //   contain    -> FIT_START    (scale to fit)
  //   fitWidth   -> FILL_START    (match width)
  //   fitHeight  -> FILL_END      (match height)
  final double scale;
  switch (fit) {
    case CameraPreviewFit.cover:
      scale = math.max(scaleX, scaleY);
      break;
    case CameraPreviewFit.contain:
      scale = math.min(scaleX, scaleY);
      break;
    case CameraPreviewFit.fitWidth:
      scale = scaleX;
      break;
    case CameraPreviewFit.fitHeight:
      scale = scaleY;
      break;
  }

  final double displayW = imgW * scale;
  final double displayH = imgH * scale;

  // Offset/alignment: cover & contain are centered. fitWidth aligns to the
  // start (top-left) and fitHeight to the end (bottom-right), mirroring the
  // FILL_START / FILL_END semantics on the native side.
  double offsetX;
  double offsetY;
  switch (fit) {
    case CameraPreviewFit.fitWidth:
      offsetX = 0;
      offsetY = 0;
      break;
    case CameraPreviewFit.fitHeight:
      offsetX = viewW - displayW;
      offsetY = viewH - displayH;
      break;
    case CameraPreviewFit.cover:
    case CameraPreviewFit.contain:
      offsetX = (viewW - displayW) / 2.0;
      offsetY = (viewH - displayH) / 2.0;
      break;
  }

  return Rect.fromLTRB(
    left * displayW + offsetX,
    top * displayH + offsetY,
    right * displayW + offsetX,
    bottom * displayH + offsetY,
  );
}

/// Paints bounding boxes for a [DetectionFrame] over the preview.
class BoundingBoxPainter extends CustomPainter {
  final DetectionFrame frame;
  final CameraPreviewFit fit;
  final Color color;
  final double strokeWidth;
  final bool showLabel;

  BoundingBoxPainter({
    required this.frame,
    required this.fit,
    this.color = const Color(0xFF00E5FF),
    this.strokeWidth = 3.0,
    this.showLabel = true,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (frame.detections.isEmpty) return;

    final boxPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..color = color;

    for (final detection in frame.detections) {
      final rect = mapDetectionToWidget(
        detection: detection,
        widgetSize: size,
        imageWidth: frame.imageWidth,
        imageHeight: frame.imageHeight,
        isMirrored: frame.isMirrored,
        fit: fit,
      );
      if (rect == null) continue;

      final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(8));
      canvas.drawRRect(rrect, boxPaint);

      if (showLabel && (detection.label != null || detection.confidence != null)) {
        _paintLabel(canvas, rect, detection);
      }
    }
  }

  void _paintLabel(Canvas canvas, Rect rect, SubjectDetection detection) {
    final labelParts = <String>[];
    if (detection.label != null) labelParts.add(detection.label!);
    if (detection.confidence != null) {
      labelParts.add('${(detection.confidence! * 100).toStringAsFixed(0)}%');
    }
    if (labelParts.isEmpty) return;

    final textPainter = TextPainter(
      text: TextSpan(
        text: ' ${labelParts.join('  ')} ',
        style: const TextStyle(
          color: Colors.black,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final bgRect = Rect.fromLTWH(
      rect.left,
      math.max(0, rect.top - textPainter.height - 4),
      textPainter.width,
      textPainter.height + 4,
    );
    canvas.drawRect(bgRect, Paint()..color = color);
    textPainter.paint(canvas, Offset(bgRect.left, bgRect.top + 2));
  }

  @override
  bool shouldRepaint(covariant BoundingBoxPainter oldDelegate) {
    return oldDelegate.frame != frame ||
        oldDelegate.fit != fit ||
        oldDelegate.color != color ||
        oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.showLabel != showLabel;
  }
}
