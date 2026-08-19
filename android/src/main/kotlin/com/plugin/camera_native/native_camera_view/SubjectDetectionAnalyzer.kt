package com.plugin.camera_native.native_camera_view

import android.content.Context
import android.graphics.Bitmap
import android.graphics.Matrix
import android.graphics.RectF
import android.util.Log
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import com.google.mediapipe.framework.image.BitmapImageBuilder
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.vision.core.RunningMode
import com.google.mediapipe.tasks.vision.objectdetector.ObjectDetector

/**
 * CameraX [ImageAnalysis.Analyzer] that runs MediaPipe Tasks object detection
 * on the bundled EfficientDet-Lite0 model (Apache-2.0, COCO) to locate the car
 * in frame, and reports its bounding box as normalized (0..1) top-left-origin
 * coordinates in the frame's display (upright) orientation.
 *
 * The model only reliably detects a roughly-upright car. The consuming app is
 * portrait-locked but held in landscape-left, so CameraX delivers a portrait
 * display frame in which a real upright car sits rotated 90°. Detection therefore
 * applies a single fixed rotation ([DETECTION_ROTATION_DEGREES]) to the display
 * frame so the car is upright for the model, then maps the winning box back to
 * the display frame — one inference per frame, no rotation search. To support a
 * different holding, change that constant (or search several rotations, at the
 * cost of extra inference while searching).
 *
 * Only the `car` category is kept. When multiple cars are detected, a composite
 * score selects the most prominent one based on:
 *   1. Relative area (larger = more prominent, but not the sole factor).
 *   2. Center proximity (cars closer to frame center are preferred).
 *   3. Detection confidence (higher model confidence = preferred).
 *   4. Tracking continuity / hysteresis (the previously-selected car gets a
 *      bonus so the box doesn't jump between cars frame-to-frame).
 *
 * Detection is advisory only; it never affects image capture.
 */
