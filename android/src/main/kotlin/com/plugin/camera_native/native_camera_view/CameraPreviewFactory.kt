// File: android/app/src/main/kotlin/com/plugin/camera_native/native_camera_view/CameraPreviewFactory.kt
package com.plugin.camera_native.native_camera_view // Updated package name
import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.ContextWrapper
import android.content.Intent
import android.app.Activity
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Settings
import android.util.Log
import android.view.MotionEvent
import android.view.View
import androidx.annotation.NonNull
import androidx.core.app.ActivityCompat
import androidx.appcompat.app.AlertDialog
import androidx.camera.core.*
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import com.google.common.util.concurrent.ListenableFuture
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import java.io.File
import java.io.FileOutputStream
import java.text.SimpleDateFormat
import java.util.*
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import android.graphics.PixelFormat
import android.view.Surface
import android.view.SurfaceView
import android.util.Size

class CameraPreviewFactory(
    private val binaryMessenger: BinaryMessenger,
    private val lifecycleOwner: LifecycleOwner
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {

    override fun create(context: Context?, viewId: Int, args: Any?): PlatformView {
        val creationParams = args as? Map<String?, Any?>
        requireNotNull(context) { "Context cannot be null when creating CameraPlatformView" }
        return CameraPlatformView(context, binaryMessenger, viewId, lifecycleOwner, creationParams)
    }
}

class CameraPlatformView(
    private val context: Context,
    private val binaryMessenger: BinaryMessenger,
    private val viewId: Int,
    private val lifecycleOwner: LifecycleOwner,
    private val creationParams: Map<String?, Any?>?
) : PlatformView, DefaultLifecycleObserver, LifecycleOwner by lifecycleOwner {

    private lateinit var previewView: PreviewView
    private lateinit var cameraExecutor: ExecutorService
    private var cameraProvider: ProcessCameraProvider? = null
    private var camera: Camera? = null
    private var imageCapture: ImageCapture? = null
    private var previewUseCase: Preview? = null
    private var imageAnalysisUseCase: ImageAnalysis? = null
    private var detectionAnalyzer: SubjectDetectionAnalyzer? = null
    private lateinit var analysisExecutor: ExecutorService
    private var detectionEnabled: Boolean = false
    private var groundGuideMinFraction: Float = 0.15f
    private var groundGuideEdge: String = "bottom" // bottom | top | left | right
    private lateinit var eventChannel: EventChannel
    private var detectionEventSink: EventChannel.EventSink? = null
    private val mainHandler = android.os.Handler(android.os.Looper.getMainLooper())
    private lateinit var methodChannel: MethodChannel
    private var isCameraPausedManually = false
    private var currentLensFacing: Int = CameraSelector.LENS_FACING_BACK

    private val TAG = "CameraPlatformView"
    // --- Diagnostics (NCVDIAG): trace the preview lifecycle to catch the
    // intermittent blank-preview issue. Filter logcat by "NCVDIAG".
    private val diagCreatedAtMs = System.currentTimeMillis()
    private var cameraReadySent = false
    private val FILENAME_FORMAT = "yyyy-MM-dd-HH-mm-ss-SSS"
    private var currentPreviewFitStr: String = "cover"

    private var currentPreviewPresetStr: String? = null
    private var currentCapturePresetStr: String? = null
    private var currentCaptureModeStr: String = "minimizeLatency"
    private var currentTargetRotation: Int = Surface.ROTATION_0

    // Flag to avoid showing multiple dialogs at the same time
    private var isDialogShowing = false
    private var hasRequestedPermission = false
    private var bypassPermissionCheck: Boolean = false

    private var isCameraInitialized = false
    private var lastPermissionRequestTime: Long = 0
    companion object {
        private const val REQUEST_CODE_PERMISSIONS = 10
    }

    /** One tagged, elapsed-timestamped diagnostic line. Filter logcat: NCVDIAG. */
    private fun diag(area: String, message: String) {
        Log.d("NCVDIAG", "+${System.currentTimeMillis() - diagCreatedAtMs}ms [android view $viewId] [$area] $message")
    }

    /**
     * Logs loudly while the camera has not reported ready, so an intermittent
     * blank preview that never recovers leaves a trail. Cancels itself once
     * [cameraReadySent] flips true.
     */
    private fun scheduleReadyWatchdog() {
        cameraReadySent = false
        for (sec in intArrayOf(4, 8, 15)) {
            mainHandler.postDelayed({
                if (cameraReadySent) return@postDelayed
                diag("watchdog",
                    "camera STILL not ready after ${sec}s — previewView=${previewView.width}x${previewView.height}, " +
                        "initialized=$isCameraInitialized, provider=${cameraProvider != null}, paused=$isCameraPausedManually. " +
                        "This is the blank-preview state.")
            }, sec * 1000L)
        }
    }

    init {
        previewView = PreviewView(context)
        previewView.post {
            val surfaceView = previewView.getChildAt(0) as? SurfaceView
            if (surfaceView != null) {
                surfaceView.holder.setFormat(PixelFormat.TRANSPARENT)
                surfaceView.setZOrderMediaOverlay(true)
                Log.d(TAG, "SurfaceView settings applied for viewId $viewId.")
                diag("surface", "SurfaceView found; applied TRANSPARENT + ZOrderMediaOverlay (child0=${previewView.getChildAt(0)?.javaClass?.simpleName})")
            } else {
                Log.e(TAG, "Could not find SurfaceView inside PreviewView for viewId $viewId.")
                diag("surface", "WARNING no SurfaceView child (child0=${previewView.getChildAt(0)?.javaClass?.simpleName}) — preview may render incorrectly")
            }
        }

        lifecycleOwner.lifecycle.addObserver(this) // Register the observer

        val useFrontInitially = creationParams?.get("isFrontCamera") as? Boolean ?: false
        currentLensFacing = if (useFrontInitially) CameraSelector.LENS_FACING_FRONT else CameraSelector.LENS_FACING_BACK
        bypassPermissionCheck = creationParams?.get("bypassPermissionCheck") as? Boolean ?: false

        currentPreviewFitStr = (creationParams?.get("cameraPreviewFit") as? String)?.lowercase(Locale.getDefault()) ?: "cover"

        currentPreviewPresetStr = creationParams?.get("previewPreset") as? String
        currentCapturePresetStr = creationParams?.get("capturePreset") as? String
        currentCaptureModeStr = (creationParams?.get("captureMode") as? String) ?: "minimizeLatency" // Defaults to minimizeLatency

        Log.d(TAG, "Initial lens facing for viewId $viewId: ${if (currentLensFacing == CameraSelector.LENS_FACING_FRONT) "FRONT" else "BACK"}")
        Log.d(TAG, "Initial settings for viewId $viewId: " +
                "previewPreset=$currentPreviewPresetStr, " +
                "capturePreset=$currentCapturePresetStr, " +
                "captureMode=$currentCaptureModeStr")

        applyPreviewFit() // Pass creationParams

        detectionEnabled = creationParams?.get("enableDetection") as? Boolean ?: false
        groundGuideMinFraction = (creationParams?.get("groundGuideMinFraction") as? Double)?.toFloat() ?: 0.15f
        groundGuideEdge = (creationParams?.get("groundGuideEdge") as? String) ?: "bottom"

        //COMPATIBLE PERFORMANCE
        previewView.implementationMode = PreviewView.ImplementationMode.COMPATIBLE
        cameraExecutor = Executors.newSingleThreadExecutor()
        analysisExecutor = Executors.newSingleThreadExecutor()

        val channelName = "com.plugin.camera_native.native_camera_view/camera_method_channel_$viewId"
        methodChannel = MethodChannel(binaryMessenger, channelName)
        methodChannel.setMethodCallHandler { call, result ->
            handleMethodCall(call, result)
        }

        val eventChannelName = "com.plugin.camera_native.native_camera_view/camera_detections_$viewId"
        eventChannel = EventChannel(binaryMessenger, eventChannelName)
        eventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                detectionEventSink = events
                Log.d(TAG, "Detection EventChannel listener attached for viewId $viewId.")
            }

            override fun onCancel(arguments: Any?) {
                detectionEventSink = null
                Log.d(TAG, "Detection EventChannel listener cancelled for viewId $viewId.")
            }
        })

        setupTapToFocus()

        diag("init", "created (lens=${if (currentLensFacing == CameraSelector.LENS_FACING_FRONT) "front" else "back"}, " +
            "fit=$currentPreviewFitStr, detection=$detectionEnabled, bypassPerm=$bypassPermissionCheck)")
        // A zero-size PreviewView is a direct cause of a blank preview; log size changes.
        previewView.addOnLayoutChangeListener { _, l, t, r, b, ol, ot, or_, ob ->
            val nw = r - l; val nh = b - t
            val ow = or_ - ol; val oh = ob - ot
            if (nw != ow || nh != oh) {
                diag("layout", "previewView size ${nw}x$nh" +
                    if (nw == 0 || nh == 0) " — WARNING zero-size (blank preview)" else "")
            }
        }
    }

    override fun onResume(owner: LifecycleOwner) {
        super.onResume(owner)
        diag("lifecycle", "onResume (dialogShowing=$isDialogShowing, initialized=$isCameraInitialized, paused=$isCameraPausedManually)")
        // If our dialog is currently showing, do nothing
        if (isDialogShowing) return

        // Check permissions
        checkPermissionsAndSetup()
    }

    override fun onPause(owner: LifecycleOwner) {
        super.onPause(owner)
        diag("lifecycle", "onPause")
    }

    private fun findActivity(): Activity? {
        var currentContext = context
        while (currentContext is ContextWrapper) {
            if (currentContext is Activity) {
                return currentContext
            }
            currentContext = currentContext.baseContext
        }
        return null
    }

    // Fully updated permission-checking logic
    private fun checkPermissionsAndSetup() {
        val granted = ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
        diag("perm", "check: granted=$granted, bypass=$bypassPermissionCheck, initialized=$isCameraInitialized")
        if (bypassPermissionCheck) {
            setupCamera()
            return
        }

        if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
            if (!isCameraInitialized) {
                Log.d(TAG, "Permission granted. Setting up camera.")
                setupCamera()
            }
            return
        }

        val activity = findActivity()
        if (activity == null) return

        isCameraInitialized = false

        if (System.currentTimeMillis() - lastPermissionRequestTime < 2000) {
            Log.d(TAG, "Request pending or too fast. Ignoring onResume check.")
            return
        }

        val shouldShowRationale = ActivityCompat.shouldShowRequestPermissionRationale(activity, Manifest.permission.CAMERA)

        if (hasRequestedPermission && !shouldShowRationale) {
            Log.d(TAG, "Permission permanently denied. Showing settings dialog.")

            val errorDetails = mapOf("message" to "Camera permission denied permanently.")
            methodChannel.invokeMethod("onCameraError", errorDetails)

            showPermissionDeniedDialog()
            return
        }

        hasRequestedPermission = true
        lastPermissionRequestTime = System.currentTimeMillis() // Update the throttle timestamp

        Log.d(TAG, "Requesting camera permission...")
        ActivityCompat.requestPermissions(
            activity,
            arrayOf(Manifest.permission.CAMERA),
            REQUEST_CODE_PERMISSIONS
        )
    }

    // New function to show a dialog when permission is missing
    private fun showPermissionDeniedDialog() {
        if (isDialogShowing) return
        isDialogShowing = true

        AlertDialog.Builder(context, R.style.RoundedAlertDialog)
            .setTitle(context.getString(R.string.permission_denied_title))
            .setMessage(context.getString(R.string.permission_denied_message))
            .setCancelable(false)
            .setPositiveButton(context.getString(R.string.open_settings_button)) { _, _ ->
                val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                val uri = Uri.fromParts("package", context.packageName, null)
                intent.data = uri
                context.startActivity(intent)
                isDialogShowing = false
            }
            .setNegativeButton(context.getString(R.string.close_button)) { _, _ ->
                isDialogShowing = false
            }
            .show()
    }


    private fun handleMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "initialize" -> {
                Log.d(TAG, "Initialization requested from Flutter for viewId $viewId.")
                diag("method", "initialize requested")
                scheduleReadyWatchdog()
                checkPermissionsAndSetup()
                result.success(null)
            }
            "captureImage" -> takePhoto(result)
            "pauseCamera" -> pauseCameraNative(result)
            "resumeCamera" -> resumeCameraNative(result)
            "switchCamera" -> {
                val args = call.arguments as? Map<String, Any>
                val useFront = args?.get("useFrontCamera") as? Boolean ?: false
                switchCameraNative(useFront, result)
            }
            "deleteAllCapturedPhotos" -> deleteAllPhotosNative(result)
            "setPreviewFit" -> { // Handle fit mode changes from Flutter
                val fitName = call.arguments as? String
                if (fitName != null) {
                    currentPreviewFitStr = fitName.lowercase(Locale.getDefault())
                    applyPreviewFit() // Apply immediately
                    result.success(null)
                } else {
                    result.error("INVALID_ARGUMENT", "Missing 'fitName'", null)
                }
            }
            "setTargetRotation" -> {
                val args = call.arguments as? Map<String, Any>
                val rotation = (args?.get("rotation") as? Int) ?: 0
                setTargetRotationNative(rotation, result)
            }
            "setZoom" -> {
                val args = call.arguments as? Map<String, Any>
                val zoom = (args?.get("zoom") as? Double)?.toFloat() ?: 1.0f
                setZoomNative(zoom, result)
            }
            "getMaxZoom" -> getMaxZoomNative(result)
            "getMinZoom" -> getMinZoomNative(result)
            "setDetectionEnabled" -> {
                val enabled = call.arguments as? Boolean ?: false
                setDetectionEnabledNative(enabled, result)
            }
            else -> result.notImplemented()
        }
    }

    @SuppressLint("ClickableViewAccessibility")
    private fun setupTapToFocus() {
        previewView.setOnTouchListener { _, event ->
            if (event.action == MotionEvent.ACTION_UP) {
                if (camera == null) {
                    Log.w(TAG, "Camera object is null, cannot perform tap-to-focus.")
                    return@setOnTouchListener true
                }
                val factory: MeteringPointFactory = previewView.meteringPointFactory
                val point: MeteringPoint = factory.createPoint(event.x, event.y)
                val action: FocusMeteringAction = FocusMeteringAction.Builder(point, FocusMeteringAction.FLAG_AF)
                    .setAutoCancelDuration(5, TimeUnit.SECONDS)
                    .build()
                Log.d(TAG, "Attempting tap-to-focus at: (${event.x}, ${event.y})")
                val focusFuture: ListenableFuture<FocusMeteringResult> = camera!!.cameraControl.startFocusAndMetering(action)
                focusFuture.addListener({
                    try {
                        val focusResult = focusFuture.get()
                        if (focusResult.isFocusSuccessful) {
                            Log.d(TAG, "Tap-to-focus successful.")
                        } else {
                            Log.w(TAG, "Tap-to-focus failed.")
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "Error observing tap-to-focus result: ${e.message}", e)
                    }
                }, ContextCompat.getMainExecutor(context))
            }
            true
        }
    }

    private fun applyPreviewFit() {
        Log.d(TAG, "Applying cameraPreviewFit for viewId $viewId: $currentPreviewFitStr")
        previewView.scaleType = when (currentPreviewFitStr) {
            "fitwidth" -> PreviewView.ScaleType.FILL_START
            "fitheight" -> PreviewView.ScaleType.FILL_END
            "contain" -> PreviewView.ScaleType.FIT_START // Or FIT_CENTER if you want it centered
            "cover" -> PreviewView.ScaleType.FILL_CENTER
            else -> {
                Log.w(TAG, "Unknown cameraPreviewFit value: '$currentPreviewFitStr'. Defaulting to FILL_CENTER.")
                PreviewView.ScaleType.FILL_CENTER
            }
        }
    }

    private fun setupCamera() {
        diag("setup", "requesting ProcessCameraProvider")
        val cameraProviderFuture = ProcessCameraProvider.getInstance(context)
        cameraProviderFuture.addListener({
            try {
                cameraProvider = cameraProviderFuture.get()
                diag("setup", "provider obtained (paused=$isCameraPausedManually)")
                if (!isCameraPausedManually) {
                    bindCameraUseCases(cameraProvider!!)
                } else {
                    Log.d(TAG, "Camera for viewId $viewId is manually paused, not binding use cases on setup.")
                    diag("setup", "paused — not binding use cases")
                }
            } catch (e: Exception) {
                Log.e(TAG, "Failed to get ProcessCameraProvider for viewId $viewId: ${e.message}", e)
                diag("setup", "FAILED to get provider: ${e.message}")
            }
        }, ContextCompat.getMainExecutor(context))
    }

    private fun getTargetResolution(preset: String?): Size? {
        return when (preset) {
            "low" -> Size(640, 480)    // SD
            "medium" -> Size(1280, 720)   // HD
            "high" -> Size(1920, 1080)  // FHD
            "max" -> null // Let CameraX choose the highest resolution
            else -> null // Default (not set)
        }
    }

    // Get the CaptureMode from a string
    private fun getCaptureMode(mode: String): Int {
        return when (mode) {
            "maximizeQuality" -> ImageCapture.CAPTURE_MODE_MAXIMIZE_QUALITY
            "minimizeLatency" -> ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY
            else -> ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY
        }
    }

    private fun bindCameraUseCases(cameraProvider: ProcessCameraProvider) {
        diag("bind", "begin (previewView=${previewView.width}x${previewView.height}, paused=$isCameraPausedManually, detection=$detectionEnabled)")
        applyPreviewFit()
        cameraProvider.unbindAll()

        val previewBuilder = Preview.Builder()
        getTargetResolution(currentPreviewPresetStr)?.let {
            previewBuilder.setTargetResolution(it)
            Log.d(TAG, "Setting PREVIEW resolution to $it for viewId $viewId")
        }
        previewUseCase = previewBuilder.build().also {
            it.setSurfaceProvider(previewView.surfaceProvider)
        }

        //Apply the CaptureMode and resolution settings to ImageCapture
        val imageCaptureBuilder = ImageCapture.Builder()

        // 1. Set Capture Mode
        val captureMode = getCaptureMode(currentCaptureModeStr)
        imageCaptureBuilder.setCaptureMode(captureMode)
        Log.d(TAG, "Setting CAPTURE MODE to $currentCaptureModeStr ($captureMode) for viewId $viewId")

        // 2. Set Capture Resolution
        getTargetResolution(currentCapturePresetStr)?.let {
            imageCaptureBuilder.setTargetResolution(it)
            Log.d(TAG, "Setting CAPTURE resolution to $it for viewId $viewId")
        }

        imageCaptureBuilder.setTargetRotation(currentTargetRotation)
        imageCapture = imageCaptureBuilder.build()

        // Live subject-detection use case (opt-in, skipped while paused).
        imageAnalysisUseCase = null
        detectionAnalyzer?.close()
        detectionAnalyzer = null
        if (detectionEnabled && !isCameraPausedManually) {
            val analyzer = SubjectDetectionAnalyzer(context) { imageWidth, imageHeight, detections ->
                val isFront = currentLensFacing == CameraSelector.LENS_FACING_FRONT
                mainHandler.post {
                    // Compute the cropped state against the actual preview bounds
                    // (FILL_CENTER cover), matching what the user sees. Sides are
                    // in the fixed portrait display frame (see CropSide in Dart).
                    val sides = if (detections.isEmpty()) {
                        emptyList()
                    } else {
                        croppedSides(detections[0], imageWidth, imageHeight, isFront)
                    }
                    val hasEnoughGround = if (detections.isEmpty()) {
                        true
                    } else {
                        hasEnoughGroundBelow(detections[0], imageWidth, imageHeight, isFront)
                    }
                    val payload = mapOf(
                        "imageWidth" to imageWidth,
                        "imageHeight" to imageHeight,
                        // Analysis frames are NOT mirrored, but the preview mirrors
                        // the front camera, so the Dart side must flip X to match.
                        "isMirrored" to isFront,
                        "detections" to detections,
                        "isDetected" to detections.isNotEmpty(),
                        "isCropped" to sides.isNotEmpty(),
                        "croppedSides" to sides,
                        "hasEnoughGround" to hasEnoughGround
                    )
                    detectionEventSink?.success(payload)
                }
            }
            detectionAnalyzer = analyzer
            val analysis = ImageAnalysis.Builder()
                .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_RGBA_8888)
                .build()
            analysis.setAnalyzer(analysisExecutor, analyzer)
            imageAnalysisUseCase = analysis
            Log.d(TAG, "Subject detection ImageAnalysis enabled for viewId $viewId")
        }

        val cameraSelector = CameraSelector.Builder()
            .requireLensFacing(currentLensFacing)
            .build()

        try {
            val useCasesToBind = mutableListOf<UseCase>()
            if (!isCameraPausedManually) {
                previewUseCase?.let { useCasesToBind.add(it) }
            }
            imageCapture?.let { useCasesToBind.add(it) }
            imageAnalysisUseCase?.let { useCasesToBind.add(it) }

            if (useCasesToBind.isEmpty()) {
                Log.w(TAG, "No use cases to bind for viewId $viewId.")
            } else {
                // Bind through a UseCaseGroup with a shared ViewPort so Preview,
                // ImageAnalysis and ImageCapture map to the SAME sensor region
                // (WYSIWYG). Without it, CameraX can hand the analyzer a different
                // resolution/aspect — and thus a different field of view — than the
                // preview shows, so detection boxes (normalized to the analysis
                // frame) render consistently smaller/misaligned and the ground
                // thresholds skew ("zoomed in"). The ViewPort is taken from the
                // PreviewView (FILL_CENTER = "cover") and the analyzer honours the
                // resulting crop rect. Falls back to plain binding if the view
                // isn't laid out yet (viewPort == null).
                val groupBuilder = UseCaseGroup.Builder()
                previewView.viewPort?.let { groupBuilder.setViewPort(it) }
                useCasesToBind.forEach { groupBuilder.addUseCase(it) }
                this.camera = cameraProvider.bindToLifecycle(
                    this,
                    cameraSelector,
                    groupBuilder.build()
                )
            }
            Log.d(TAG, "Camera use cases bound for viewId $viewId. Paused: $isCameraPausedManually")
            cameraReadySent = true
            diag("ready", "bound OK, sending onCameraReady (camera=${camera != null}, previewView=${previewView.width}x${previewView.height})")
            isCameraInitialized = true
            methodChannel.invokeMethod("onCameraReady", null)
        } catch (exc: Exception) {
            Log.e(TAG, "Failed to bind camera use cases for viewId $viewId: ${exc.message}", exc)
            diag("bind", "FAILED: ${exc.message} — sending onCameraError")
            this.camera = null
            isCameraInitialized = false

            val errorDetails = mapOf("message" to (exc.message ?: "Failed to bind use cases. Resolution may not be supported."))
            methodChannel.invokeMethod("onCameraError", errorDetails)
        }
    }

    private fun pauseCameraNative(result: MethodChannel.Result) {
        Log.d(TAG, "Pausing camera for viewId $viewId (only unbinding preview)")
        diag("method", "pauseCamera")
        isCameraPausedManually = true
        try {
            previewUseCase?.let { currentPreviewUseCase ->
                if (cameraProvider?.isBound(currentPreviewUseCase) == true) {
                    cameraProvider?.unbind(currentPreviewUseCase)
                    Log.d(TAG, "Unbound PreviewUseCase for viewId $viewId.")
                } else {
                    Log.d(TAG, "PreviewUseCase not bound or provider null for viewId $viewId.")
                }
            }
            result.success(null)
        } catch (e: Exception) {
            Log.e(TAG, "Error during pauseCameraNative for viewId $viewId: ${e.message}", e)
            result.error("PAUSE_FAILED", "Failed to pause camera: ${e.message}", null)
        }
    }

    private fun resumeCameraNative(result: MethodChannel.Result) {
        Log.d(TAG, "Resuming camera for viewId $viewId")
        diag("method", "resumeCamera")
        scheduleReadyWatchdog()
        isCameraPausedManually = false
        if (cameraProvider != null) {
            bindCameraUseCases(cameraProvider!!)
        } else {
            Log.w(TAG, "CameraProvider not available yet for viewId $viewId on resume.")
            diag("method", "resume: provider not ready yet")
        }
        result.success(null)
    }
    // Whether the detected car touches the visible preview edge (cropped),
    // computed against the PreviewView with FILL_CENTER (cover) — matching what
    // the user sees. Assumes cover fit (the app's usage).
    // Whether there's enough ground beyond the car toward the configured edge
    // (gap >= groundGuideMinFraction of the relevant preview dimension). Mapped
    // through FILL_CENTER cover, matching what the user sees.
    private fun hasEnoughGroundBelow(
        box: Map<String, Any>,
        imageWidth: Int,
        imageHeight: Int,
        isFront: Boolean
    ): Boolean {
        val vw = previewView.width.toFloat()
        val vh = previewView.height.toFloat()
        if (vw <= 0f || vh <= 0f || imageWidth <= 0 || imageHeight <= 0) return true

        var l = (box["left"] as? Double)?.toFloat() ?: return true
        val t = (box["top"] as? Double)?.toFloat() ?: return true
        var r = (box["right"] as? Double)?.toFloat() ?: return true
        val b = (box["bottom"] as? Double)?.toFloat() ?: return true
        // Front preview is mirrored; flip X so left/right match what's shown.
        if (isFront) {
            val nl = 1f - r
            val nr = 1f - l
            l = nl
            r = nr
        }

        val imgW = imageWidth.toFloat()
        val imgH = imageHeight.toFloat()
        val scale = maxOf(vw / imgW, vh / imgH) // cover
        val dispW = imgW * scale
        val dispH = imgH * scale
        val offX = (vw - dispW) / 2f
        val offY = (vh - dispH) / 2f

        val boxLeft = l * dispW + offX
        val boxTop = t * dispH + offY
        val boxRight = r * dispW + offX
        val boxBottom = b * dispH + offY

        val gap: Float
        val dim: Float
        when (groundGuideEdge) {
            "top" -> { gap = boxTop; dim = vh }
            "left" -> { gap = boxLeft; dim = vw }
            "right" -> { gap = vw - boxRight; dim = vw }
            else -> { gap = vh - boxBottom; dim = vh } // bottom
        }
        return dim > 0f && (gap / dim) >= groundGuideMinFraction
    }

    // Which visible preview edges the detected car touches (cropped), computed
    // against the PreviewView with FILL_CENTER (cover) — matching what the user
    // sees. Sides are in the fixed portrait display frame: "left"/"right" are
    // the frame's short edges and "top"/"bottom" its long-side edges, regardless
    // of how the phone is held (see CropSide in Dart). Assumes cover fit.
    // Empty list == not cropped.
    private fun croppedSides(
        box: Map<String, Any>,
        imageWidth: Int,
        imageHeight: Int,
        isFront: Boolean
    ): List<String> {
        val vw = previewView.width.toFloat()
        val vh = previewView.height.toFloat()
        if (vw <= 0f || vh <= 0f || imageWidth <= 0 || imageHeight <= 0) return emptyList()

        var l = (box["left"] as? Double)?.toFloat() ?: return emptyList()
        val t = (box["top"] as? Double)?.toFloat() ?: return emptyList()
        var r = (box["right"] as? Double)?.toFloat() ?: return emptyList()
        val b = (box["bottom"] as? Double)?.toFloat() ?: return emptyList()

        // Front preview is mirrored; flip X so left/right match what's shown.
        if (isFront) {
            val nl = 1f - r
            val nr = 1f - l
            l = nl
            r = nr
        }

        val imgW = imageWidth.toFloat()
        val imgH = imageHeight.toFloat()
        val scale = maxOf(vw / imgW, vh / imgH) // cover
        val dispW = imgW * scale
        val dispH = imgH * scale
        val offX = (vw - dispW) / 2f
        val offY = (vh - dispH) / 2f

        val left = l * dispW + offX
        val top = t * dispH + offY
        val right = r * dispW + offX
        val bottom = b * dispH + offY

        val margin = minOf(vw, vh) * 0.02f
        val sides = mutableListOf<String>()
        if (left <= margin) sides.add("left")
        if (top <= margin) sides.add("top")
        if (right >= vw - margin) sides.add("right")
        if (bottom >= vh - margin) sides.add("bottom")
        return sides
    }

    private fun setDetectionEnabledNative(enabled: Boolean, result: MethodChannel.Result) {
        Log.d(TAG, "setDetectionEnabled($enabled) for viewId $viewId")
        if (detectionEnabled == enabled) {
            result.success(null)
            return
        }
        detectionEnabled = enabled
        // Rebind so the ImageAnalysis use case is added/removed.
        if (cameraProvider != null && !isCameraPausedManually) {
            bindCameraUseCases(cameraProvider!!)
        }
        result.success(null)
    }

    private fun switchCameraNative(useFront: Boolean, flutterResult: MethodChannel.Result) {
        val newLensFacing = if (useFront) CameraSelector.LENS_FACING_FRONT else CameraSelector.LENS_FACING_BACK

        val isCurrentlyBound = previewUseCase?.let { cameraProvider?.isBound(it) } ?: false

        if (newLensFacing == currentLensFacing && isCurrentlyBound && !isCameraPausedManually) {
            Log.d(TAG, "Camera for viewId $viewId is already using the requested lens and is active: ${if (useFront) "FRONT" else "BACK"}")
            flutterResult.success(null)
            return
        }

        currentLensFacing = newLensFacing
        Log.d(TAG, "Switching camera for viewId $viewId to: ${if (useFront) "FRONT" else "BACK"}")

        if (cameraProvider != null) {
            if (!isCameraPausedManually) {
                bindCameraUseCases(cameraProvider!!)
            } else {
                Log.d(TAG, "Camera for viewId $viewId is manually paused. Lens selection will apply on resume.")
            }
            flutterResult.success(null)
        } else {
            Log.e(TAG, "CameraProvider not available to switch camera for viewId $viewId.")
            flutterResult.error("PROVIDER_UNAVAILABLE", "CameraProvider not available to switch camera.", null)
        }
    }

    private fun takePhoto(flutterResult: MethodChannel.Result) {
        val imageCaptureInstance = this.imageCapture
        if (imageCaptureInstance == null) {
            Log.e(TAG, "ImageCapture not initialized for viewId $viewId.")
            flutterResult.error("UNINITIALIZED", "ImageCapture not initialized.", null)
            return
        }

        // Create a temp file to store the original (uncropped) photo
        val originalPhotoFile = File(context.cacheDir, "original_${SimpleDateFormat(FILENAME_FORMAT, Locale.US).format(System.currentTimeMillis())}.jpg")
        val outputOptions = ImageCapture.OutputFileOptions.Builder(originalPhotoFile).build()

        imageCaptureInstance.takePicture(outputOptions, ContextCompat.getMainExecutor(context), object : ImageCapture.OnImageSavedCallback {
            override fun onImageSaved(@NonNull outputFileResults: ImageCapture.OutputFileResults) {
                val savedUri = outputFileResults.savedUri ?: Uri.fromFile(originalPhotoFile)
                val originalFilePath = originalPhotoFile.absolutePath
                Log.d(TAG, "Photo capture saved to: $savedUri, path: $originalFilePath")

                if (currentPreviewFitStr == "cover") {
                    Log.d(TAG, "Cover mode detected. Attempting to crop photo for viewId $viewId.")
                    try {
                        val croppedFilePath = cropPhotoToMatchPreview(originalFilePath, previewView)
                        if (croppedFilePath != null) {
                            Log.d(TAG, "Photo cropped successfully: $croppedFilePath")
                            originalPhotoFile.delete() // Delete the original file if cropping succeeded
                            flutterResult.success(croppedFilePath)
                        } else {
                            Log.e(TAG, "Photo cropping failed. Returning original photo for viewId $viewId.")
                            flutterResult.success(originalFilePath) // Return the original photo if cropping fails
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "Exception during cropping for viewId $viewId: ${e.message}", e)
                        flutterResult.success(originalFilePath) // Return the original photo if an exception occurs
                    }
                } else {
                    Log.d(TAG, "Not in cover mode. Returning original photo for viewId $viewId.")
                    flutterResult.success(originalFilePath)
                }
            }

            override fun onError(@NonNull exception: ImageCaptureException) {
                Log.e(TAG, "Photo capture failed for viewId $viewId: ${exception.message}", exception)
                flutterResult.error("CAPTURE_FAILED", "Photo capture failed: ${exception.message}", exception.toString())
            }
        })
    }

    // NEW FUNCTION TO CROP THE PHOTO
    private fun cropPhotoToMatchPreview(originalPhotoPath: String, previewView: PreviewView): String? {
        try {
            // 1. Get the original Bitmap and handle orientation from EXIF
            val originalBitmapUnrotated = BitmapFactory.decodeFile(originalPhotoPath)
            if (originalBitmapUnrotated == null) {
                Log.e(TAG, "Failed to decode original photo file: $originalPhotoPath")
                return null
            }

            val exif = ExifInterface(originalPhotoPath)
            val orientation = exif.getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_UNDEFINED)
            val matrix = Matrix()
            when (orientation) {
                ExifInterface.ORIENTATION_ROTATE_90 -> matrix.postRotate(90f)
                ExifInterface.ORIENTATION_ROTATE_180 -> matrix.postRotate(180f)
                ExifInterface.ORIENTATION_ROTATE_270 -> matrix.postRotate(270f)
                ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> matrix.preScale(-1.0f, 1.0f)
                ExifInterface.ORIENTATION_FLIP_VERTICAL -> matrix.preScale(1.0f, -1.0f)
                // More complex cases may need additional handling
            }
            val originalBitmap = Bitmap.createBitmap(originalBitmapUnrotated, 0, 0, originalBitmapUnrotated.width, originalBitmapUnrotated.height, matrix, true)


            val photoWidth = originalBitmap.width.toFloat()
            val photoHeight = originalBitmap.height.toFloat()
            val photoAspectRatio = photoWidth / photoHeight

            val previewWidth = previewView.width.toFloat()
            val previewHeight = previewView.height.toFloat()
            if (previewWidth == 0f || previewHeight == 0f) {
                Log.e(TAG, "PreviewView dimensions are zero. Cannot calculate crop.")
                return null
            }
            val rawPreviewAspectRatio = previewWidth / previewHeight
            // The captured photo can be 90° transposed from the preview — e.g. it
            // comes out landscape (orientation-aware capture / ViewPort crop / EXIF)
            // while the preview is portrait. They then describe the SAME field of
            // view, just rotated. Compare in the PHOTO's orientation; otherwise we
            // trim the wrong axis and slice the scene roughly in half, which looks
            // like a heavy zoom-in. Same-orientation is unchanged (no-op).
            val photoIsLandscape = photoWidth >= photoHeight
            val previewIsLandscape = previewWidth >= previewHeight
            val previewAspectRatio = if (photoIsLandscape == previewIsLandscape) {
                rawPreviewAspectRatio
            } else {
                previewHeight / previewWidth
            }

            Log.d(TAG, "Original Photo: ${photoWidth}x$photoHeight (AR: $photoAspectRatio)")
            Log.d(TAG, "Preview View: ${previewWidth}x$previewHeight (AR: $rawPreviewAspectRatio, effective: $previewAspectRatio)")

            var cropX = 0f
            var cropY = 0f
            var cropWidth = photoWidth
            var cropHeight = photoHeight

            if (previewView.scaleType == PreviewView.ScaleType.FILL_CENTER) { // "cover" mode
                if (photoAspectRatio > previewAspectRatio) {
                    // Original photo is wider than the preview (e.g. 16:9 photo, 4:3 preview)
                    // => Preview fills the photo's height and crops the width
                    cropHeight = photoHeight
                    cropWidth = photoHeight * previewAspectRatio
                    cropX = (photoWidth - cropWidth) / 2
                } else if (photoAspectRatio < previewAspectRatio) {
                    // Original photo is taller than the preview (e.g. 4:3 photo, 16:9 preview)
                    // => Preview fills the photo's width and crops the height
                    cropWidth = photoWidth
                    cropHeight = photoWidth / previewAspectRatio
                    cropY = (photoHeight - cropHeight) / 2
                }
                // If the aspect ratios are equal, no crop is needed (cropWidth=photoWidth, cropHeight=photoHeight)
            } else {
                Log.w(TAG, "Cropping is currently only implemented for 'cover' (FILL_CENTER) mode.")
                return originalPhotoPath // Return the original photo if not in cover mode
            }

            if (cropX < 0 || cropY < 0 || cropWidth <= 0 || cropHeight <= 0 || cropX + cropWidth > photoWidth + 0.1 || cropY + cropHeight > photoHeight + 0.1 ) {
                Log.e(TAG, "Invalid crop rectangle calculated: x=$cropX, y=$cropY, w=$cropWidth, h=$cropHeight for photo ${photoWidth}x${photoHeight}. Returning original.")
                return originalPhotoPath
            }


            val croppedBitmap = Bitmap.createBitmap(
                originalBitmap,
                cropX.toInt(),
                cropY.toInt(),
                cropWidth.toInt(),
                cropHeight.toInt()
            )

            // Save the cropped bitmap
            val croppedPhotoFile = File(context.cacheDir, "cropped_${SimpleDateFormat(FILENAME_FORMAT, Locale.US).format(System.currentTimeMillis())}.jpg")
            FileOutputStream(croppedPhotoFile).use { out ->
                croppedBitmap.compress(Bitmap.CompressFormat.JPEG, 90, out) // quality 90
            }
            croppedBitmap.recycle() // Free the memory of the cropped bitmap
            // originalBitmap.recycle() // originalBitmap was already handled by createBitmap with a matrix

            Log.d(TAG, "Cropped photo saved to: ${croppedPhotoFile.absolutePath}")
            return croppedPhotoFile.absolutePath

        } catch (e: Exception) {
            Log.e(TAG, "Error during cropPhotoToMatchPreview: ${e.message}", e)
            return null // Return null on error; takePhoto will handle returning the original photo
        }
    }

    private fun deleteAllPhotosNative(result: MethodChannel.Result) {
        Log.d(TAG, "deleteAllPhotosNative called for viewId $viewId")
        var allDeleted = true
        var filesFound = false
        try {
            val cacheDir = context.cacheDir
            val photoFiles = cacheDir.listFiles { file ->
                file.name.startsWith("photo_") && file.name.endsWith(".jpg")
            }

            if (photoFiles != null && photoFiles.isNotEmpty()) {
                filesFound = true
                for (file in photoFiles) {
                    if (file.delete()) {
                        Log.d(TAG, "Deleted photo: ${file.name}")
                    } else {
                        Log.w(TAG, "Failed to delete photo: ${file.name}")
                        allDeleted = false
                    }
                }
            } else {
                Log.d(TAG, "No photos found in cache directory to delete.")
            }

            if (allDeleted) {
                result.success(true)
            } else {
                result.success(false)
            }

        } catch (e: Exception) {
            Log.e(TAG, "Error deleting photos: ${e.message}", e)
            result.error("DELETE_FAILED", "Error deleting photos: ${e.message}", null)
        }
    }


    private fun setTargetRotationNative(rotation: Int, result: MethodChannel.Result) {
        val surfaceRotation = when (rotation) {
            0 -> Surface.ROTATION_0
            90 -> Surface.ROTATION_90
            180 -> Surface.ROTATION_180
            270 -> Surface.ROTATION_270
            else -> Surface.ROTATION_0
        }
        currentTargetRotation = surfaceRotation
        imageCapture?.targetRotation = surfaceRotation
        Log.d(TAG, "Set target rotation to $rotation ($surfaceRotation) for viewId $viewId")
        result.success(null)
    }

    private fun setZoomNative(zoomRatio: Float, result: MethodChannel.Result) {
        val cam = camera
        if (cam == null) {
            result.error("NO_CAMERA", "Camera not initialized", null)
            return
        }
        try {
            val zoomState = cam.cameraInfo.zoomState.value
            val minZoom = zoomState?.minZoomRatio ?: 1.0f
            val maxZoom = zoomState?.maxZoomRatio ?: 1.0f
            val clampedZoom = zoomRatio.coerceIn(minZoom, maxZoom)
            cam.cameraControl.setZoomRatio(clampedZoom).addListener({
                result.success(null)
            }, ContextCompat.getMainExecutor(context))
        } catch (e: Exception) {
            Log.e(TAG, "Error setting zoom: ${e.message}", e)
            result.error("ZOOM_FAILED", "Failed to set zoom: ${e.message}", null)
        }
    }

    private fun getMaxZoomNative(result: MethodChannel.Result) {
        val cam = camera
        if (cam == null) {
            result.success(1.0)
            return
        }
        val zoomState = cam.cameraInfo.zoomState.value
        val maxZoom = zoomState?.maxZoomRatio?.toDouble() ?: 1.0
        result.success(maxZoom)
    }

    private fun getMinZoomNative(result: MethodChannel.Result) {
        val cam = camera
        if (cam == null) {
            result.success(1.0)
            return
        }
        val zoomState = cam.cameraInfo.zoomState.value
        val minZoom = zoomState?.minZoomRatio?.toDouble() ?: 1.0
        result.success(minZoom)
    }
    override fun getView(): View { return previewView }

    override fun dispose() {
        Log.d(TAG, "Disposing CameraPlatformView for viewId $viewId")
        diag("lifecycle", "dispose")
        lifecycleOwner.lifecycle.removeObserver(this)
        isCameraPausedManually = false
        isCameraInitialized = false
        imageAnalysisUseCase?.clearAnalyzer()
        imageAnalysisUseCase = null
        detectionAnalyzer?.close()
        detectionAnalyzer = null
        cameraExecutor.shutdown()
        analysisExecutor.shutdown()
        cameraProvider?.unbindAll()
        camera = null
        detectionEventSink = null
        eventChannel.setStreamHandler(null)
        methodChannel.setMethodCallHandler(null)
    }
}
