package com.example.segwaycontrol

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant

private const val CHANNEL = "segwaycontrol/permissions"
private const val SENSOR_METHOD_CHANNEL = "dev.fluttercommunity.plus/sensors/method"
private const val REQUEST_CODE_PERMISSIONS = 1234

class MainActivity : FlutterActivity() {
  private var pendingResult: MethodChannel.Result? = null

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)

    // Provide a minimal implementation for the sensors method channel.
    // sensors_plus calls setAccelerationSamplingPeriod / setGyroscopeSamplingPeriod
    // etc. If these are unhandled, a MissingPluginException is thrown.
    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, SENSOR_METHOD_CHANNEL)
      .setMethodCallHandler { call, result ->
        when (call.method) {
          "setAccelerationSamplingPeriod",
          "setGyroscopeSamplingPeriod",
          "setUserAccelerometerSamplingPeriod",
          "setMagnetometerSamplingPeriod" -> {
            // No-op: Android sensor sampling is controlled by the plugin's event channel.
            result.success(null)
          }
          else -> result.notImplemented()
        }
      }

    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
      .setMethodCallHandler { call, result ->
        when (call.method) {
          "requestPermissions" -> {
            if (pendingResult != null) {
              result.error("BUSY", "A permission request is already in progress", null)
              return@setMethodCallHandler
            }
            pendingResult = result
            requestPermissionsIfNeeded()
          }
          else -> result.notImplemented()
        }
      }
  }

  private fun requestPermissionsIfNeeded() {
    val permissions = mutableListOf<String>()

    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
      permissions += Manifest.permission.BLUETOOTH_CONNECT
      permissions += Manifest.permission.BLUETOOTH_SCAN
    }
    permissions += Manifest.permission.ACCESS_FINE_LOCATION

    val toRequest = permissions.filter {
      ContextCompat.checkSelfPermission(this, it) != PackageManager.PERMISSION_GRANTED
    }

    if (toRequest.isEmpty()) {
      pendingResult?.success(true)
      pendingResult = null
      return
    }

    ActivityCompat.requestPermissions(this, toRequest.toTypedArray(), REQUEST_CODE_PERMISSIONS)
  }

  override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
    super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    if (requestCode != REQUEST_CODE_PERMISSIONS) return

    val granted = grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }
    pendingResult?.success(granted)
    pendingResult = null
  }
}
