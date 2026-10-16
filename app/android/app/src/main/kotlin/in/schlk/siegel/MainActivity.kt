package `in`.schlk.siegel

import android.os.Build
import android.view.WindowManager
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import com.google.android.play.core.integrity.IntegrityManagerFactory
import com.google.android.play.core.integrity.StandardIntegrityManager.PrepareIntegrityTokenRequest
import com.google.android.play.core.integrity.StandardIntegrityManager.StandardIntegrityTokenRequest
import java.security.MessageDigest

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
        // Update prompt: our build number, and the Play Store page to update from.
        appChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "siegel/app")
        appChannel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "build" -> result.success(packageManager.getPackageInfo(packageName, 0).longVersionCode)
                // DISC-08: the link the app was opened with, once.
                "takeLink" -> {
                    result.success(pendingLink)
                    pendingLink = null
                }
                "share" -> {
                    val send = android.content.Intent(android.content.Intent.ACTION_SEND)
                        .setType("text/plain").putExtra(android.content.Intent.EXTRA_TEXT, call.arguments as String)
                    startActivity(android.content.Intent.createChooser(send, null))
                    result.success(null)
                }
                "openStore" -> {
                    val page = android.net.Uri.parse("https://play.google.com/store/apps/details?id=$packageName")
                    val market = android.content.Intent(android.content.Intent.ACTION_VIEW,
                        android.net.Uri.parse("market://details?id=$packageName"))
                    try { startActivity(market) } catch (e: android.content.ActivityNotFoundException) {
                        startActivity(android.content.Intent(android.content.Intent.ACTION_VIEW, page))
                    }
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
        // ID-02: a Play Integrity token bound to the number being registered. The server checks
        // requestHash == hex(SHA-256(E.164)), so the token can't be used for another number.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "siegel/attest").setMethodCallHandler { call, result ->
            val phone = call.arguments as? String
            if (call.method != "token" || phone == null) return@setMethodCallHandler result.notImplemented()
            val hash = MessageDigest.getInstance("SHA-256").digest(phone.toByteArray()).joinToString("") { "%02x".format(it) }
            val fail = { e: Exception -> result.error("attestation", e.javaClass.simpleName, null) }
            IntegrityManagerFactory.createStandard(applicationContext)
                .prepareIntegrityToken(PrepareIntegrityTokenRequest.builder().setCloudProjectNumber(CLOUD_PROJECT).build())
                .addOnSuccessListener { provider ->
                    provider.request(StandardIntegrityTokenRequest.builder().setRequestHash(hash).build())
                        .addOnSuccessListener { result.success(it.token()) }
                        .addOnFailureListener(fail)
                }
                .addOnFailureListener(fail)
        }
    }

    private var pendingLink: String? = null
    private var appChannel: MethodChannel? = null

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        pendingLink = intent?.dataString
        super.onCreate(savedInstanceState)
    }

    // A link opened while the app runs: hand it to Dart right away.
    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        intent.dataString?.let { appChannel?.invokeMethod("link", it) }
    }

    private companion object {
        const val CLOUD_PROJECT = 779364744809L // Google Cloud project linked in Play Console
    }
}
