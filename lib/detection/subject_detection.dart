// File: lib/detection/subject_detection.dart
//
// Shared data model for the live "subject / foreground bounding box" feature.
//
// These types describe the payload that native code (Android ML Kit object
// detection, iOS Vision saliency) streams to Dart over the per-view
// detection EventChannel.
//
// Coordinate contract (IMPORTANT):
//   * All box edges are normalized to the range 0.0..1.0.
//   * The origin is the TOP-LEFT of the analyzed frame, expressed in the
//     frame's DISPLAY orientation (i.e. already rotated upright to match the
//     preview). This keeps Dart free of any sensor-rotation math.
//   * [DetectionFrame.isMirrored] is true when the normalized coordinates are
//     in a NON-mirrored space but the preview is mirrored (front camera on
//     Android). When true, consumers must flip X (left' = 1 - right) before
//     mapping to the mirrored preview. iOS mirrors the buffer natively and
//     therefore reports isMirrored = false.

import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';

/// A single detected subject/foreground object for one analyzed frame.
@immutable
class SubjectDetection {
  /// Normalized left edge (0.0..1.0), top-left origin, display orientation.
  final double left;

  /// Normalized top edge (0.0..1.0).
  final double top;

  /// Normalized right edge (0.0..1.0).
  final double right;

  /// Normalized bottom edge (0.0..1.0).
  final double bottom;

  /// Detection confidence in 0.0..1.0, when the backend provides one.
  ///
  /// iOS saliency exposes a per-object confidence; ML Kit object detection in
  /// its default (non-classifying) mode does not, so this may be null.
  final double? confidence;

  /// Coarse label when available (e.g. a classifier category). Null for the
  /// pure foreground/saliency mode shipped in v1.
  final String? label;

  /// Stable id used to track the same object across frames, when the backend
  /// supports it (ML Kit stream mode does; iOS saliency does not).
  final int? trackingId;

  const SubjectDetection({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    this.confidence,
    this.label,
    this.trackingId,
  });

  /// Normalized rect in image space (top-left origin), before any mirroring or
  /// fit mapping is applied.
  Rect get normalizedRect => Rect.fromLTRB(left, top, right, bottom);

  factory SubjectDetection.fromMap(Map<dynamic, dynamic> map) {
    double d(Object? v, double fallback) =>
        v is num ? v.toDouble() : fallback;
    return SubjectDetection(
      left: d(map['left'], 0),
      top: d(map['top'], 0),
      right: d(map['right'], 0),
      bottom: d(map['bottom'], 0),
      confidence: map['confidence'] is num
          ? (map['confidence'] as num).toDouble()
          : null,
      label: map['label'] as String?,
      trackingId: map['trackingId'] is num
          ? (map['trackingId'] as num).toInt()
          : null,
    );
  }

  @override
  String toString() =>
      'SubjectDetection(rect: $normalizedRect, confidence: $confidence, '
      'label: $label, trackingId: $trackingId)';
}

/// The full result for one analyzed frame: the source frame dimensions (in
/// display orientation), whether coordinates need mirroring, and the list of
/// detected subjects.
@immutable
class DetectionFrame {
  /// Width of the analyzed frame in display orientation (pixels).
  final int imageWidth;

  /// Height of the analyzed frame in display orientation (pixels).
  final int imageHeight;

  /// See the coordinate contract at the top of this file.
  final bool isMirrored;

  /// All subjects detected in this frame (may be empty).
  final List<SubjectDetection> detections;

  const DetectionFrame({
    required this.imageWidth,
    required this.imageHeight,
    required this.isMirrored,
    required this.detections,
  });

  /// Aspect ratio (width / height) of the analyzed frame. Falls back to 1.0
  /// when dimensions are unknown to avoid divide-by-zero.
  double get aspectRatio =>
      (imageWidth <= 0 || imageHeight <= 0) ? 1.0 : imageWidth / imageHeight;

  bool get isEmpty => detections.isEmpty;

  static const DetectionFrame empty = DetectionFrame(
    imageWidth: 0,
    imageHeight: 0,
    isMirrored: false,
    detections: <SubjectDetection>[],
  );

  factory DetectionFrame.fromMap(Map<dynamic, dynamic> map) {
    final rawList = map['detections'];
    final detections = <SubjectDetection>[];
    if (rawList is List) {
      for (final item in rawList) {
        if (item is Map) {
          detections.add(SubjectDetection.fromMap(item));
        }
      }
    }
    return DetectionFrame(
      imageWidth: (map['imageWidth'] as num?)?.toInt() ?? 0,
      imageHeight: (map['imageHeight'] as num?)?.toInt() ?? 0,
      isMirrored: map['isMirrored'] as bool? ?? false,
      detections: detections,
    );
  }
}
