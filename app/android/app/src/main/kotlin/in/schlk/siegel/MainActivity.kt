package `in`.schlk.siegel

import android.os.Build
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

// FragmentActivity is required by local_auth (app lock, ID-15).
class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        // ID-15: no chat previews in the recents screen (Android 13+; older versions rely on the Flutter cover).
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) setRecentsScreenshotEnabled(false)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "siegel/window").setMethodCallHandler { call, result ->
            when (call.method) {
                // ID-15 screen security: blocks screenshots, screen recording and recents thumbnails.
                "setSecure" -> {
                    if (call.arguments == true) window.addFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    else window.clearFlags(WindowManager.LayoutParams.FLAG_SECURE)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }
}