class SubjectDetectionAnalyzer(
    context: Context,
    private val onResult: (imageWidth: Int, imageHeight: Int, detections: List<Map<String, Any>>) -> Unit
) : ImageAnalysis.Analyzer {

    private val TAG = "SubjectDetectAnalyzer"

    companion object {
        private const val MODEL_ASSET = "efficientdet_lite0.tflite"
        // COCO label for cars in the EfficientDet-Lite label map.
        private const val TARGET_LABEL = "car"
        private const val SCORE_THRESHOLD = 0.4f
        // Drop boxes smaller than this fraction of the frame area (noise).
        private const val MIN_RELATIVE_AREA = 0.02f
        // The app is portrait-locked but held in landscape-left, so a real
        // upright car sits rotated 90° in the portrait display frame. Rotate the
        // display frame clockwise by this much before detection so the car is
        // upright for the model. 270 = landscape-left; use 90 for the mirror
        // (landscape-right), or 0 to detect on the upright frame (portrait).
        private const val DETECTION_ROTATION_DEGREES = 270

        // --- Composite scoring weights ---
        // How much relative area contributes to the score.
        private const val WEIGHT_AREA = 0.35f
        // How much proximity to the frame center contributes.
        private const val WEIGHT_CENTER = 0.30f
        // How much model confidence contributes.
        private const val WEIGHT_CONFIDENCE = 0.15f
        // How much overlap with the previously-selected car contributes
        // (tracking hysteresis to prevent jumping).
        private const val WEIGHT_CONTINUITY = 0.20f
        // IoU threshold above which a detection is considered "the same car" as
        // the previous selection (for continuity bonus).
        private const val CONTINUITY_IOU_THRESHOLD = 0.3f
    }

    private var detector: ObjectDetector? = null

    /** Normalized rect of the previously-selected car (in detection bitmap space). */
    @Volatile
    private var lastSelectedRect: RectF? = null

    init {
        try {
            val baseOptions = BaseOptions.builder()
                .setModelAssetPath(MODEL_ASSET)
                .build()
            val options = ObjectDetector.ObjectDetectorOptions.builder()
                .setBaseOptions(baseOptions)
                .setRunningMode(RunningMode.IMAGE)
                .setScoreThreshold(SCORE_THRESHOLD)
                // No category allowlist — a single-category allowlist crashes the
                // GPU delegate; filter to "car" in code (see selectPrimaryCar).
                .setMaxResults(25)
                .build()
            detector = ObjectDetector.createFromOptions(context, options)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to create ObjectDetector: ${e.message}", e)
        }
    }

    /** A car box normalized (0..1, top-left) to some image's own dimensions. */
    private data class NormalizedDetection(
        val rect: RectF,
        val label: String,
        val confidence: Double
    )

    override fun analyze(imageProxy: ImageProxy) {
        val activeDetector = detector
        if (activeDetector == null) {
            imageProxy.close()
            return
        }
        try {
            // Build the "display" bitmap = the frame upright as the preview shows
            // it (raw sensor buffer rotated by the analysis rotationDegrees).
            val raw = imageProxy.toBitmap()
            val rotationDegrees = imageProxy.imageInfo.rotationDegrees
            // Crop to the use case's crop rect (set by the shared ViewPort in the
            // factory) so the analyzed frame covers exactly the field of view the
            // preview shows. toBitmap() returns the FULL buffer — the crop rect is
            // only metadata — so we apply it here. No-op when the rect already
            // spans the whole buffer (e.g. no ViewPort configured). cropRect is in
            // the raw (unrotated) buffer space, so crop before rotating.
            val visibleBitmap = cropToRect(raw, imageProxy.cropRect)
            val displayBitmap = rotateBitmap(visibleBitmap, rotationDegrees)

            val dispW = displayBitmap.width
            val dispH = displayBitmap.height
            if (dispW <= 0 || dispH <= 0) {
                imageProxy.close()
                return
            }

            // Held in landscape-left, an upright car appears rotated 90° in the
            // portrait display frame. Rotate to upright for the model (single
            // fixed rotation — no search), then map the box back to the display
            // frame so all downstream logic stays in display coordinates.
            val candidate = if (DETECTION_ROTATION_DEGREES % 360 == 0) {
                displayBitmap
            } else {
                rotateBitmap(displayBitmap, DETECTION_ROTATION_DEGREES)
            }
            val found = selectPrimaryCar(activeDetector, candidate)
            val displayDetection = found?.let {
                it.copy(rect = unrotateNormalizedRect(it.rect, DETECTION_ROTATION_DEGREES))
            }

            val results = if (displayDetection == null) {
                emptyList()
            } else {
                val r = displayDetection.rect
                listOf(
                    hashMapOf<String, Any>(
                        "left" to r.left.coerceIn(0f, 1f).toDouble(),
                        "top" to r.top.coerceIn(0f, 1f).toDouble(),
                        "right" to r.right.coerceIn(0f, 1f).toDouble(),
                        "bottom" to r.bottom.coerceIn(0f, 1f).toDouble(),
                        "label" to displayDetection.label,
                        "confidence" to displayDetection.confidence
                    )
                )
            }
            onResult(dispW, dispH, results)
        } catch (e: Exception) {
            Log.e(TAG, "Detection failed: ${e.message}", e)
        } finally {
            // Must close so CameraX can deliver the next frame.
            imageProxy.close()
        }
    }

    /**
     * Runs the detector on one bitmap and selects the most prominent car using a
     * composite score that considers area, center proximity, confidence, and
     * continuity with the previous selection. This prevents the box from jumping
     * to background/parked cars that happen to be large in the frame.
     */
    private fun selectPrimaryCar(detector: ObjectDetector, bitmap: Bitmap): NormalizedDetection? {
        val w = bitmap.width.toFloat()
        val h = bitmap.height.toFloat()
        if (w <= 0f || h <= 0f) return null
        val frameArea = w * h

        val result = detector.detect(BitmapImageBuilder(bitmap).build())
        val candidates = result.detections()
            .filter { det ->
                val box = det.boundingBox()
                val relativeArea = if (frameArea > 0f) (box.width() * box.height()) / frameArea else 0f
                val isCar = det.categories().firstOrNull()?.categoryName() == TARGET_LABEL
                isCar && relativeArea >= MIN_RELATIVE_AREA
            }

        if (candidates.isEmpty()) {
            lastSelectedRect = null
            return null
        }

        // Find the maximum area among candidates for normalization.
        val maxArea = candidates.maxOf { it.boundingBox().width() * it.boundingBox().height() }

        val scored = candidates.map { det ->
            val box = det.boundingBox()
            val area = box.width() * box.height()
            val confidence = det.categories().firstOrNull()?.score()?.toDouble() ?: 0.0

            // Normalize area to 0..1 relative to the largest candidate.
            val areaNorm = if (maxArea > 0f) area / maxArea else 0f

            // Center proximity: 1.0 = dead center, 0.0 = in the corner.
            val centerX = (box.left + box.right) / 2f / w
            val centerY = (box.top + box.bottom) / 2f / h
            // Max possible distance from center is sqrt(0.5² + 0.5²) ≈ 0.707
            val distFromCenter = Math.sqrt(
                ((centerX - 0.5) * (centerX - 0.5) + (centerY - 0.5) * (centerY - 0.5)).toDouble()
            )
            val centerNorm = (1.0 - (distFromCenter / 0.707)).coerceIn(0.0, 1.0)

            // Continuity: how much this detection overlaps with the previously
            // selected car. Full bonus if IoU > threshold, partial otherwise.
            val normalizedRect = RectF(box.left / w, box.top / h, box.right / w, box.bottom / h)
            val continuityNorm = lastSelectedRect?.let { prev ->
                val iou = computeIoU(normalizedRect, prev)
                if (iou >= CONTINUITY_IOU_THRESHOLD) 1.0 else (iou / CONTINUITY_IOU_THRESHOLD).toDouble()
            } ?: 0.0

            // Composite score.
            val score = (WEIGHT_AREA * areaNorm +
                    WEIGHT_CENTER * centerNorm.toFloat() +
                    WEIGHT_CONFIDENCE * confidence.toFloat() +
                    WEIGHT_CONTINUITY * continuityNorm.toFloat()).toDouble()

            Triple(det, normalizedRect, score)
        }

        val (primary, primaryRect, _) = scored.maxByOrNull { it.third } ?: return null

        // Update tracking state for next frame.
        lastSelectedRect = primaryRect

        val category = primary.categories().firstOrNull()
        return NormalizedDetection(
            rect = primaryRect,
            label = category?.categoryName() ?: TARGET_LABEL,
            confidence = category?.score()?.toDouble() ?: 0.0
        )
    }

    /** Computes Intersection-over-Union of two normalized rects. */
    private fun computeIoU(a: RectF, b: RectF): Float {
        val interLeft = maxOf(a.left, b.left)
        val interTop = maxOf(a.top, b.top)
        val interRight = minOf(a.right, b.right)
        val interBottom = minOf(a.bottom, b.bottom)
        val interArea = maxOf(0f, interRight - interLeft) * maxOf(0f, interBottom - interTop)
        if (interArea <= 0f) return 0f
        val aArea = (a.right - a.left) * (a.bottom - a.top)
        val bArea = (b.right - b.left) * (b.bottom - b.top)
        val unionArea = aArea + bArea - interArea
        return if (unionArea > 0f) interArea / unionArea else 0f
    }

    /**
     * Maps a normalized rect detected in a bitmap that was the display frame
     * rotated clockwise by [degrees], back into the display frame's coordinates.
     */
    private fun unrotateNormalizedRect(r: RectF, degrees: Int): RectF {
        return when (degrees % 360) {
            90 -> RectF(r.top, 1f - r.right, r.bottom, 1f - r.left)
            180 -> RectF(1f - r.right, 1f - r.bottom, 1f - r.left, 1f - r.top)
            270 -> RectF(1f - r.bottom, r.left, 1f - r.top, r.right)
            else -> RectF(r) // 0
        }
    }

    /**
     * Crops [bitmap] to [rect] (in the raw, unrotated buffer's coordinate space).
     * Returns the input unchanged when the rect already spans the whole buffer or
     * is unusable, so this is a no-op unless a ViewPort crop rect is in effect.
     */
    private fun cropToRect(bitmap: Bitmap, rect: android.graphics.Rect): Bitmap {
        val left = rect.left.coerceIn(0, bitmap.width)
        val top = rect.top.coerceIn(0, bitmap.height)
        val right = rect.right.coerceIn(left, bitmap.width)
        val bottom = rect.bottom.coerceIn(top, bitmap.height)
        val w = right - left
        val h = bottom - top
        if (w <= 0 || h <= 0) return bitmap
        if (left == 0 && top == 0 && w == bitmap.width && h == bitmap.height) return bitmap
        return Bitmap.createBitmap(bitmap, left, top, w, h)
    }

    private fun rotateBitmap(bitmap: Bitmap, degrees: Int): Bitmap {
        if (degrees % 360 == 0) return bitmap
        val matrix = Matrix().apply { postRotate(degrees.toFloat()) }
        return Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
    }

    fun close() {
        try {
            detector?.close()
        } catch (e: Exception) {
            Log.w(TAG, "Error closing detector: ${e.message}")
        }
        detector = null
    }
}
