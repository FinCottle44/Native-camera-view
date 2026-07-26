// File: lib/detection/bounding_box_painter.dart
//
// Maps normalized detection rects onto the preview widget (accounting for the
// active fit mode + front-camera mirroring) and paints them.

import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../camera_controller.dart' show CameraPreviewFit;
import 'subject_detection.dart';

/// Which screen edge the "ground" lies toward in the fixed preview. For a
/// portrait-locked app held in landscape-left, the ground is toward the left.
enum GroundGuideEdge { bottom, top, left, right }

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

/// Returns true when [rect] touches (or exceeds) the bounds of [size] within
/// [marginPx] on any edge — i.e. the subject is likely cropped by the frame.
bool isRectCropped(Rect rect, Size size, double marginPx) {
  return rect.left <= marginPx ||
      rect.top <= marginPx ||
      rect.right >= size.width - marginPx ||
      rect.bottom >= size.height - marginPx;
}

/// Paints the car bounding box for a [DetectionFrame] over the preview. The box
/// is drawn in [color] normally and [croppedColor] when it touches a frame edge
/// (the car is likely cropped).
class BoundingBoxPainter extends CustomPainter {
  final DetectionFrame frame;
  final CameraPreviewFit fit;
  final Color color;
  final Color croppedColor;
  final double strokeWidth;
  final bool showLabel;

  /// Fraction of the smaller widget dimension used as the edge margin for the
  /// cropped check.
  final double edgeMargin;

  /// Whether to draw the bounding box itself.
  final bool showBox;

  /// Whether to draw the translucent ground guide band below the car.
  final bool showGroundGuide;

  /// Minimum ground beyond the car (fraction of the relevant widget dimension)
  /// for the guide to count as sufficient (drawn in [color] not [croppedColor]).
  final double groundMinFraction;

  /// Which edge the ground guide extends from.
  final GroundGuideEdge groundEdge;

  /// How far the ground guide laps into the box, as a fraction of the box's
  /// size along the ground axis. The car region is punched out and the band
  /// fades to transparent as it meets the car.
  final double groundOverlap;

