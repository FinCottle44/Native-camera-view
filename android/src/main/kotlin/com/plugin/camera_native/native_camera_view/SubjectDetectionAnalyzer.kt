package com.plugin.camera_native.native_camera_view

import android.annotation.SuppressLint
import android.util.Log
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.objects.ObjectDetection
import com.google.mlkit.vision.objects.ObjectDetector
import com.google.mlkit.vision.objects.defaults.ObjectDetectorOptions

/**
 * CameraX [ImageAnalysis.Analyzer] that runs ML Kit on-device object detection
 * in stream mode to locate the prominent foreground subject, and reports its
 * bounding box as normalized (0..1) top-left-origin coordinates in the frame's
 * display (upright) orientation.
 *
 * The bundled ML Kit model requires no download. Classification is left off for
 * v1, so [SubjectDetectionAnalyzer] emits a pure foreground/subject box (label
 * and confidence are typically absent). See docs/ml_subject_detection.md for how
 * to enable classification or swap in a car-specific custom model.
 */
class SubjectDetectionAnalyzer(
    private val onResult: (imageWidth: Int, imageHeight: Int, detections: List<Map<String, Any>>) -> Unit
) : ImageAnalysis.Analyzer {

    private val TAG = "SubjectDetectAnalyzer"

    companion object {
        // Drop boxes smaller than this fraction of the frame area (noise/clutter).
        private const val MIN_RELATIVE_AREA = 0.02f
        // When a classifier label is present, ignore low-confidence detections.
        private const val MIN_LABEL_CONFIDENCE = 0.3f
    }

    // STREAM_MODE (single prominent object) gives one stable, tracked subject.
    private val detector: ObjectDetector = run {
        val options = ObjectDetectorOptions.Builder()
            .setDetectorMode(ObjectDetectorOptions.STREAM_MODE)
            .build()
        ObjectDetection.getClient(options)
    }

    @SuppressLint("UnsafeOptInUsageError")
    override fun analyze(imageProxy: ImageProxy) {
        val mediaImage = imageProxy.image
        if (mediaImage == null) {
            imageProxy.close()
            return
        }

        val rotationDegrees = imageProxy.imageInfo.rotationDegrees
        val inputImage = InputImage.fromMediaImage(mediaImage, rotationDegrees)

        // ML Kit returns boxes in the coordinate space of the upright (rotated)
        // image, so swap width/height for 90/270.
        val uprightWidth: Int
        val uprightHeight: Int
        if (rotationDegrees == 90 || rotationDegrees == 270) {
            uprightWidth = imageProxy.height
            uprightHeight = imageProxy.width
        } else {
            uprightWidth = imageProxy.width
            uprightHeight = imageProxy.height
        }

        detector.process(inputImage)
            .addOnSuccessListener { detectedObjects ->
                if (uprightWidth <= 0 || uprightHeight <= 0) return@addOnSuccessListener
                val w = uprightWidth.toFloat()
                val h = uprightHeight.toFloat()
                val frameArea = w * h

                // Keep only the single most prominent subject: the largest box
                // that passes the size (and, if labelled, confidence) filters.
                val primary = detectedObjects
                    .filter { obj ->
                        val box = obj.boundingBox
                        val area = box.width().toFloat() * box.height().toFloat()
                        val relativeArea = if (frameArea > 0f) area / frameArea else 0f
                        val label = obj.labels.firstOrNull()
                        val confidenceOk = label == null || label.confidence >= MIN_LABEL_CONFIDENCE
                        relativeArea >= MIN_RELATIVE_AREA && confidenceOk
                    }
                    .maxByOrNull { it.boundingBox.width().toLong() * it.boundingBox.height().toLong() }

                val results = if (primary == null) {
                    emptyList()
                } else {
                    val box = primary.boundingBox
                    val map = hashMapOf<String, Any>(
                        "left" to (box.left / w).coerceIn(0f, 1f).toDouble(),
                        "top" to (box.top / h).coerceIn(0f, 1f).toDouble(),
                        "right" to (box.right / w).coerceIn(0f, 1f).toDouble(),
                        "bottom" to (box.bottom / h).coerceIn(0f, 1f).toDouble()
                    )
                    primary.trackingId?.let { map["trackingId"] = it }
                    primary.labels.firstOrNull()?.let { label ->
                        map["label"] = label.text
                        map["confidence"] = label.confidence.toDouble()
                    }
                    listOf(map)
                }
                onResult(uprightWidth, uprightHeight, results)
            }
            .addOnFailureListener { e ->
                Log.e(TAG, "Object detection failed: ${e.message}", e)
            }
            .addOnCompleteListener {
                // Must close so CameraX can deliver the next frame.
                imageProxy.close()
            }
    }

    fun close() {
        try {
            detector.close()
        } catch (e: Exception) {
            Log.w(TAG, "Error closing detector: ${e.message}")
        }
    }
}
