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
 * The model only reliably detects a roughly-upright car. Because the app can be
 * held in any physical orientation (while the preview stays put), detection is
 * rotation-tolerant: the display frame is tried as-is, then rotated 90/180/270
 * until a car is found, and the box is mapped back to the display frame. The
 * last winning rotation is tried first so steady-state is a single inference.
 *
 * Only the `car` category is kept, and only the single most prominent (largest)
 * car is emitted. Detection is advisory only; it never affects image capture.
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
        // Rotations (degrees, clockwise) tried until a car is found.
        private val ROTATION_CANDIDATES = intArrayOf(0, 90, 180, 270)
    }

    private var detector: ObjectDetector? = null
    private var lastSuccessfulRotationIndex = 0

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
                // GPU delegate; filter to "car" in code (see detectLargestCar).
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
            val displayBitmap = rotateBitmap(raw, rotationDegrees)

            val dispW = displayBitmap.width
            val dispH = displayBitmap.height
            if (dispW <= 0 || dispH <= 0) {
                imageProxy.close()
                return
            }

            // Try candidate rotations (last winner first) until a car is found.
            val order = buildList {
                add(lastSuccessfulRotationIndex)
                for (i in ROTATION_CANDIDATES.indices) if (i != lastSuccessfulRotationIndex) add(i)
            }

            var displayDetection: NormalizedDetection? = null
            for (idx in order) {
                val degrees = ROTATION_CANDIDATES[idx]
                val candidate = if (degrees == 0) displayBitmap else rotateBitmap(displayBitmap, degrees)
                val found = detectLargestCar(activeDetector, candidate)
                if (found != null) {
                    // Map the box from the rotated frame back to the display frame.
                    val displayRect = unrotateNormalizedRect(found.rect, degrees)
                    displayDetection = found.copy(rect = displayRect)
                    lastSuccessfulRotationIndex = idx
                    break
                }
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

    /** Runs the detector on one bitmap; returns the largest car normalized to it. */
    private fun detectLargestCar(detector: ObjectDetector, bitmap: Bitmap): NormalizedDetection? {
        val w = bitmap.width.toFloat()
        val h = bitmap.height.toFloat()
        if (w <= 0f || h <= 0f) return null
        val frameArea = w * h

        val result = detector.detect(BitmapImageBuilder(bitmap).build())
        val primary = result.detections()
            .filter { det ->
                val box = det.boundingBox()
                val relativeArea = if (frameArea > 0f) (box.width() * box.height()) / frameArea else 0f
                val isCar = det.categories().firstOrNull()?.categoryName() == TARGET_LABEL
                isCar && relativeArea >= MIN_RELATIVE_AREA
            }
            .maxByOrNull { it.boundingBox().width() * it.boundingBox().height() }
            ?: return null

        val box = primary.boundingBox()
        val category = primary.categories().firstOrNull()
        return NormalizedDetection(
            rect = RectF(box.left / w, box.top / h, box.right / w, box.bottom / h),
            label = category?.categoryName() ?: TARGET_LABEL,
            confidence = category?.score()?.toDouble() ?: 0.0
        )
    }

    /**
     * Maps a normalized rect detected in a bitmap that was the display frame
     * rotated clockwise by [degrees], back into the display frame's coordinates.
     */
    private fun unrotateNormalizedRect(r: RectF, degrees: Int): RectF {
        return when (degrees) {
            90 -> RectF(r.top, 1f - r.right, r.bottom, 1f - r.left)
            180 -> RectF(1f - r.right, 1f - r.bottom, 1f - r.left, 1f - r.top)
            270 -> RectF(1f - r.bottom, r.left, 1f - r.top, r.right)
            else -> RectF(r) // 0
        }
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
