package com.plugin.camera_native.native_camera_view

import androidx.annotation.NonNull // IMPORTANT: Import for @NonNull
// import androidx.lifecycle.DefaultLifecycleObserver // Not needed unless used directly
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding

class NativeCameraViewPlugin : FlutterPlugin, ActivityAware {
  private var flutterPluginBinding: FlutterPlugin.FlutterPluginBinding? = null
  private var activityPluginBinding: ActivityPluginBinding? = null
  private var cameraPreviewFactory: CameraPreviewFactory? = null

  private val viewType = "com.plugin.camera_native.native_camera_view/camera_preview_android"

  override fun onAttachedToEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
    print("NativeCameraViewPlugin: onAttachedToEngine")
    this.flutterPluginBinding = binding

  }

  override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
    print("NativeCameraViewPlugin: onDetachedFromEngine")
    this.flutterPluginBinding = null
  }

  // --- ActivityAware Lifecycle Methods ---
  override fun onAttachedToActivity(binding: ActivityPluginBinding) {
    print("NativeCameraViewPlugin: onAttachedToActivity - Registering CameraPreviewFactory")
    this.activityPluginBinding = binding
    // val activityLifecycle = FlutterLifecycleAdapter.getActivityLifecycle(binding.lifecycle) // Get the lifecycle from the activity

    val messenger = flutterPluginBinding?.binaryMessenger
    if (messenger == null) {
      print("NativeCameraViewPlugin: ERROR - BinaryMessenger is null in onAttachedToActivity. Cannot register factory.")
      return
    }

    val activity = binding.activity
    if (activity !is LifecycleOwner) {
      print("NativeCameraViewPlugin: ERROR - Activity is not a LifecycleOwner. Cannot register factory.")
      return
    }

    // Create and register the factory
    // The activity is the LifecycleOwner required by CameraPreviewFactory
    cameraPreviewFactory = CameraPreviewFactory(messenger, activity)
    flutterPluginBinding?.platformViewRegistry?.registerViewFactory(
      viewType, // Use the defined viewType
      cameraPreviewFactory!! // Use !! since we just created it
    )
    print("NativeCameraViewPlugin: CameraPreviewFactory registered successfully with viewType: $viewType")
  }

  override fun onDetachedFromActivityForConfigChanges() {
    print("NativeCameraViewPlugin: onDetachedFromActivityForConfigChanges")
    // Call onDetachedFromActivity to clean up
    onDetachedFromActivity()
  }

  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
    print("NativeCameraViewPlugin: onReattachedToActivityForConfigChanges")
    // Call onAttachedToActivity again to re-register the factory
    onAttachedToActivity(binding)
  }

  override fun onDetachedFromActivity() {
    print("NativeCameraViewPlugin: onDetachedFromActivity - Cleaning up")
    this.activityPluginBinding = null
    // this.activityLifecycle = null // Not needed unless stored
    this.cameraPreviewFactory = null // Remove the reference to the factory
    print("NativeCameraViewPlugin: Cleaned up activity attachments.")
  }
}
