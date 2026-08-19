// File: ios/Runner/SwiftCameraPreview.swift
import Flutter
import UIKit
import AVFoundation
import CoreImage
import MediaPipeTasksVision

// Custom UIView subclass to manage the previewLayer's frame + the native box.
class CameraHostView: UIView {
    var previewLayer: AVCaptureVideoPreviewLayer?

    /// How long the box + ground guide take to fade out when the car leaves the
    /// frame (set from the `detectionFadeMillis` creation param). They still snap
    /// in immediately when a car is (re)acquired.
    var fadeOutDuration: CFTimeInterval = 0.2

    // Diagnostics: only log when the layout actually changes (avoids spam).
    private var lastLoggedBounds: CGRect = .zero

    // Translucent "ground guide" fill, drawn below the box. A gradient (opaque
    // at the ground-side edge, fading to transparent as it meets the car) is
    // masked to a shape: the ground strip with the car region punched out
    // (even-odd), so the band laps up the sides of the box without covering it.
    lazy var groundGuideGradient: CAGradientLayer = {
        let g = CAGradientLayer()
        g.startPoint = CGPoint(x: 0, y: 0.5)
        g.endPoint = CGPoint(x: 1, y: 0.5)
        return g
    }()
    private lazy var groundGuideMask: CAShapeLayer = {
        let m = CAShapeLayer()
        m.fillRule = .evenOdd
        m.fillColor = UIColor.black.cgColor
        return m
    }()

    // Native bounding-box overlay drawn directly on top of the preview.
    lazy var detectionBoxLayer: CAShapeLayer = {
        let l = CAShapeLayer()
        l.fillColor = UIColor.clear.cgColor
        l.lineWidth = 4
        l.strokeColor = UIColor.clear.cgColor
        return l
    }()

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = self.bounds
        // Ground guide sits below the box (added first).
        if groundGuideGradient.superlayer == nil {
            layer.addSublayer(groundGuideGradient)
        }
        if detectionBoxLayer.superlayer == nil {
            layer.addSublayer(detectionBoxLayer)
        }
        groundGuideGradient.frame = self.bounds
        groundGuideMask.frame = self.bounds
        groundGuideGradient.mask = groundGuideMask
        detectionBoxLayer.frame = self.bounds

        // Diagnostics: a zero-size host view or a nil preview layer here means a
        // blank preview. Only log on change to keep it quiet.
        if self.bounds != lastLoggedBounds {
            lastLoggedBounds = self.bounds
            let pl = previewLayer
            print("NCVDIAG [ios hostview] layoutSubviews bounds=\(self.bounds) previewLayer=\(pl != nil ? "attached(frame=\(pl!.frame))" : "NIL")\(self.bounds.isEmpty ? " — WARNING zero-size view" : "")")
        }
    }

    /// Draws (or clears) the translucent ground band. Glides with the box.
    /// Must be called on the main thread.
    func updateGroundGuide(maskPath: CGPath?, color: UIColor, startPoint: CGPoint, endPoint: CGPoint) {
        guard let p = maskPath else {
            // Nothing shown, or already fading/faded out — nothing to do.
            if groundGuideMask.path == nil || groundGuideGradient.opacity == 0 { return }
            // Quick fade-out instead of an abrupt cut; clear the mask once hidden
            // so the next appearance snaps in cleanly.
            CATransaction.begin()
            CATransaction.setAnimationDuration(fadeOutDuration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            CATransaction.setCompletionBlock { [weak self] in
                guard let self = self, self.groundGuideGradient.opacity == 0 else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.groundGuideMask.path = nil
                CATransaction.commit()
            }
            groundGuideGradient.opacity = 0
            CATransaction.commit()
            return
        }
        let solid = color.withAlphaComponent(0.30).cgColor
        let clear = color.withAlphaComponent(0.0).cgColor
        let firstAppearance = (groundGuideMask.path == nil)
        CATransaction.begin()
        if firstAppearance {
            CATransaction.setDisableActions(true)
        } else {
            CATransaction.setAnimationDuration(0.12)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
        }
        // Cancel any in-flight fade-out and ensure the guide is fully visible.
        if groundGuideGradient.opacity != 1 {
            groundGuideGradient.removeAnimation(forKey: "opacity")
            groundGuideGradient.opacity = 1
        }
        groundGuideMask.path = p
        // Solid for the first stretch, then fade to transparent as it meets the
        // car so there's no harsh cutoff at the box edge.
        groundGuideGradient.colors = [solid, solid, clear]
        groundGuideGradient.locations = [0.0, 0.7, 1.0]
        groundGuideGradient.startPoint = startPoint
        groundGuideGradient.endPoint = endPoint
        CATransaction.commit()
    }

    /// Draws (or clears) the detection box in this view's coordinate space.
    /// Detections arrive at ~10fps; animating the path change makes the box
    /// glide smoothly at the display refresh rate instead of stepping.
    /// Must be called on the main thread.
    func updateDetectionBox(rect: CGRect?, color: UIColor) {
        guard let r = rect else {
            // Nothing shown, or already fading/faded out — nothing to do.
            if detectionBoxLayer.path == nil || detectionBoxLayer.opacity == 0 { return }
            // Quick fade-out instead of an abrupt cut; clear the path once hidden
            // so the next appearance snaps in cleanly.
            CATransaction.begin()
            CATransaction.setAnimationDuration(fadeOutDuration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
            CATransaction.setCompletionBlock { [weak self] in
                guard let self = self, self.detectionBoxLayer.opacity == 0 else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.detectionBoxLayer.path = nil
                CATransaction.commit()
            }
            detectionBoxLayer.opacity = 0
            CATransaction.commit()
            return
        }
        let newPath = UIBezierPath(roundedRect: r, cornerRadius: 10).cgPath
        // Snap on first appearance; glide on subsequent updates.
        let firstAppearance = (detectionBoxLayer.path == nil)
        CATransaction.begin()
        if firstAppearance {
            CATransaction.setDisableActions(true)
        } else {
            CATransaction.setAnimationDuration(0.12)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
        }
        // Cancel any in-flight fade-out and ensure the box is fully visible.
        if detectionBoxLayer.opacity != 1 {
            detectionBoxLayer.removeAnimation(forKey: "opacity")
            detectionBoxLayer.opacity = 1
        }
        detectionBoxLayer.path = newPath
        detectionBoxLayer.strokeColor = color.cgColor
        CATransaction.commit()
    }

    deinit {
        print("[CameraHostView-\(ObjectIdentifier(self))] DEINIT: Cleaning up previewLayer.")
        previewLayer?.removeFromSuperlayer()
        previewLayer = nil
    }
}

class CameraPlatformViewFactory: NSObject, FlutterPlatformViewFactory {
    private var messenger: FlutterBinaryMessenger
    init(messenger: FlutterBinaryMessenger) {
        self.messenger = messenger
        super.init()
    }
    func create( withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
        return CameraPlatformView( frame: frame, viewIdentifier: viewId, arguments: args, binaryMessenger: messenger)
    }
    public func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
        return FlutterStandardMessageCodec.sharedInstance()
    }
}

enum CameraSetupError: Error, LocalizedError {
    case failedToGetCaptureDevice
    case couldNotAddInput
    case couldNotAddPhotoOutput
    case couldNotAddVideoDataOutput

    var errorDescription: String? {
        switch self {
        case .failedToGetCaptureDevice: return "Failed to get capture device."
        case .couldNotAddInput: return "Could not add input to session."
        case .couldNotAddPhotoOutput: return "Could not add PhotoOutput to session."
        case .couldNotAddVideoDataOutput: return "Could not add VideoDataOutput to session."
        }
    }
}

