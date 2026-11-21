package dev.facetrack.teacher

import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // Keeps the screen on while a classroom scan runs: a screen timeout would pause the app
        // and end the scan.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "dev.facetrack/screen")
            .setMethodCallHandler { call, result ->
                if (call.method == "keepAwake") {
                    val on = call.arguments as? Boolean ?: false
                    if (on) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
    }
}