  BoundingBoxPainter({
    required this.frame,
    required this.fit,
    this.color = const Color(0xFF6E23FE),
    this.croppedColor = const Color(0xFFFF3B30),
    this.strokeWidth = 3.0,
    this.showLabel = true,
    this.edgeMargin = 0.02,
    this.showBox = true,
    this.showGroundGuide = false,
    this.groundMinFraction = 0.15,
    this.groundEdge = GroundGuideEdge.bottom,
    this.groundOverlap = 0.15,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (frame.detections.isEmpty) return;

    final marginPx = edgeMargin * math.min(size.width, size.height);

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

      final cropped = isRectCropped(rect, size, marginPx);

      // Ground guide: translucent band from the car toward the ground edge.
      // Drawn first so the box sits on top. Purple when there's enough ground
      // beyond the car, red when not.
      if (showGroundGuide) {
        // The strip runs from the ground-side phone edge to `groundOverlap`
        // past the car's near edge (lapping into the box). `gap` is the actual
        // clearance (phone edge -> car near edge) used for the enough-ground
        // check; `dim` is the full dimension. The gradient runs opaque at the
        // phone edge -> transparent as it meets the car (no harsh cutoff), and
        // the car region is punched out so the band never covers the car.
        final (Rect strip, double gap, double dim, Alignment gBegin, Alignment gEnd) =
            switch (groundEdge) {
          GroundGuideEdge.bottom => (
              Rect.fromLTRB(
                0,
                (rect.bottom - groundOverlap * rect.height).clamp(0.0, size.height),
                size.width,
                size.height,
              ),
              size.height - rect.bottom,
              size.height,
              Alignment.bottomCenter,
              Alignment.topCenter,
            ),
          GroundGuideEdge.top => (
              Rect.fromLTRB(
                0,
                0,
                size.width,
                (rect.top + groundOverlap * rect.height).clamp(0.0, size.height),
              ),
              rect.top,
              size.height,
              Alignment.topCenter,
              Alignment.bottomCenter,
            ),
          GroundGuideEdge.left => (
              Rect.fromLTRB(
                0,
                0,
                (rect.left + groundOverlap * rect.width).clamp(0.0, size.width),
                size.height,
              ),
              rect.left,
              size.width,
              Alignment.centerLeft,
              Alignment.centerRight,
            ),
          GroundGuideEdge.right => (
              Rect.fromLTRB(
                (rect.right - groundOverlap * rect.width).clamp(0.0, size.width),
                0,
                size.width,
                size.height,
              ),
              size.width - rect.right,
              size.width,
              Alignment.centerRight,
              Alignment.centerLeft,
            ),
        };
        if (dim > 0 && strip.width > 0 && strip.height > 0) {
          final bool enough = (gap / dim) >= groundMinFraction;
          final Color base = enough ? color : croppedColor;
          final Paint fill = Paint()
            ..style = PaintingStyle.fill
            ..shader = LinearGradient(
              begin: gBegin,
              end: gEnd,
              colors: [
                base.withValues(alpha: 0.30),
                base.withValues(alpha: 0.30),
                base.withValues(alpha: 0.0),
              ],
              stops: const [0.0, 0.7, 1.0],
            ).createShader(strip);
          // Punch the car out of the strip (difference) so the ground laps up
          // the sides of the box but never paints over the car itself. Round the
          // hole's corners that sit on the car's ground-side edge to match the
          // box's rounded corners (radius 8 below); the inner cut stays square.
          final Rect hole = strip.intersect(rect);
          if (hole.width > 0 && hole.height > 0) {
            final double r =
                math.min(8.0, math.min(hole.width, hole.height) / 2);
            final Radius rad = Radius.circular(r);
            final RRect holeRRect = switch (groundEdge) {
              GroundGuideEdge.top =>
                RRect.fromRectAndCorners(hole, topLeft: rad, topRight: rad),
              GroundGuideEdge.bottom => RRect.fromRectAndCorners(hole,
                  bottomLeft: rad, bottomRight: rad),
              GroundGuideEdge.left =>
                RRect.fromRectAndCorners(hole, topLeft: rad, bottomLeft: rad),
              GroundGuideEdge.right =>
                RRect.fromRectAndCorners(hole, topRight: rad, bottomRight: rad),
            };
            final Path region = Path.combine(
              PathOperation.difference,
              Path()..addRect(strip),
              Path()..addRRect(holeRRect),
            );
            canvas.drawPath(region, fill);
          } else {
            canvas.drawRect(strip, fill);
          }
        }
      }

      if (showBox) {
        final drawColor = cropped ? croppedColor : color;
        final boxPaint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth
          ..color = drawColor;

        final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(8));
        canvas.drawRRect(rrect, boxPaint);

        if (showLabel && (detection.label != null || detection.confidence != null)) {
          _paintLabel(canvas, rect, detection, drawColor);
        }
      }
    }
  }

  void _paintLabel(
      Canvas canvas, Rect rect, SubjectDetection detection, Color bgColor) {
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
    canvas.drawRect(bgRect, Paint()..color = bgColor);
    textPainter.paint(canvas, Offset(bgRect.left, bgRect.top + 2));
  }

  @override
  bool shouldRepaint(covariant BoundingBoxPainter oldDelegate) {
    return oldDelegate.frame != frame ||
        oldDelegate.fit != fit ||
        oldDelegate.color != color ||
        oldDelegate.croppedColor != croppedColor ||
        oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.showLabel != showLabel ||
        oldDelegate.edgeMargin != edgeMargin ||
        oldDelegate.showBox != showBox ||
        oldDelegate.showGroundGuide != showGroundGuide ||
        oldDelegate.groundMinFraction != groundMinFraction ||
        oldDelegate.groundEdge != groundEdge ||
        oldDelegate.groundOverlap != groundOverlap;
  }
}