class CameraPlatformView: NSObject, FlutterPlatformView,
    AVCapturePhotoCaptureDelegate, AVCaptureVideoDataOutputSampleBufferDelegate,
    FlutterStreamHandler
{
    private var _hostView: CameraHostView
    private var messenger: FlutterBinaryMessenger
    private var viewId: Int64
    private var methodChannel: FlutterMethodChannel?

    private var captureSession: AVCaptureSession?
    private var photoOutput: AVCapturePhotoOutput?
    private var currentCameraInput: AVCaptureDeviceInput?
    private var currentCameraPosition: AVCaptureDevice.Position = .back
    private var isCameraPausedManually = false
    private var currentPhotoOrientation: AVCaptureVideoOrientation = .portrait
    private var currentPreviewFit: String = "cover"
    private var pendingPhotoCaptureResult: FlutterResult?

    private var bypassPermissionCheck: Bool = false
    private let sessionQueue = DispatchQueue(label: "com.plugin.camera_native.native_camera_view.sessionQueue.view-\(UUID().uuidString)")
    private var isDeinitializing = false
    private var lastPausedFrameCGImage: CGImage?

    // --- Diagnostics (NCVDIAG): trace the preview lifecycle to catch the
    // intermittent blank-preview issue. Filter device logs by "NCVDIAG".
    private let createdAt: CFTimeInterval = CACurrentMediaTime()
    private var cameraReadySent = false
    private var framesReceivedTotal = 0
    private var framesSinceHeartbeat = 0
    private var lastFrameHeartbeat: CFTimeInterval = 0

    private var videoDataOutput: AVCaptureVideoDataOutput?
    private let videoDataOutputQueue = DispatchQueue(label: "com.plugin.camera_native.native_camera_view.videoDataOutputQueue.view-\(UUID().uuidString)", qos: .userInitiated)
    private var lastFrameAsUIImage: UIImage?
    private lazy var ciContext = CIContext()

    // --- Live car detection (MediaPipe object detection) ---
    private var detectionEventChannel: FlutterEventChannel?
    private var detectionEventSink: FlutterEventSink?
    private var detectionEnabled: Bool = false
    // Toggleable helper overlays (set at instantiation via creationParams).
    private var showDetectionBox: Bool = true
    private var showGroundGuide: Bool = false
    private var groundGuideMinFraction: CGFloat = 0.15
    private var groundGuideEdge: String = "bottom" // bottom | top | left | right
    private var groundGuideOverlap: CGFloat = 0.15 // how far the band laps into the box
    private var isProcessingDetection = false
    private var lastDetectionTime: CFTimeInterval = 0
    private let detectionMinInterval: CFTimeInterval = 0.1 // throttle to ~10 fps
    private let detectionMinConfidence: Float = 0.3
    private var objectDetector: ObjectDetector?
    private var detectorInitFailed = false
    // The consuming app is always used in landscape-left, where the car is found
    // on the un-rotated frame — so we only detect on `.up`. To restore
    // rotation-tolerance (any holding) at the cost of extra inference when no car
    // is found, add [.right, .left, .down] here.
    private let detectionOrientationCandidates: [CGImagePropertyOrientation] = [.up]
    private var lastSuccessfulOrientationIndex = 0
    // Temporal smoothing to steady the box: EMA on the raw normalized rect, held
    // through a short run of empty frames to avoid flicker.
    private var smoothedBox: CGRect?
    private var detectionMissCount = 0
    private let detectionMaxMissFrames = 12
    private let detectionSmoothingFactor: CGFloat = 0.35
    // Perf: downscale the frame before detection (the model input is ~320px, so
    // processing full photo-resolution frames is wasted work). Also throttle the
    // paused-capture snapshot, which otherwise renders a full-res image/frame.
    private let detectionMaxSide: CGFloat = 512
    private var lastPausedFrameUpdateTime: CFTimeInterval = 0
    private let pausedFrameMinInterval: CFTimeInterval = 0.2


    


    init(
        frame: CGRect,
        viewIdentifier viewId: Int64,
        arguments args: Any?,
        binaryMessenger messenger: FlutterBinaryMessenger
    ) {
        self.messenger = messenger
        self.viewId = viewId
        self._hostView = CameraHostView(frame: frame)
        
        if let params = args as? [String: Any] {
            if let useFront = params["isFrontCamera"] as? Bool, useFront {
                self.currentCameraPosition = .front
            } else {
                self.currentCameraPosition = .back
            }
            if let fitMode = params["cameraPreviewFit"] as? String {
                self.currentPreviewFit = fitMode
            }
            if let bypass = params["bypassPermissionCheck"] as? Bool {
                self.bypassPermissionCheck = bypass
            }
            if let enableDetection = params["enableDetection"] as? Bool {
                self.detectionEnabled = enableDetection
            }
            if let showBox = params["showDetectionBox"] as? Bool {
                self.showDetectionBox = showBox
            }
            if let showGround = params["showGroundGuide"] as? Bool {
                self.showGroundGuide = showGround
            }
            if let minGround = params["groundGuideMinFraction"] as? Double {
                self.groundGuideMinFraction = CGFloat(minGround)
            }
            if let edge = params["groundGuideEdge"] as? String {
                self.groundGuideEdge = edge
            }
            if let overlap = params["groundGuideOverlap"] as? Double {
                self.groundGuideOverlap = CGFloat(overlap)
            }
            if let fadeMs = params["detectionFadeMillis"] as? Int {
                self._hostView.fadeOutDuration = CFTimeInterval(fadeMs) / 1000.0
            }
        }
        
        self.methodChannel = FlutterMethodChannel(
            name: "com.plugin.camera_native.native_camera_view/camera_method_channel_ios_\(viewId)",
            binaryMessenger: messenger
        )
        self.detectionEventChannel = FlutterEventChannel(
            name: "com.plugin.camera_native.native_camera_view/camera_detections_ios_\(viewId)",
            binaryMessenger: messenger
        )
        super.init()

        self.detectionEventChannel?.setStreamHandler(self)

        print("[CameraPlatformView-\(viewId)] INIT with lens: \(self.currentCameraPosition == .front ? "FRONT":"BACK"). Frame: \(frame), Thread: \(Thread.current)")

        self.methodChannel?.setMethodCallHandler({ [weak self] (call: FlutterMethodCall, result: @escaping FlutterResult) -> Void in
            guard let strongSelf = self else {
                DispatchQueue.main.async { result(FlutterError(code: "INSTANCE_GONE", message: "Platform view instance was deallocated.", details: nil)) }
                return
            }
            guard !strongSelf.isDeinitializing else {
                 DispatchQueue.main.async { result(FlutterError(code: "INSTANCE_DEINITIALIZING", message: "Platform view instance is deinitializing.", details: nil)) }
                return
            }
            strongSelf.handleMethodCall(call, result: result)
        })
        
        print("[CameraPlatformView-\(viewId)] Parsed arguments: fitMode=\(self.currentPreviewFit), useFront=\(self.currentCameraPosition == .front)")
        diag("init", "created (lens=\(currentCameraPosition == .front ? "front" : "back"), fit=\(currentPreviewFit), detection=\(detectionEnabled), bypassPerm=\(bypassPermissionCheck))")
    }

    func view() -> UIView { return _hostView }

    // MARK: - Diagnostics (NCVDIAG)

    /// Emits one tagged, elapsed-timestamped diagnostic line. Filter device logs
    /// by "NCVDIAG" to trace the whole preview lifecycle across Dart + native.
    private func diag(_ area: String, _ message: String) {
        let t = String(format: "%.3f", CACurrentMediaTime() - createdAt)
        print("NCVDIAG +\(t)s [ios view \(viewId)] [\(area)] \(message)")
    }

    /// Registers observers for the AVCaptureSession notifications that are the
    /// usual causes of a suddenly-blank preview (interruptions, runtime errors).
    /// Scoped to [session] so we only hear about the current session.
    private func registerSessionObservers(_ session: AVCaptureSession) {
        let nc = NotificationCenter.default
        nc.removeObserver(self) // clear any observers from a previous session
        nc.addObserver(self, selector: #selector(sessionRuntimeError(_:)),
                       name: .AVCaptureSessionRuntimeError, object: session)
        nc.addObserver(self, selector: #selector(sessionWasInterrupted(_:)),
                       name: .AVCaptureSessionWasInterrupted, object: session)
        nc.addObserver(self, selector: #selector(sessionInterruptionEnded(_:)),
                       name: .AVCaptureSessionInterruptionEnded, object: session)
        nc.addObserver(self, selector: #selector(sessionDidStartRunning(_:)),
                       name: .AVCaptureSessionDidStartRunning, object: session)
        nc.addObserver(self, selector: #selector(sessionDidStopRunning(_:)),
                       name: .AVCaptureSessionDidStopRunning, object: session)
        diag("session", "observers registered")
    }

    @objc private func sessionRuntimeError(_ n: Notification) {
        let err = n.userInfo?[AVCaptureSessionErrorKey]
        diag("session", "RUNTIME ERROR: \(String(describing: err)) — preview will blank until the session recovers")
    }

    @objc private func sessionWasInterrupted(_ n: Notification) {
        var reasonStr = "unknown"
        if let raw = n.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int {
            let name: String
            switch raw {
            case 1: name = "videoDeviceNotAvailableInBackground"
            case 2: name = "audioDeviceInUseByAnotherClient"
            case 3: name = "videoDeviceInUseByAnotherClient"
            case 4: name = "videoDeviceNotAvailableWithMultipleForegroundApps"
            case 5: name = "videoDeviceNotAvailableDueToSystemPressure"
            default: name = "other"
            }
            reasonStr = "\(raw) (\(name))"
        }
        diag("session", "INTERRUPTED reason=\(reasonStr) — THIS BLANKS THE PREVIEW")
    }

    @objc private func sessionInterruptionEnded(_ n: Notification) {
        diag("session", "interruption ended — preview should resume; isRunning=\(captureSession?.isRunning ?? false)")
    }

    @objc private func sessionDidStartRunning(_ n: Notification) {
        diag("session", "didStartRunning")
    }

    @objc private func sessionDidStopRunning(_ n: Notification) {
        diag("session", "didStopRunning (preview goes blank while stopped)")
    }

    private func checkCameraPermissionsAndSetup() {
        print("[CameraPlatformView-\(viewId)] checkCameraPermissionsAndSetup CALLED")
        guard !isDeinitializing else {
            print("[CameraPlatformView-\(viewId)] checkCameraPermissionsAndSetup: Instance is deinitializing, aborting.")
            return
        }

        diag("perm", "authStatus=\(AVCaptureDevice.authorizationStatus(for: .video).rawValue), bypass=\(bypassPermissionCheck)")

        //  Check the bypass flag first
        if bypassPermissionCheck {
            print("[CameraPlatformView-\(viewId)] Permission check is BYPASSED. Proceeding directly to setup.")
            self.setupCamera()
            return // Exit the function early
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            // Permission already granted, continue setting up the camera
            print("[CameraPlatformView-\(viewId)] Permission authorized.")
            self.setupCamera()

        case .notDetermined:
            // Asking for permission for the first time; the system will show a dialog
            print("[CameraPlatformView-\(viewId)] Permission not determined. Requesting...")
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let strongSelf = self, !strongSelf.isDeinitializing else { return }
                DispatchQueue.main.async {
                    if granted {
                        strongSelf.setupCamera()
                    } else {
                        print("[CameraPlatformView-\(strongSelf.viewId)] Permission denied by user on first request.")
                        // Could show a gentle message here if desired, or do nothing
                    }
                }
            }

        case .denied, .restricted:
            // Permission was previously denied or is restricted by a parent/organization
            print("[CameraPlatformView-\(viewId)] Permission denied previously or is restricted.")

            // SHOW THE NATIVE ALERT
            self.showPermissionDeniedAlert()

            // (No need to send an error back to Flutter once the alert is shown here)
            // DispatchQueue.main.async {
            //     if let channel = self.methodChannel, !self.isDeinitializing {
            //         channel.invokeMethod("onError", arguments: "camera_permission_denied_previously")
            //     }
            // }

        @unknown default:
            fatalError("Unknown camera authorization status for viewId: \(viewId)")
        }
    }

    private func setupCamera() {
        sessionQueue.async { [weak self] in
            guard let strongSelf = self, !strongSelf.isDeinitializing else {
                print("[CameraPlatformView-AGGREGATED] setupCamera: strongSelf is nil or deinitializing.")
                return
            }
            let viewId = strongSelf.viewId
            let targetLens = strongSelf.currentCameraPosition

            print("[CameraPlatformView-\(viewId)] setupCamera: Called on sessionQueue. Target lens: \(targetLens == .front ? "FRONT" : "BACK")")

            if let existingSession = strongSelf.captureSession {
                print("[CameraPlatformView-\(viewId)] setupCamera: Cleaning up existing session.")
                if existingSession.isRunning { existingSession.stopRunning() }
                existingSession.inputs.forEach { existingSession.removeInput($0) }
                existingSession.outputs.forEach { existingSession.removeOutput($0) }
                if let videoOutput = strongSelf.videoDataOutput {
                    videoOutput.setSampleBufferDelegate(nil, queue: nil)
                }
                strongSelf.videoDataOutput = nil
                strongSelf.lastFrameAsUIImage = nil
                strongSelf.photoOutput = nil
                strongSelf.currentCameraInput = nil
            }
            strongSelf.captureSession = nil

            print("[CameraPlatformView-\(viewId)] setupCamera: Creating new session for \(targetLens == .front ? "FRONT" : "BACK").")
            let newSession = AVCaptureSession()
            strongSelf.captureSession = newSession
            newSession.sessionPreset = .photo
            strongSelf.cameraReadySent = false
            strongSelf.framesReceivedTotal = 0
            strongSelf.registerSessionObservers(newSession)
            strongSelf.diag("setup", "begin (lens=\(targetLens == .front ? "front" : "back"), paused=\(strongSelf.isCameraPausedManually))")

            var configurationSuccess = true
            var setupError: Error? // Variable to hold the error if any

            newSession.beginConfiguration()
            print("[CameraPlatformView-\(viewId)] setupCamera: newSession.beginConfiguration() called.")

            do {
                guard let captureDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: targetLens) else {
                    throw CameraSetupError.failedToGetCaptureDevice
                }
                let input = try AVCaptureDeviceInput(device: captureDevice)
                if newSession.canAddInput(input) { newSession.addInput(input); strongSelf.currentCameraInput = input }
                else { throw CameraSetupError.couldNotAddInput }

                let newPhotoOutput = AVCapturePhotoOutput()
                if newSession.canAddOutput(newPhotoOutput) {
                    newSession.addOutput(newPhotoOutput)
                    strongSelf.photoOutput = newPhotoOutput
                    // Apply current orientation to photo output connection
                    if let connection = newPhotoOutput.connection(with: .video),
                       connection.isVideoOrientationSupported {
                        connection.videoOrientation = strongSelf.currentPhotoOrientation
                    }
                }
                else { throw CameraSetupError.couldNotAddPhotoOutput }

                let newVideoDataOutput = AVCaptureVideoDataOutput()
                newVideoDataOutput.alwaysDiscardsLateVideoFrames = true
                // MediaPipe's MPImage(pixelBuffer:) requires 32BGRA; force it here
                // (also fine for the CIImage-based paused-frame capture).
                newVideoDataOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
                newVideoDataOutput.setSampleBufferDelegate(strongSelf, queue: strongSelf.videoDataOutputQueue)
                if newSession.canAddOutput(newVideoDataOutput) {
                    newSession.addOutput(newVideoDataOutput)
                    strongSelf.videoDataOutput = newVideoDataOutput
                    if let connection = newVideoDataOutput.connection(with: .video) {
                        if connection.isVideoOrientationSupported { /* TODO: Set orientation */ }
                        if connection.isVideoMirroringSupported && targetLens == .front { connection.isVideoMirrored = true }
                    }
                } else { throw CameraSetupError.couldNotAddVideoDataOutput }

            } catch {
                print("[CameraPlatformView-\(viewId)] setupCamera: Error during I/O setup: \(error.localizedDescription)")
                setupError = error // Save the error
                configurationSuccess = false
            }

            newSession.commitConfiguration()
            print("[CameraPlatformView-\(viewId)] setupCamera: newSession.commitConfiguration() called. configurationSuccess: \(configurationSuccess)")

            guard configurationSuccess else {
                print("[CameraPlatformView-\(viewId)] setupCamera: Configuration failed. Cleaning up and sending error to Flutter.")
                strongSelf.diag("setup", "CONFIGURATION FAILED: \(setupError?.localizedDescription ?? "unknown") — sending onCameraError")
                // Send an error signal back to Flutter
                let errorMessage = setupError?.localizedDescription ?? "Unknown configuration error."
                DispatchQueue.main.async {
                    strongSelf.methodChannel?.invokeMethod("onCameraError", arguments: ["message": errorMessage])
                }

                if strongSelf.captureSession === newSession { strongSelf.captureSession = nil }
                strongSelf.videoDataOutput?.setSampleBufferDelegate(nil, queue: nil); strongSelf.videoDataOutput = nil
                strongSelf.photoOutput = nil; strongSelf.currentCameraInput = nil
                return
            }

            if !strongSelf.isCameraPausedManually {
                if strongSelf.captureSession === newSession && !newSession.isRunning {
                    newSession.startRunning()
                    print("[CameraPlatformView-\(viewId)] setupCamera: newSession started for \(targetLens).")
                    strongSelf.diag("setup", "startRunning called; session.isRunning=\(newSession.isRunning)")
                }
            } else {
                print("[CameraPlatformView-\(viewId)] setupCamera: Camera manually paused, not starting session for \(targetLens).")
                strongSelf.diag("setup", "paused — session NOT started")
            }

            DispatchQueue.main.async {
                guard let sSelf = self, !sSelf.isDeinitializing, sSelf.captureSession === newSession else { return }
                let previewLayer = AVCaptureVideoPreviewLayer(session: newSession)
                sSelf._hostView.previewLayer?.removeFromSuperlayer()
                sSelf._hostView.previewLayer = previewLayer
                sSelf.applyPreviewFitToLayer(layer: previewLayer)
                sSelf._hostView.layer.insertSublayer(previewLayer, at: 0)
                sSelf._hostView.setNeedsLayout()
                print("[CameraPlatformView-\(sSelf.viewId)] setupCamera: Preview layer configured for \(targetLens).")
                sSelf.diag("setup", "preview layer attached (hostView.bounds=\(sSelf._hostView.bounds), gravity=\(previewLayer.videoGravity.rawValue))")

                // Send the camera-ready signal back to Flutter
                sSelf.cameraReadySent = true
                sSelf.diag("ready", "sending onCameraReady")
                sSelf.methodChannel?.invokeMethod("onCameraReady", arguments: nil)

                // Native watchdog: 5s later, confirm the session is actually
                // running and frames are flowing. If not, the preview is blank.
                DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak sSelf] in
                    guard let s = sSelf, !s.isDeinitializing else { return }
                    let running = s.captureSession?.isRunning ?? false
                    let hasLayer = (s._hostView.previewLayer != nil)
                    if !running || s.framesReceivedTotal == 0 || !hasLayer || s._hostView.bounds.isEmpty {
                        s.diag("watchdog",
                               "5s check FAILED: isRunning=\(running), frames=\(s.framesReceivedTotal), previewLayer=\(hasLayer), bounds=\(s._hostView.bounds) — this is the blank-preview state")
                    } else {
                        s.diag("watchdog", "5s check OK: isRunning=true, frames=\(s.framesReceivedTotal)")
                    }
                }
            }
        }
    }
    
    private func applyPreviewFitToLayer(layer: AVCaptureVideoPreviewLayer) {
        switch currentPreviewFit.lowercased() {
        case "fitwidth", "fitheight": layer.videoGravity = .resizeAspectFill
        case "contain": layer.videoGravity = .resizeAspect
        case "cover": layer.videoGravity = .resizeAspectFill
        default: layer.videoGravity = .resizeAspectFill
        }
    }

    private func handleMethodCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        print("[CameraPlatformView-\(viewId)] handleMethodCall: \(call.method)")
        guard !isDeinitializing else {
             DispatchQueue.main.async { result(FlutterError(code: "INSTANCE_DEINITIALIZING_HANDLER", message: "Instance is deinitializing.", details: nil)) }
            return
        }
        switch call.method {
        case "initialize":
                print("[CameraPlatformView-\(viewId)] Initialization requested from Flutter.")
                diag("method", "initialize requested")
                checkCameraPermissionsAndSetup()
                result(nil)
        case "captureImage": capturePhoto(result: result)
        case "pauseCamera": pauseCameraNative(result: result)
        case "resumeCamera": resumeCameraNative(result: result)
        case "switchCamera":
            if let args = call.arguments as? [String: Any],
               let useFront = args["useFrontCamera"] as? Bool
            {
                switchCameraNative(useFront: useFront, result: result)
            } else {
                DispatchQueue.main.async { result(FlutterError(code: "INVALID_ARGUMENT",message: "Missing 'useFrontCamera'", details: nil)) }
            }
        case "setTargetRotation":
            if let args = call.arguments as? [String: Any],
               let rotation = args["rotation"] as? Int {
                setTargetRotationNative(rotation: rotation, result: result)
            } else {
                DispatchQueue.main.async { result(FlutterError(code: "INVALID_ARGUMENT", message: "Missing rotation value", details: nil)) }
            }
        case "setZoom":
            if let args = call.arguments as? [String: Any],
               let zoom = args["zoom"] as? Double {
                setZoomNative(zoomFactor: CGFloat(zoom), result: result)
            } else {
                DispatchQueue.main.async { result(FlutterError(code: "INVALID_ARGUMENT", message: "Missing zoom value", details: nil)) }
            }
        case "getMaxZoom":
            getMaxZoomNative(result: result)
        case "getMinZoom":
            getMinZoomNative(result: result)
        case "setDetectionEnabled":
            let enabled = (call.arguments as? Bool) ?? false
            self.detectionEnabled = enabled
            if !enabled {
                // Stopping inference doesn't erase what's already on screen: the
                // last box and ground guide stay painted until something draws
                // over them, which never comes. Clear them and drop the smoothing
                // state so a later re-enable starts fresh rather than gliding out
                // of a stale box.
                //
                // Routed through the frame queue first so it lands after any
                // inference still in flight - that one has already queued its own
                // main-thread draw, and clearing before it would just get painted
                // over again.
                videoDataOutputQueue.async { [weak self] in
                    guard let self = self else { return }
                    self.smoothedBox = nil
                    self.detectionMissCount = 0
                    DispatchQueue.main.async {
                        guard !self.isDeinitializing else { return }
                        _ = self.updateNativeOverlays(metadataRect: nil)
                    }
                }
            }
            print("[CameraPlatformView-\(viewId)] setDetectionEnabled: \(enabled)")
            result(nil)

        default:
            DispatchQueue.main.async { result(FlutterMethodNotImplemented) }
        }
    }

    private func switchCameraNative(useFront: Bool, result: @escaping FlutterResult) {
        let newPosition: AVCaptureDevice.Position = useFront ? .front : .back
        print("[CameraPlatformView-\(viewId)] switchCameraNative called. Requested: \(newPosition == .front ? "FRONT" : "BACK")")

        guard !isDeinitializing else {
            result(FlutterError(code: "INSTANCE_GONE", message: "Switching on deinitializing instance", details: nil))
            return
        }

        // If the camera is already in the correct position and the session is running, do nothing
        if self.currentCameraPosition == newPosition && (self.captureSession?.isRunning ?? false) {
            print("[CameraPlatformView-\(viewId)] Camera is already in the requested position and running.")
            result(nil)
            return
        }

        // Update the desired camera position
        self.currentCameraPosition = newPosition
        
        // Call setupCamera again to fully reconfigure the session with the new camera.
        // The setupCamera function is designed to clean up the old session safely.
        print("[CameraPlatformView-\(viewId)] Triggering setupCamera for new position.")
        self.setupCamera()
        
        result(nil)
    }
    
    private func cropImage(_ image: UIImage, toNormalizedRect cropRect: CGRect, targetViewIdForLog: Int64) -> UIImage? {
        guard let cgImage = image.cgImage else {
            print("[CameraPlatformView-\(targetViewIdForLog)] cropImage: Failed to get CGImage.")
            return nil
        }
        let originalWidth = CGFloat(cgImage.width)
        let originalHeight = CGFloat(cgImage.height)
        let cropX = cropRect.origin.x * originalWidth
        let cropY = cropRect.origin.y * originalHeight
        let cropWidth = cropRect.size.width * originalWidth
        let cropHeight = cropRect.size.height * originalHeight
        
        guard cropWidth > 0 && cropHeight > 0 else {
            print("[CameraPlatformView-\(targetViewIdForLog)] cropImage: Invalid crop dimensions (width or height is zero).")
            return nil
        }
        let pixelCropRect = CGRect(x: cropX, y: cropY, width: cropWidth, height: cropHeight)

        guard let croppedCGImage = cgImage.cropping(to: pixelCropRect) else {
            print("[CameraPlatformView-\(targetViewIdForLog)] cropImage: cgImage.cropping failed.")
            return nil
        }
        return UIImage(cgImage: croppedCGImage, scale: image.scale, orientation: image.imageOrientation)
    }

    private func capturePhoto(result: @escaping FlutterResult) {
            guard !isDeinitializing else {
                DispatchQueue.main.async { result(FlutterError(code: "INSTANCE_GONE", message: "Capturing on deinitializing instance", details: nil)) }
                return
            }

        if self.isCameraPausedManually {
            print("[CameraPlatformView-\(viewId)] Attempting to capture PAUSED image.")
            
            // 1. Get the stored raw CGImage
            guard let sourceCGImage = self.lastPausedFrameCGImage else {
                DispatchQueue.main.async { result(FlutterError(code: "NO_PAUSED_FRAME", message: "Camera is paused, but no raw frame was stored.", details: nil)) }
                return
            }

            let localViewId = self.viewId
            let fitModeForCrop = self.currentPreviewFit.lowercased()

            DispatchQueue.main.async { [weak self] in
                guard let strongSelf = self else {
                    result(FlutterError(code: "INSTANCE_GONE_CROP_PAUSED", message: "Instance deallocated before processing paused image.", details: nil))
                    return
                }
                
                var cgImageToProcess = sourceCGImage
                
                // 2. CROP THE RAW IMAGE FIRST (if in 'cover' mode)
                if fitModeForCrop == "cover" {
                    print("[CameraPlatformView-\(localViewId)] Paused capture in 'cover' mode. Cropping first.")
                    var normalizedCropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
                    if let previewLayer = strongSelf._hostView.previewLayer {
                        normalizedCropRect = previewLayer.metadataOutputRectConverted(fromLayerRect: previewLayer.bounds)
                    }
                    
                    // Convert the normalized rect into a pixel rect
                    let originalWidth = CGFloat(sourceCGImage.width)
                    let originalHeight = CGFloat(sourceCGImage.height)
                    let pixelCropRect = CGRect(
                        x: normalizedCropRect.origin.x * originalWidth,
                        y: normalizedCropRect.origin.y * originalHeight,
                        width: normalizedCropRect.size.width * originalWidth,
                        height: normalizedCropRect.size.height * originalHeight
                    )
                    
                    // Perform the crop
                    if let croppedCGImage = sourceCGImage.cropping(to: pixelCropRect) {
                        cgImageToProcess = croppedCGImage
                        print("[CameraPlatformView-\(localViewId)] Cropping successful.")
                    } else {
                        print("[CameraPlatformView-\(localViewId)] Cropping failed, will use un-cropped image.")
                    }
                }
                
                // 3. TRANSFORM THE CROPPED IMAGE (or the original if not cropped)
                var finalImage: UIImage?
                
                if strongSelf.currentCameraPosition == .front {
                    // For the front camera, rotate, flip horizontally and flip vertically
                    let mirroredAndRotatedImage = UIImage(cgImage: cgImageToProcess, scale: 1.0, orientation: .leftMirrored)
                    
                    UIGraphicsBeginImageContextWithOptions(mirroredAndRotatedImage.size, false, mirroredAndRotatedImage.scale)
                    if let context = UIGraphicsGetCurrentContext() {
                        context.translateBy(x: 0, y: mirroredAndRotatedImage.size.height)
                        context.scaleBy(x: 1.0, y: -1.0)
                        mirroredAndRotatedImage.draw(in: CGRect(x: 0, y: 0, width: mirroredAndRotatedImage.size.width, height: mirroredAndRotatedImage.size.height))
                        finalImage = UIGraphicsGetImageFromCurrentImageContext()
                        UIGraphicsEndImageContext()
                    }
                    if finalImage == nil { finalImage = mirroredAndRotatedImage } // Fallback
                    
                } else { // Back camera
                    finalImage = UIImage(cgImage: cgImageToProcess, scale: 1.0, orientation: .right)
                }
                
                // 4. SAVE THE FINAL IMAGE
                guard let imageToSave = finalImage else {
                    result(FlutterError(code: "PROCESS_FAILED", message: "Failed to create final UIImage.", details: nil))
                    return
                }
                
                strongSelf.saveImageDataAndReturnPath(imageToSave.jpegData(compressionQuality: 0.9), viewId: localViewId, resultCallback: result)
            }
            return // Return early since processing is asynchronous
        }

            // Live capture (not paused)
            print("[CameraPlatformView-\(viewId)] Attempting LIVE capture.")
            sessionQueue.async { [weak self] in
                guard let strongSelf = self, !strongSelf.isDeinitializing else { return }
                guard let photoOutput = strongSelf.photoOutput, let session = strongSelf.captureSession, session.isRunning else { return }
                let photoSettings = AVCapturePhotoSettings()
                strongSelf.pendingPhotoCaptureResult = result
                photoOutput.capturePhoto(with: photoSettings, delegate: strongSelf)
            }
        }

    private func showPermissionDeniedAlert() {
        DispatchQueue.main.async {
            guard let rootViewController = UIApplication.shared.keyWindow?.rootViewController else {
                print("[CameraPlatformView-\(self.viewId)] Could not find a root view controller to present the alert.")
                return
            }

            let title = "Camera Access Denied"
            let message = "Please go to Settings to grant camera access for the application."

            let alertController = UIAlertController(title: title, message: message, preferredStyle: .alert)

            // Add an "Open Settings" button to take the user straight to the app's settings
            let settingsAction = UIAlertAction(title: "Open Settings", style: .default) { _ in
                guard let settingsUrl = URL(string: UIApplication.openSettingsURLString) else { return }
                if UIApplication.shared.canOpenURL(settingsUrl) {
                    UIApplication.shared.open(settingsUrl)
                }
            }
            alertController.addAction(settingsAction)

            // Add a "Close" button
            let closeAction = UIAlertAction(title: "Close", style: .cancel, handler: nil)
            alertController.addAction(closeAction)

            // Present the alert
            rootViewController.present(alertController, animated: true, completion: nil)
        }
    }
    
    private func processAndSaveImage(originalImage: UIImage,
                                     normalizedCropRect: CGRect,
                                     shouldCropBasedOnRect: Bool,
                                     viewId: Int64,
                                     resultCallback: @escaping FlutterResult) {
        // Perform the crop and save on a background thread to avoid blocking the UI
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let strongSelf = self else {
                // The 'self' instance was deallocated before it could be processed and saved.
                DispatchQueue.main.async {
                    resultCallback(FlutterError(code: "INSTANCE_GONE_SAVE", message: "Instance deallocated before image could be processed/saved.", details: nil))
                }
                return
            }

            var imageToSave = originalImage
            var performActualCrop = false

            // Only crop if requested AND the crop rectangle is valid/not the entire image
            if shouldCropBasedOnRect {
                if !(normalizedCropRect.equalTo(CGRect(x: 0, y: 0, width: 1, height: 1))) && normalizedCropRect.width > 0 && normalizedCropRect.height > 0 {
                    performActualCrop = true
                } else {
                    print("[CameraPlatformView-\(viewId)] processAndSaveImage: No crop needed based on rect (\(normalizedCropRect)).")
                }
            }

            if performActualCrop {
                print("[CameraPlatformView-\(viewId)] processAndSaveImage: Attempting crop.")
                if let croppedImage = strongSelf.cropImage(originalImage, toNormalizedRect: normalizedCropRect, targetViewIdForLog: viewId) {
                    imageToSave = croppedImage
                } else {
                    print("[CameraPlatformView-\(viewId)] processAndSaveImage: Cropping failed, using original image.")
                }
            }
            
            // Save the final image (cropped or original)
            strongSelf.saveImageDataAndReturnPath(imageToSave.jpegData(compressionQuality: 0.9), viewId: viewId, resultCallback: resultCallback)
        }
    }
    
    // Helper function to save the image and return the result to Flutter
        private func saveImageDataAndReturnPath(_ data: Data?, viewId: Int64, resultCallback: @escaping FlutterResult) {
            guard let imageDataToSave = data else {
                DispatchQueue.main.async { resultCallback(FlutterError(code: "PROCESS_FAILED", message: "Failed to get final image data.", details: nil)) }
                return
            }
            let tempDir = NSTemporaryDirectory()
            let fileName = "photo_ios_\(viewId)_\(Date().timeIntervalSince1970).jpg"
            let filePath = URL(fileURLWithPath: tempDir).appendingPathComponent(fileName)
            do {
                try imageDataToSave.write(to: filePath)
                DispatchQueue.main.async { resultCallback(filePath.path) }
            } catch {
                DispatchQueue.main.async { resultCallback(FlutterError(code: "SAVE_FAILED", message: "Error saving photo: \(error.localizedDescription)", details: nil)) }
            }
        }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
            guard let resultCallback = self.pendingPhotoCaptureResult else {
                // If there is no pending result, this may be an unexpected capture, so ignore it.
                print("[CameraPlatformView-\(viewId)] photoOutput called without a pending result callback.")
                return
            }
            self.pendingPhotoCaptureResult = nil // Always clean up the callback
            
            guard !isDeinitializing else {
                DispatchQueue.main.async { resultCallback(FlutterError(code: "INSTANCE_DEINIT_CAPTURE", message: "Instance deinitializing during photo capture.", details: nil)) }
                return
            }
            
            if let error = error {
                DispatchQueue.main.async { resultCallback(FlutterError(code: "CAPTURE_FAILED_PHOTO", message: "Error capturing photo: \(error.localizedDescription)", details: nil)) }
                return
            }
            
            guard let imageData = photo.fileDataRepresentation(), let originalImage = UIImage(data: imageData) else {
                DispatchQueue.main.async { resultCallback(FlutterError(code: "IMAGE_DATA_ERROR", message: "No image data or could not create UIImage.", details: nil)) }
                return
            }
            
            let localViewId = self.viewId
            let fitModeForCrop = self.currentPreviewFit.lowercased()

            // The crop logic for live images is kept as is
            if fitModeForCrop == "cover" {
                DispatchQueue.main.async { [weak self] in
                    guard let strongSelf = self else {
                        DispatchQueue.main.async { resultCallback(FlutterError(code: "INSTANCE_GONE_CROP_PARAMS_LIVE", message: "Instance deallocated before crop.", details: nil)) }
                        return
                    }
                    var normalizedCropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
                    if let previewLayer = strongSelf._hostView.previewLayer {
                        normalizedCropRect = previewLayer.metadataOutputRectConverted(fromLayerRect: previewLayer.bounds)
                    }
                    strongSelf.processAndSaveImage(originalImage: originalImage,
                                                   normalizedCropRect: normalizedCropRect,
                                                   shouldCropBasedOnRect: true,
                                                   viewId: localViewId,
                                                   resultCallback: resultCallback)
                }
            } else {
                self.processAndSaveImage(originalImage: originalImage,
                                           normalizedCropRect: CGRect(x: 0, y: 0, width: 1, height: 1),
                                           shouldCropBasedOnRect: false,
                                           viewId: localViewId,
                                           resultCallback: resultCallback)
            }
        }
    
    private func pauseCameraNative(result: @escaping FlutterResult) {
        print("[CameraPlatformView-\(viewId)] pauseCameraNative called.")
        diag("method", "pauseCamera")
        isCameraPausedManually = true
        
        // On pause, we stop the session. `lastPausedFrameImage` is still retained.
        // The unbindAll logic is unnecessary since setupCamera on resume handles that.
        self.sessionQueue.async { [weak self] in
            guard let strongSelf = self, let session = strongSelf.captureSession else {
                DispatchQueue.main.async { result(nil) }
                return
            }
            
            if session.isRunning {
                session.stopRunning()
                print("[CameraPlatformView-\(strongSelf.viewId)] Session stopped for pause.")
            }
            
            DispatchQueue.main.async {
                result(nil)
            }
        }
    }
    
    private func stopSessionForPauseInternal() {
        guard !isDeinitializing else { return }
        if let session = self.captureSession, session.isRunning {
            session.stopRunning()
        }
    }

    private func resumeCameraNative(result: @escaping FlutterResult) {
        print("[CameraPlatformView-\(viewId)] resumeCameraNative called.")
        diag("method", "resumeCamera")
        guard !isDeinitializing else {
            result(FlutterError(code: "INSTANCE_GONE", message: "Resuming on deinitializing instance", details: nil))
            return
        }
        
        isCameraPausedManually = false
        
        // On resume, instead of just restarting the old session, call setupCamera again.
        // This ensures all use cases (Preview, ImageCapture, VideoDataOutput) are rebound correctly.
        print("[CameraPlatformView-\(viewId)] Triggering setupCamera on resume.")
        self.setupCamera()
        
        result(nil)
    }
    
    // MARK: - AVCaptureVideoDataOutputSampleBufferDelegate
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard !isDeinitializing, output == self.videoDataOutput else { return }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Frame heartbeat: proof that frames are actually flowing. If these lines
        // go quiet while the app is foregrounded, the preview has stalled — line
        // it up against the session interruption/runtime-error logs.
        framesReceivedTotal += 1
        framesSinceHeartbeat += 1
        let hbNow = CACurrentMediaTime()
        if lastFrameHeartbeat == 0 {
            lastFrameHeartbeat = hbNow
            diag("frames", "first frame received (preview should be live)")
        } else if hbNow - lastFrameHeartbeat >= 2.0 {
            diag("frames", "\(framesSinceHeartbeat) frames in last \(String(format: "%.1f", hbNow - lastFrameHeartbeat))s (total=\(framesReceivedTotal))")
            lastFrameHeartbeat = hbNow
            framesSinceHeartbeat = 0
        }

        // Keep a recent full-res frame for paused capture, but throttled. Doing
        // this every frame at photo resolution was a major source of jank.
        let nowTs = CACurrentMediaTime()
        if nowTs - lastPausedFrameUpdateTime >= pausedFrameMinInterval {
            lastPausedFrameUpdateTime = nowTs
            let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
            self.lastPausedFrameCGImage = self.ciContext.createCGImage(ciImage, from: ciImage.extent)
        }

        // Run live subject detection on this frame (throttled, non-overlapping).
        self.runSubjectDetectionIfNeeded(on: pixelBuffer)
    }

    // MARK: - Live subject detection (MediaPipe object detection)

    /// Locates the bundled EfficientDet-Lite0 model across the possible bundle
    /// layouts (framework bundle, resource bundle, main bundle).
    private func modelPath() -> String? {
        let candidates = [Bundle(for: type(of: self)), Bundle.main]
        for bundle in candidates {
            if let path = bundle.path(forResource: "efficientdet_lite0", ofType: "tflite") {
                return path
            }
            if let assetsURL = bundle.url(forResource: "NativeCameraViewAssets", withExtension: "bundle"),
               let assetsBundle = Bundle(url: assetsURL),
               let path = assetsBundle.path(forResource: "efficientdet_lite0", ofType: "tflite") {
                return path
            }
        }
        return nil
    }

    /// Lazily creates the MediaPipe object detector. Returns nil (and disables
    /// further attempts) if creation fails, so detection stays advisory.
    private func ensureDetector() -> ObjectDetector? {
        if let detector = objectDetector { return detector }
        if detectorInitFailed { return nil }
        guard let path = modelPath() else {
            print("[CameraPlatformView-\(viewId)] Detection model not found in bundle.")
            detectorInitFailed = true
            return nil
        }
        func makeDetector(useGPU: Bool) throws -> ObjectDetector {
            let options = ObjectDetectorOptions()
            options.baseOptions.modelAssetPath = path
            options.baseOptions.delegate = useGPU ? .GPU : .CPU
            options.runningMode = .image
            options.scoreThreshold = detectionMinConfidence
            // NOTE: no categoryAllowlist — a single-category allowlist crashes the
            // GPU delegate ("Only all classes >= class 0 or >= class 1"). We filter
            // to "car" in code instead (see selectPrimaryCar).
            options.maxResults = 25
            return try ObjectDetector(options: options)
        }
        // Prefer the GPU delegate (much faster on device); fall back to CPU.
        do {
            objectDetector = try makeDetector(useGPU: true)
            return objectDetector
        } catch {
            print("[CameraPlatformView-\(viewId)] GPU detector failed, falling back to CPU: \(error.localizedDescription)")
        }
        do {
            objectDetector = try makeDetector(useGPU: false)
            return objectDetector
        } catch {
            print("[CameraPlatformView-\(viewId)] Failed to create ObjectDetector: \(error.localizedDescription)")
            detectorInitFailed = true
            return nil
        }
    }

    // --- Composite scoring constants (mirrors Android SubjectDetectionAnalyzer) ---
    private let weightArea: CGFloat = 0.35
    private let weightCenter: CGFloat = 0.30
    private let weightConfidence: CGFloat = 0.15
    private let weightContinuity: CGFloat = 0.20
    private let continuityIoUThreshold: CGFloat = 0.3
    private let minRelativeArea: CGFloat = 0.02 // noise filter
    /// Normalized rect of the previously-selected car (for continuity scoring).
    private var lastSelectedDetectionRect: CGRect?

    /// Runs the detector on one (already-oriented) image and returns the most
    /// prominent car box using composite scoring (area + center proximity +
    /// confidence + tracking continuity). Normalized (0..1, top-left) to the
    /// image's own dimensions.
    private func selectPrimaryCar(
        in ciImage: CIImage
    ) -> (rect: CGRect, label: String, confidence: Double)? {
        guard let detector = objectDetector else { return nil }
        guard let cg = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return nil }
        let w = CGFloat(cg.width)
        let h = CGFloat(cg.height)
        guard w > 0, h > 0 else { return nil }
        let frameArea = w * h
        let result: ObjectDetectorResult
        do {
            result = try detector.detect(image: try MPImage(uiImage: UIImage(cgImage: cg)))
        } catch {
            print("[CameraPlatformView-\(viewId)] Detection failed: \(error.localizedDescription)")
            return nil
        }
        // Filter to cars and apply minimum area noise filter.
        let candidates = result.detections.filter { det in
            guard det.categories.first?.categoryName == "car" else { return false }
            let bb = det.boundingBox
            let relativeArea = (bb.width * bb.height) / frameArea
            return relativeArea >= minRelativeArea
        }
        guard !candidates.isEmpty else {
            lastSelectedDetectionRect = nil
            return nil
        }

        // Find the max area for normalization.
        let maxArea = candidates.map { $0.boundingBox.width * $0.boundingBox.height }.max() ?? 1

        // Score each candidate with composite weights.
        var bestScore: CGFloat = -1
        var bestDetection: Detection?
        var bestNormRect: CGRect?

        for det in candidates {
            let bb = det.boundingBox
            let area = bb.width * bb.height
            let conf = CGFloat(det.categories.first?.score ?? 0)

            // Normalize area to 0..1 relative to the largest candidate.
            let areaNorm = maxArea > 0 ? area / maxArea : 0

            // Center proximity: 1.0 = dead center, 0.0 = corner.
            let centerX = bb.midX / w
            let centerY = bb.midY / h
            let distFromCenter = sqrt(pow(centerX - 0.5, 2) + pow(centerY - 0.5, 2))
            // Max possible distance ≈ 0.707
            let centerNorm = max(0, min(1, 1.0 - (distFromCenter / 0.707)))

            // Continuity: IoU with previously-selected car.
            let normRect = CGRect(x: bb.minX / w, y: bb.minY / h, width: bb.width / w, height: bb.height / h)
            let continuityNorm: CGFloat
            if let prev = lastSelectedDetectionRect {
                let iou = computeIoU(normRect, prev)
                continuityNorm = iou >= continuityIoUThreshold ? 1.0 : (iou / continuityIoUThreshold)
            } else {
                continuityNorm = 0
            }

            // Composite score.
            let score = weightArea * areaNorm +
                        weightCenter * centerNorm +
                        weightConfidence * conf +
                        weightContinuity * continuityNorm

            if score > bestScore {
                bestScore = score
                bestDetection = det
                bestNormRect = normRect
            }
        }

        guard let best = bestDetection, let normRect = bestNormRect else { return nil }
        lastSelectedDetectionRect = normRect
        let cat = best.categories.first
        return (normRect, cat?.categoryName ?? "car", Double(cat?.score ?? 0))
    }

    /// Computes Intersection-over-Union of two normalized rects.
    private func computeIoU(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let interLeft = max(a.minX, b.minX)
        let interTop = max(a.minY, b.minY)
        let interRight = min(a.maxX, b.maxX)
        let interBottom = min(a.maxY, b.maxY)
        let interArea = max(0, interRight - interLeft) * max(0, interBottom - interTop)
        if interArea <= 0 { return 0 }
        let aArea = a.width * a.height
        let bArea = b.width * b.height
        let unionArea = aArea + bArea - interArea
        return unionArea > 0 ? interArea / unionArea : 0
    }

    /// Maps a normalized rect detected in an image that was produced by applying
    /// [orientation] to the raw buffer, back into the raw buffer's normalized
    /// (unrotated) space.
    private func unrotateNormalizedRect(_ r: CGRect, from orientation: CGImagePropertyOrientation) -> CGRect {
        switch orientation {
        case .right: // raw rotated 90° CW to make the detection image
            return CGRect(x: r.origin.y, y: 1 - (r.origin.x + r.size.width), width: r.size.height, height: r.size.width)
        case .left: // raw rotated 90° CCW
            return CGRect(x: 1 - (r.origin.y + r.size.height), y: r.origin.x, width: r.size.height, height: r.size.width)
        case .down: // 180°
            return CGRect(x: 1 - (r.origin.x + r.size.width), y: 1 - (r.origin.y + r.size.height), width: r.size.width, height: r.size.height)
        default: // .up — no rotation
            return r
        }
    }

    private func runSubjectDetectionIfNeeded(on pixelBuffer: CVPixelBuffer) {
        guard detectionEnabled, detectionEventSink != nil, !isProcessingDetection else { return }

        let now = CACurrentMediaTime()
        guard now - lastDetectionTime >= detectionMinInterval else { return }
        lastDetectionTime = now

        guard ensureDetector() != nil else { return }
        isProcessingDetection = true
        defer { isProcessingDetection = false }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return }

        // Downscale before detection — the model input is ~320px, so running it
        // on full photo-resolution frames is the main cost. Normalized box coords
        // are unaffected by uniform scaling.
        var baseCI = CIImage(cvPixelBuffer: pixelBuffer)
        let longestSide = max(baseCI.extent.width, baseCI.extent.height)
        if longestSide > detectionMaxSide {
            let s = detectionMaxSide / longestSide
            baseCI = baseCI.transformed(by: CGAffineTransform(scaleX: s, y: s))
        }

        // Try candidate rotations (last winner first) until a car is found. The
        // box is mapped back to the raw buffer's coordinate space so the native
        // preview conversion draws it correctly regardless of how it was found.
        var rawRect: CGRect?
        var label = "car"
        var confidence = 0.0
        // While actively tracking, only re-check the last winning orientation (1
        // inference). Do the full multi-orientation search only when acquiring
        // (no box held) — this avoids a 4x inference spike on every missed frame.
        var order = [lastSuccessfulOrientationIndex]
        if smoothedBox == nil {
            for i in detectionOrientationCandidates.indices where i != lastSuccessfulOrientationIndex {
                order.append(i)
            }
        }
        for idx in order {
            let orientation = detectionOrientationCandidates[idx]
            let image = (orientation == .up) ? baseCI : baseCI.oriented(orientation)
            if let found = selectPrimaryCar(in: image) {
                rawRect = unrotateNormalizedRect(found.rect, from: orientation)
                label = found.label
                confidence = found.confidence
                lastSuccessfulOrientationIndex = idx
                break
            }
        }

        // Clamp to [0,1].
        let foundRect: CGRect? = rawRect.map { r in
            let l = min(max(r.minX, 0), 1)
            let t = min(max(r.minY, 0), 1)
            let rr = min(max(r.maxX, 0), 1)
            let bb = min(max(r.maxY, 0), 1)
            return CGRect(x: l, y: t, width: max(0, rr - l), height: max(0, bb - t))
        }

        // Temporal smoothing: EMA toward the new box; hold the last box through a
        // short run of empty frames so it doesn't flicker.
        let displayRect: CGRect?
        if let target = foundRect {
            detectionMissCount = 0
            if let prev = smoothedBox {
                let f = detectionSmoothingFactor
                smoothedBox = CGRect(
                    x: prev.minX + (target.minX - prev.minX) * f,
                    y: prev.minY + (target.minY - prev.minY) * f,
                    width: prev.width + (target.width - prev.width) * f,
                    height: prev.height + (target.height - prev.height) * f
                )
            } else {
                smoothedBox = target
            }
            displayRect = smoothedBox
        } else {
            detectionMissCount += 1
            if detectionMissCount > detectionMaxMissFrames {
                smoothedBox = nil
            }
            displayRect = smoothedBox
        }

        var detections: [[String: Any]] = []
        if let r = displayRect {
            detections.append([
                "left": Double(r.minX),
                "top": Double(r.minY),
                "right": Double(r.maxX),
                "bottom": Double(r.maxY),
                "label": label,
                "confidence": confidence
            ])
        }

        let basePayload: [String: Any] = [
            "imageWidth": width,
            "imageHeight": height,
            "isMirrored": false,
            "detections": detections
        ]
        let isDetected = (displayRect != nil)

        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.isDeinitializing else { return }
            // Draw the overlays (box + ground guide) and get the framing state,
            // computed against the actual preview bounds, then report to Dart.
            let state = self.updateNativeOverlays(metadataRect: displayRect)
            var payload = basePayload
            payload["isDetected"] = isDetected
            payload["isCropped"] = state.cropped
            payload["croppedSides"] = state.croppedSides
            payload["hasEnoughGround"] = state.hasEnoughGround
            self.detectionEventSink?(payload)
        }
    }

    /// Draws the native overlays (bounding box + ground guide) using the preview
    /// layer's own coordinate conversion (handles the aspect-fill crop), and
    /// returns the framing state. Main thread only.
    /// - `cropped`: the car touches a preview edge.
    /// - `croppedSides`: which edges it touches, in the fixed display (portrait)
    ///   frame — "left"/"right" are the frame's short edges, "top"/"bottom" its
    ///   long-side edges, regardless of how the phone is held (see CropSide in Dart).
    /// - `hasEnoughGround`: enough ground beneath the car (true when no car).
    private func updateNativeOverlays(metadataRect: CGRect?) -> (cropped: Bool, croppedSides: [String], hasEnoughGround: Bool) {
        guard let previewLayer = _hostView.previewLayer, let mRect = metadataRect else {
            _hostView.updateDetectionBox(rect: nil, color: .clear)
            _hostView.updateGroundGuide(maskPath: nil, color: .clear, startPoint: .zero, endPoint: .zero)
            return (false, [], true)
        }
        let layerRect = previewLayer.layerRectConverted(fromMetadataOutputRect: mRect)
        let b = previewLayer.bounds
        let margin = min(b.width, b.height) * 0.02
        var sides: [String] = []
        if layerRect.minX <= b.minX + margin { sides.append("left") }
        if layerRect.minY <= b.minY + margin { sides.append("top") }
        if layerRect.maxX >= b.maxX - margin { sides.append("right") }
        if layerRect.maxY >= b.maxY - margin { sides.append("bottom") }
        let cropped = !sides.isEmpty
        let purple = UIColor(red: 0x6E / 255.0, green: 0x23 / 255.0, blue: 0xFE / 255.0, alpha: 1.0)
        let red = UIColor(red: 1.0, green: 0x3B / 255.0, blue: 0x30 / 255.0, alpha: 1.0)

        // Bounding box (optional).
        if showDetectionBox {
            _hostView.updateDetectionBox(rect: layerRect, color: cropped ? red : purple)
        } else {
            _hostView.updateDetectionBox(rect: nil, color: .clear)
        }

        // Ground guide: a translucent band running from the ground-side edge
        // toward the car. It laps `groundGuideOverlap` of the box into the car,
        // fades out (gradient) as it meets the car instead of a hard cutoff, and
        // punches the car region out (even-odd) so it never covers the car.
        // `gap`/`dim` drive the enough-ground check (actual clearance, edge->car).
        let strip: CGRect
        let gap: CGFloat
        let dim: CGFloat
        let startPoint: CGPoint
        let endPoint: CGPoint
        switch groundGuideEdge {
        case "top":
            let ov = groundGuideOverlap * layerRect.height
            let inner = min(layerRect.minY + ov, b.maxY)
            strip = CGRect(x: b.minX, y: b.minY, width: b.width, height: max(0, inner - b.minY))
            gap = layerRect.minY - b.minY
            dim = b.height
            startPoint = CGPoint(x: 0.5, y: 0.0)
            endPoint = CGPoint(x: 0.5, y: (inner - b.minY) / b.height)
        case "left":
            let ov = groundGuideOverlap * layerRect.width
            let inner = min(layerRect.minX + ov, b.maxX)
            strip = CGRect(x: b.minX, y: b.minY, width: max(0, inner - b.minX), height: b.height)
            gap = layerRect.minX - b.minX
            dim = b.width
            startPoint = CGPoint(x: 0.0, y: 0.5)
            endPoint = CGPoint(x: (inner - b.minX) / b.width, y: 0.5)
        case "right":
            let ov = groundGuideOverlap * layerRect.width
            let inner = max(layerRect.maxX - ov, b.minX)
            strip = CGRect(x: inner, y: b.minY, width: max(0, b.maxX - inner), height: b.height)
            gap = b.maxX - layerRect.maxX
            dim = b.width
            startPoint = CGPoint(x: 1.0, y: 0.5)
            endPoint = CGPoint(x: (inner - b.minX) / b.width, y: 0.5)
        default: // bottom
            let ov = groundGuideOverlap * layerRect.height
            let inner = max(layerRect.maxY - ov, b.minY)
            strip = CGRect(x: b.minX, y: inner, width: b.width, height: max(0, b.maxY - inner))
            gap = b.maxY - layerRect.maxY
            dim = b.height
            startPoint = CGPoint(x: 0.5, y: 1.0)
            endPoint = CGPoint(x: 0.5, y: (inner - b.minY) / b.height)
        }
        let hole = strip.intersection(layerRect)
        let hasEnoughGround = dim > 0 && (gap / dim) >= groundGuideMinFraction
        if showGroundGuide && strip.width > 0 && strip.height > 0 {
            let base = hasEnoughGround ? purple : red
            let path = UIBezierPath(rect: strip)
            if !hole.isNull && hole.width > 0 && hole.height > 0 {
                // Round the hole's corners that sit on the car's ground-side edge
                // so the punched-out region follows the box's rounded corners
                // (cornerRadius 10 in updateDetectionBox) instead of cutting a
                // sharp corner. The inner cut stays square.
                let boxCornerRadius: CGFloat = 10
                let holeCorners: UIRectCorner
                switch groundGuideEdge {
                case "top":   holeCorners = [.topLeft, .topRight]
                case "left":  holeCorners = [.topLeft, .bottomLeft]
                case "right": holeCorners = [.topRight, .bottomRight]
                default:      holeCorners = [.bottomLeft, .bottomRight] // bottom
                }
                let r = min(boxCornerRadius, min(hole.width, hole.height) / 2)
                let holePath = UIBezierPath(
                    roundedRect: hole,
                    byRoundingCorners: holeCorners,
                    cornerRadii: CGSize(width: r, height: r)
                )
                path.append(holePath) // punched out by even-odd fill rule
            }
            _hostView.updateGroundGuide(maskPath: path.cgPath, color: base, startPoint: startPoint, endPoint: endPoint)
        } else {
            _hostView.updateGroundGuide(maskPath: nil, color: .clear, startPoint: .zero, endPoint: .zero)
        }

        return (cropped, sides, hasEnoughGround)
    }

    // MARK: - FlutterStreamHandler (detection EventChannel)

    func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        self.detectionEventSink = events
        print("[CameraPlatformView-\(viewId)] Detection EventChannel listener attached.")
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        self.detectionEventSink = nil
        print("[CameraPlatformView-\(viewId)] Detection EventChannel listener cancelled.")
        return nil
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !isDeinitializing else { return }
    }
    

    private func setTargetRotationNative(rotation: Int, result: @escaping FlutterResult) {
        let orientation: AVCaptureVideoOrientation
        switch rotation {
        case 0: orientation = .portrait
        case 90: orientation = .landscapeRight
        case 180: orientation = .portraitUpsideDown
        case 270: orientation = .landscapeLeft
        default: orientation = .portrait
        }
        self.currentPhotoOrientation = orientation
        
        // Apply to the photo output connection immediately if available
        sessionQueue.async { [weak self] in
            guard let strongSelf = self else { return }
            if let connection = strongSelf.photoOutput?.connection(with: .video),
               connection.isVideoOrientationSupported {
                connection.videoOrientation = orientation
            }
            DispatchQueue.main.async { result(nil) }
        }
    }

    private func setZoomNative(zoomFactor: CGFloat, result: @escaping FlutterResult) {
        sessionQueue.async { [weak self] in
            guard let strongSelf = self,
                  let device = strongSelf.currentCameraInput?.device else {
                DispatchQueue.main.async { result(FlutterError(code: "NO_CAMERA", message: "Camera not initialized", details: nil)) }
                return
            }
            do {
                try device.lockForConfiguration()
                let maxZoom = min(device.activeFormat.videoMaxZoomFactor, 20.0) // Cap at 20x for safety
                let minZoom: CGFloat = 1.0
                device.videoZoomFactor = max(minZoom, min(zoomFactor, maxZoom))
                device.unlockForConfiguration()
                DispatchQueue.main.async { result(nil) }
            } catch {
                DispatchQueue.main.async { result(FlutterError(code: "ZOOM_FAILED", message: "Failed to set zoom: \(error.localizedDescription)", details: nil)) }
            }
        }
    }

    private func getMaxZoomNative(result: @escaping FlutterResult) {
        sessionQueue.async { [weak self] in
            guard let strongSelf = self,
                  let device = strongSelf.currentCameraInput?.device else {
                DispatchQueue.main.async { result(1.0) }
                return
            }
            let maxZoom = min(Double(device.activeFormat.videoMaxZoomFactor), 20.0)
            DispatchQueue.main.async { result(maxZoom) }
        }
    }

    private func getMinZoomNative(result: @escaping FlutterResult) {
        DispatchQueue.main.async { result(1.0) }
    }
    deinit {
        isDeinitializing = true
        NotificationCenter.default.removeObserver(self)
        diag("deinit", "tearing down view")
        let currentViewId = self.viewId
        print("[CameraPlatformView-\(currentViewId)] DEINIT: Running on thread: \(Thread.current)")
        print("[CameraPlatformView-\(currentViewId)] DEINIT: Starting the deallocation process.")

        let capturedSession = self.captureSession
        let capturedPhotoOutput = self.photoOutput
        let capturedVideoDataOutput = self.videoDataOutput // Strong reference to the output
        let capturedCurrentCameraInput = self.currentCameraInput
        let capturedMethodChannel = self.methodChannel
        let capturedEventChannel = self.detectionEventChannel

        // All AVFoundation cleanup runs on sessionQueue. We use ASYNC (not sync) with
        // captured locals because deinit may itself be running ON sessionQueue (when the
        // last strong ref is released inside a sessionQueue.async block). A sync dispatch
        // to the current queue would deadlock. The captured locals keep the AV objects
        // alive until the async block completes.
        print("[CameraPlatformView-\(currentViewId)] DEINIT: Dispatching all AVFoundation cleanup to sessionQueue (ASYNC)...")
        self.sessionQueue.async { // ASYNC to avoid deadlock if deinit runs on sessionQueue
            print("[CameraPlatformView-\(currentViewId)] DEINIT: (sessionQueue.async) Starting AVFoundation cleanup...")

            // 1. Stop the session
            if capturedSession?.isRunning ?? false {
                capturedSession?.stopRunning()
                print("[CameraPlatformView-\(currentViewId)] DEINIT: (sessionQueue.sync) Session stopped.")
            } else {
                print("[CameraPlatformView-\(currentViewId)] DEINIT: (sessionQueue.sync) Session not running or already nil.")
            }

            // 2. Remove I/O from the session
            if let session = capturedSession {
                if let photoOut = capturedPhotoOutput, session.outputs.contains(photoOut) {
                    session.removeOutput(photoOut)
                    print("[CameraPlatformView-\(currentViewId)] DEINIT: (sessionQueue.sync) PhotoOutput removed.")
                }
                if let videoOut = capturedVideoDataOutput, session.outputs.contains(videoOut) {
                    session.removeOutput(videoOut) // Remove the output from the session
                    print("[CameraPlatformView-\(currentViewId)] DEINIT: (sessionQueue.sync) VideoDataOutput removed from session.")

                    // 3. Remove the VideoDataOutput delegate AFTER removing it from the session
                    //    And do it on this same sessionQueue (or videoDataOutputQueue if you prefer, but sessionQueue seems more reasonable for managing the output's lifecycle)
                    //    No separate dispatch onto videoDataOutputQueue is needed when done here.
                    videoOut.setSampleBufferDelegate(nil, queue: nil)
                    print("[CameraPlatformView-\(currentViewId)] DEINIT: (sessionQueue.sync) VideoDataOutput delegate removed (nil).")
                }
                if let camInput = capturedCurrentCameraInput, session.inputs.contains(camInput) {
                    session.removeInput(camInput)
                    print("[CameraPlatformView-\(currentViewId)] DEINIT: (sessionQueue.sync) CameraInput removed.")
                }
            } else {
                print("[CameraPlatformView-\(currentViewId)] DEINIT: (sessionQueue.sync) Session already nil, not removing I/O.")
            }
            print("[CameraPlatformView-\(currentViewId)] DEINIT: (sessionQueue.sync) AVFoundation cleanup finished.")
        } // End of sessionQueue.sync

        // Remove the method channel handler asynchronously on the main thread
        DispatchQueue.main.async {
            capturedMethodChannel?.setMethodCallHandler(nil)
            capturedEventChannel?.setStreamHandler(nil)
            print("[CameraPlatformView-\(currentViewId)] DEINIT: Method/Event channel handlers removed (async).")
        }

        // Set the properties to nil to release the strong references
        // The AVFoundation objects were captured and handled in sessionQueue.sync
        self.captureSession = nil
        self.photoOutput = nil
        self.videoDataOutput = nil // This property will be released by ARC after capturedVideoDataOutput goes out of scope
        self.currentCameraInput = nil
        self.methodChannel = nil
        self.detectionEventChannel = nil
        self.detectionEventSink = nil
        self.pendingPhotoCaptureResult = nil
        self.lastFrameAsUIImage = nil

        print("[CameraPlatformView-\(currentViewId)] DEINIT: Completed the deallocation process (synchronous part).")
    }
}

private extension Double {
    /// Clamps the value into the normalized 0.0...1.0 range.
    func clamped01() -> Double {
        return Swift.max(0.0, Swift.min(1.0, self))
    }
}
