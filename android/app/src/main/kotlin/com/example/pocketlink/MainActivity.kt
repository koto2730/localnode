package com.example.pocketlink

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import android.os.Environment

class MainActivity: FlutterActivity() {
    private val CHANNEL = "com.example.pocketlink/storage"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler {
            call, result ->
            if (call.method == "getDownloadsDirectory") {
                val downloadsPath = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS)?.absolutePath
                if (downloadsPath != null) {
                    result.success(downloadsPath)
                } else {
                    result.error("UNAVAILABLE", "Downloads directory not available.", null)
                }
            } else {
                result.notImplemented()
            }
        }
    }
}
