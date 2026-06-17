// File: ios/Runner/SwiftCameraPreview.swift
import Flutter
import UIKit
import AVFoundation

// Lớp UIView tùy chỉnh để quản lý frame của previewLayer
class CameraHostView: UIView {
    var previewLayer: AVCaptureVideoPreviewLayer?
    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = self.bounds
    }
    deinit {
        print("[CameraHostView-\(ObjectIdentifier(self))] DEINIT: Dọn dẹp previewLayer.")
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
    AVCapturePhotoCaptureDelegate, AVCaptureVideoDataOutputSampleBufferDelegate
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

    private var videoDataOutput: AVCaptureVideoDataOutput?
    private let videoDataOutputQueue = DispatchQueue(label: "com.plugin.camera_native.native_camera_view.videoDataOutputQueue.view-\(UUID().uuidString)", qos: .userInitiated)
    private var lastFrameAsUIImage: UIImage?
    private lazy var ciContext = CIContext()
    


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
        }
        
        self.methodChannel = FlutterMethodChannel(
            name: "com.plugin.camera_native.native_camera_view/camera_method_channel_ios_\(viewId)",
            binaryMessenger: messenger
        )
        super.init()

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
    }

    func view() -> UIView { return _hostView }

    private func checkCameraPermissionsAndSetup() {
        print("[CameraPlatformView-\(viewId)] checkCameraPermissionsAndSetup CALLED")
        guard !isDeinitializing else {
            print("[CameraPlatformView-\(viewId)] checkCameraPermissionsAndSetup: Instance is deinitializing, aborting.")
            return
        }

        //  Kiểm tra biến bypass trước tiên
        if bypassPermissionCheck {
            print("[CameraPlatformView-\(viewId)] Permission check is BYPASSED. Proceeding directly to setup.")
            self.setupCamera()
            return // Thoát khỏi hàm sớm
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            // Quyền đã được cấp, tiếp tục setup camera
            print("[CameraPlatformView-\(viewId)] Permission authorized.")
            self.setupCamera()

        case .notDetermined:
            // Lần đầu tiên hỏi quyền, hệ thống sẽ hiển thị dialog
            print("[CameraPlatformView-\(viewId)] Permission not determined. Requesting...")
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let strongSelf = self, !strongSelf.isDeinitializing else { return }
                DispatchQueue.main.async {
                    if granted {
                        strongSelf.setupCamera()
                    } else {
                        print("[CameraPlatformView-\(strongSelf.viewId)] Permission denied by user on first request.")
                        // Có thể hiển thị một thông báo nhẹ nhàng ở đây nếu muốn, hoặc không làm gì cả
                    }
                }
            }

        case .denied, .restricted:
            // Quyền đã bị từ chối trước đó hoặc bị hạn chế bởi phụ huynh/tổ chức
            print("[CameraPlatformView-\(viewId)] Permission denied previously or is restricted.")

            // HIỂN THỊ THÔNG BÁO NATIVE
            self.showPermissionDeniedAlert()

            // (Không cần gửi lỗi về Flutter nữa nếu đã hiển thị thông báo ở đây)
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

            var configurationSuccess = true
            var setupError: Error? // Biến để lưu lỗi nếu có

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
                setupError = error // Lưu lại lỗi
                configurationSuccess = false
            }

            newSession.commitConfiguration()
            print("[CameraPlatformView-\(viewId)] setupCamera: newSession.commitConfiguration() called. configurationSuccess: \(configurationSuccess)")

            guard configurationSuccess else {
                print("[CameraPlatformView-\(viewId)] setupCamera: Configuration failed. Cleaning up and sending error to Flutter.")
                // Gửi tín hiệu lỗi về Flutter
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
                }
            } else {
                print("[CameraPlatformView-\(viewId)] setupCamera: Camera manually paused, not starting session for \(targetLens).")
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

                // Gửi tín hiệu camera sẵn sàng về Flutter
                sSelf.methodChannel?.invokeMethod("onCameraReady", arguments: nil)
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

        // Nếu camera đã ở đúng vị trí và session đang chạy thì không cần làm gì
        if self.currentCameraPosition == newPosition && (self.captureSession?.isRunning ?? false) {
            print("[CameraPlatformView-\(viewId)] Camera is already in the requested position and running.")
            result(nil)
            return
        }

        // Cập nhật vị trí camera mong muốn
        self.currentCameraPosition = newPosition
        
        // Gọi lại setupCamera để cấu hình lại toàn bộ session với camera mới.
        // Hàm setupCamera đã được thiết kế để dọn dẹp session cũ một cách an toàn.
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
            
            // 1. Lấy CGImage thô đã lưu
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
                
                // 2. CROP ẢNH THÔ TRƯỚC (nếu là chế độ 'cover')
                if fitModeForCrop == "cover" {
                    print("[CameraPlatformView-\(localViewId)] Paused capture in 'cover' mode. Cropping first.")
                    var normalizedCropRect = CGRect(x: 0, y: 0, width: 1, height: 1)
                    if let previewLayer = strongSelf._hostView.previewLayer {
                        normalizedCropRect = previewLayer.metadataOutputRectConverted(fromLayerRect: previewLayer.bounds)
                    }
                    
                    // Chuyển đổi normalized rect thành pixel rect
                    let originalWidth = CGFloat(sourceCGImage.width)
                    let originalHeight = CGFloat(sourceCGImage.height)
                    let pixelCropRect = CGRect(
                        x: normalizedCropRect.origin.x * originalWidth,
                        y: normalizedCropRect.origin.y * originalHeight,
                        width: normalizedCropRect.size.width * originalWidth,
                        height: normalizedCropRect.size.height * originalHeight
                    )
                    
                    // Thực hiện crop
                    if let croppedCGImage = sourceCGImage.cropping(to: pixelCropRect) {
                        cgImageToProcess = croppedCGImage
                        print("[CameraPlatformView-\(localViewId)] Cropping successful.")
                    } else {
                        print("[CameraPlatformView-\(localViewId)] Cropping failed, will use un-cropped image.")
                    }
                }
                
                // 3. BIẾN ĐỔI ẢNH ĐÃ CROP (hoặc ảnh gốc nếu không crop)
                var finalImage: UIImage?
                
                if strongSelf.currentCameraPosition == .front {
                    // Đối với camera trước, xoay, lật ngang và lật dọc
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
                    
                } else { // Camera sau
                    finalImage = UIImage(cgImage: cgImageToProcess, scale: 1.0, orientation: .right)
                }
                
                // 4. LƯU ẢNH CUỐI CÙNG
                guard let imageToSave = finalImage else {
                    result(FlutterError(code: "PROCESS_FAILED", message: "Failed to create final UIImage.", details: nil))
                    return
                }
                
                strongSelf.saveImageDataAndReturnPath(imageToSave.jpegData(compressionQuality: 0.9), viewId: localViewId, resultCallback: result)
            }
            return // Kết thúc sớm vì đã xử lý bất đồng bộ
        }

            // Live capture (không pause)
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
                print("[CameraPlatformView-\(self.viewId)] Không tìm thấy root view controller để hiển thị thông báo.")
                return
            }

            let title = "Camera Access Denied"
            let message = "Please go to Settings to grant camera access for the application."

            let alertController = UIAlertController(title: title, message: message, preferredStyle: .alert)

            // Thêm nút "Mở Cài đặt" để đưa người dùng đến thẳng cài đặt của ứng dụng
            let settingsAction = UIAlertAction(title: "Open Settings", style: .default) { _ in
                guard let settingsUrl = URL(string: UIApplication.openSettingsURLString) else { return }
                if UIApplication.shared.canOpenURL(settingsUrl) {
                    UIApplication.shared.open(settingsUrl)
                }
            }
            alertController.addAction(settingsAction)

            // Thêm nút "Đóng"
            let closeAction = UIAlertAction(title: "Close", style: .cancel, handler: nil)
            alertController.addAction(closeAction)

            // Hiển thị thông báo
            rootViewController.present(alertController, animated: true, completion: nil)
        }
    }
    
    private func processAndSaveImage(originalImage: UIImage,
                                     normalizedCropRect: CGRect,
                                     shouldCropBasedOnRect: Bool,
                                     viewId: Int64,
                                     resultCallback: @escaping FlutterResult) {
        // Thực hiện crop và lưu trên background thread để không block UI
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let strongSelf = self else {
                // Instance 'self' đã bị giải phóng trước khi kịp xử lý và lưu.
                DispatchQueue.main.async {
                    resultCallback(FlutterError(code: "INSTANCE_GONE_SAVE", message: "Instance deallocated before image could be processed/saved.", details: nil))
                }
                return
            }

            var imageToSave = originalImage
            var performActualCrop = false

            // Chỉ crop nếu được yêu cầu VÀ hình chữ nhật crop hợp lệ/không phải là toàn bộ ảnh
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
            
            // Lưu ảnh cuối cùng (đã crop hoặc ảnh gốc)
            strongSelf.saveImageDataAndReturnPath(imageToSave.jpegData(compressionQuality: 0.9), viewId: viewId, resultCallback: resultCallback)
        }
    }
    
    // Hàm trợ giúp để lưu ảnh và trả kết quả về Flutter
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
                // Nếu không có pending result, có thể là một capture không mong muốn, bỏ qua.
                print("[CameraPlatformView-\(viewId)] photoOutput called without a pending result callback.")
                return
            }
            self.pendingPhotoCaptureResult = nil // Luôn dọn dẹp callback
            
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

            // Logic crop cho ảnh live vẫn được giữ nguyên
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
        isCameraPausedManually = true
        
        // Khi pause, chúng ta sẽ dừng session. `lastPausedFrameImage` vẫn sẽ được giữ lại.
        // Logic unbindAll không cần thiết vì setupCamera khi resume sẽ xử lý việc đó.
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
        guard !isDeinitializing else {
            result(FlutterError(code: "INSTANCE_GONE", message: "Resuming on deinitializing instance", details: nil))
            return
        }
        
        isCameraPausedManually = false
        
        // Khi resume, thay vì chỉ start lại session cũ, hãy gọi lại setupCamera.
        // Điều này đảm bảo tất cả các use case (Preview, ImageCapture, VideoDataOutput) được bind lại đúng cách.
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

        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        
        // Chỉ lưu lại CGImage thô, không thực hiện bất kỳ phép biến đổi nào ở đây
        self.lastPausedFrameCGImage = self.ciContext.createCGImage(ciImage, from: ciImage.extent)
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
        let currentViewId = self.viewId
        print("[CameraPlatformView-\(currentViewId)] DEINIT: Running on thread: \(Thread.current)")
        print("[CameraPlatformView-\(currentViewId)] DEINIT: Bắt đầu quá trình giải phóng.")

        let capturedSession = self.captureSession
        let capturedPhotoOutput = self.photoOutput
        let capturedVideoDataOutput = self.videoDataOutput // Tham chiếu mạnh đến output
        let capturedCurrentCameraInput = self.currentCameraInput
        let capturedMethodChannel = self.methodChannel

        // Tất cả thao tác dọn dẹp AVFoundation nên được đưa lên sessionQueue và thực hiện đồng bộ
        // để đảm bảo chúng hoàn tất trước khi deinit kết thúc.
        print("[CameraPlatformView-\(currentViewId)] DEINIT: Dispatching all AVFoundation cleanup to sessionQueue (SYNC)...")
        self.sessionQueue.sync { // SYNC block lớn cho tất cả AVFoundation cleanup
            print("[CameraPlatformView-\(currentViewId)] DEINIT: (sessionQueue.sync) Starting AVFoundation cleanup...")

            // 1. Dừng session
            if capturedSession?.isRunning ?? false {
                capturedSession?.stopRunning()
                print("[CameraPlatformView-\(currentViewId)] DEINIT: (sessionQueue.sync) Session đã dừng.")
            } else {
                print("[CameraPlatformView-\(currentViewId)] DEINIT: (sessionQueue.sync) Session không chạy hoặc đã nil.")
            }

            // 2. Gỡ bỏ I/O khỏi session
            if let session = capturedSession {
                if let photoOut = capturedPhotoOutput, session.outputs.contains(photoOut) {
                    session.removeOutput(photoOut)
                    print("[CameraPlatformView-\(currentViewId)] DEINIT: (sessionQueue.sync) PhotoOutput removed.")
                }
                if let videoOut = capturedVideoDataOutput, session.outputs.contains(videoOut) {
                    session.removeOutput(videoOut) // Gỡ output khỏi session
                    print("[CameraPlatformView-\(currentViewId)] DEINIT: (sessionQueue.sync) VideoDataOutput removed from session.")

                    // 3. Gỡ delegate của VideoDataOutput SAU KHI đã gỡ nó khỏi session
                    //    Và thực hiện trên cùng sessionQueue này (hoặc videoDataOutputQueue nếu bạn muốn, nhưng sessionQueue có vẻ hợp lý hơn cho việc quản lý vòng đời output)
                    //    Không cần dispatch riêng lên videoDataOutputQueue nữa nếu làm ở đây.
                    videoOut.setSampleBufferDelegate(nil, queue: nil)
                    print("[CameraPlatformView-\(currentViewId)] DEINIT: (sessionQueue.sync) Delegate của VideoDataOutput đã gỡ (nil).")
                }
                if let camInput = capturedCurrentCameraInput, session.inputs.contains(camInput) {
                    session.removeInput(camInput)
                    print("[CameraPlatformView-\(currentViewId)] DEINIT: (sessionQueue.sync) CameraInput removed.")
                }
            } else {
                print("[CameraPlatformView-\(currentViewId)] DEINIT: (sessionQueue.sync) Session đã nil, không gỡ I/O.")
            }
            print("[CameraPlatformView-\(currentViewId)] DEINIT: (sessionQueue.sync) AVFoundation cleanup finished.")
        } // Kết thúc sessionQueue.sync

        // Hủy method channel handler không đồng bộ trên main thread
        DispatchQueue.main.async {
            capturedMethodChannel?.setMethodCallHandler(nil)
            print("[CameraPlatformView-\(currentViewId)] DEINIT: MethodChannel handler đã gỡ (async).")
        }

        // Gán nil cho các property để giải phóng tham chiếu mạnh
        // Các đối tượng AVFoundation đã được captured và xử lý trong sessionQueue.sync
        self.captureSession = nil
        self.photoOutput = nil
        self.videoDataOutput = nil // Property này sẽ được ARC giải phóng sau khi capturedVideoDataOutput ra khỏi scope
        self.currentCameraInput = nil
        self.methodChannel = nil
        self.pendingPhotoCaptureResult = nil
        self.lastFrameAsUIImage = nil

        print("[CameraPlatformView-\(currentViewId)] DEINIT: Hoàn tất quá trình giải phóng (synchronous part).")
    }
}
