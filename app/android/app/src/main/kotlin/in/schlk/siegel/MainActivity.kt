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
                // While recording a voice note: a long one mustn't be cut off by the screen locking.
                "keepOn" -> {
                    if (call.arguments == true) window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                    else window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
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
                // MED-12: auto-download settings differ on metered (mobile) networks.
                "metered" -> result.success(
                    (getSystemService(CONNECTIVITY_SERVICE) as android.net.ConnectivityManager).isActiveNetworkMetered)
                // Phone number entry: the SIM's country (no permission needed) and every country's
                // name in the phone's language, for the country picker.
                "countries" -> {
                    val tm = getSystemService(TELEPHONY_SERVICE) as android.telephony.TelephonyManager
                    val sim = (tm.simCountryIso.takeIf { it.isNotEmpty() } ?: tm.networkCountryIso).uppercase()
                    val names = java.util.Locale.getISOCountries().associateWith {
                        java.util.Locale("", it).getDisplayCountry(java.util.Locale.getDefault())
                    }
                    result.success(mapOf("sim" to sim, "names" to names))
                }
                // Stickers shared to Siegel by another app, once: [[name, bytes], ...].
                "takeShared" -> {
                    result.success(pendingShared)
                    pendingShared = null
                }
                // DISC-08: the link the app was opened with, once.
                "takeLink" -> {
                    result.success(pendingLink)
                    pendingLink = null
                }
                // DISC-04: name and number of every phone contact, or null if the user says no.
                "contacts" -> {
                    if (checkSelfPermission(android.Manifest.permission.READ_CONTACTS) == PERMISSION_GRANTED) {
                        readContacts(result)
                    } else {
                        contactsResult = result
                        requestPermissions(arrayOf(android.Manifest.permission.READ_CONTACTS), CONTACTS_REQUEST)
                    }
                }
                "share" -> {
                    val send = android.content.Intent(android.content.Intent.ACTION_SEND)
                        .setType("text/plain").putExtra(android.content.Intent.EXTRA_TEXT, call.arguments as String)
                    startActivity(android.content.Intent.createChooser(send, null))
                    result.success(null)
                }
                "open" -> {
                    try { // a link in a message: no app may handle it
                        startActivity(android.content.Intent(android.content.Intent.ACTION_VIEW,
                            android.net.Uri.parse(call.arguments as String)))
                        result.success(null)
                    } catch (e: android.content.ActivityNotFoundException) {
                        result.error("no_app", null, null)
                    }
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
    private var contactsResult: MethodChannel.Result? = null

    override fun onRequestPermissionsResult(code: Int, permissions: Array<out String>, grants: IntArray) {
        super.onRequestPermissionsResult(code, permissions, grants)
        if (code != CONTACTS_REQUEST) return
        val result = contactsResult ?: return
        contactsResult = null
        if (grants.firstOrNull() == PERMISSION_GRANTED) readContacts(result) else result.success(null)
    }

    // Off the UI thread: big address books take a moment. Numbers are as typed; Dart normalizes them.
    private fun readContacts(result: MethodChannel.Result) = Thread {
        val list = ArrayList<List<String>>()
        contentResolver.query(
            android.provider.ContactsContract.CommonDataKinds.Phone.CONTENT_URI,
            arrayOf(android.provider.ContactsContract.CommonDataKinds.Phone.DISPLAY_NAME,
                android.provider.ContactsContract.CommonDataKinds.Phone.NUMBER),
            null, null, null,
        )?.use { c ->
            while (c.moveToNext()) list.add(listOf(c.getString(0) ?: "", c.getString(1) ?: ""))
        }
        runOnUiThread { result.success(list) }
    }.start()
    private var appChannel: MethodChannel? = null

    override fun onCreate(savedInstanceState: android.os.Bundle?) {
        if (!readShared(intent)) pendingLink = intent?.dataString
        super.onCreate(savedInstanceState)
    }

    // A link opened while the app runs: hand it to Dart right away.
    override fun onNewIntent(intent: android.content.Intent) {
        super.onNewIntent(intent)
        if (!readShared(intent)) intent.dataString?.let { appChannel?.invokeMethod("link", it) }
    }

    private var pendingShared: List<List<Any>>? = null

    /// Stickers (WebP) or a sticker pack (.wastickers) shared or opened with Siegel. Read off the
    /// UI thread from the sender's content URIs; at most 64 files of 64 MB each.
    @Suppress("DEPRECATION") // the typed getParcelableExtra needs Android 13; we support 9+
    private fun readShared(intent: android.content.Intent?): Boolean {
        val uris: List<android.net.Uri> = when (intent?.action) {
            android.content.Intent.ACTION_SEND -> listOfNotNull(
                intent.getParcelableExtra<android.net.Uri>(android.content.Intent.EXTRA_STREAM))
            android.content.Intent.ACTION_SEND_MULTIPLE ->
                intent.getParcelableArrayListExtra<android.net.Uri>(android.content.Intent.EXTRA_STREAM) ?: emptyList()
            android.content.Intent.ACTION_VIEW -> listOfNotNull(intent.data?.takeIf { it.scheme == "content" || it.scheme == "file" })
            else -> emptyList()
        }
        if (uris.isEmpty()) return false
        Thread {
            val files = uris.take(64).mapNotNull { uri ->
                try {
                    var name = uri.lastPathSegment ?: ""
                    var size = -1L
                    contentResolver.query(uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME,
                        android.provider.OpenableColumns.SIZE), null, null, null)?.use { c ->
                        if (c.moveToFirst()) {
                            name = c.getString(0) ?: name
                            if (!c.isNull(1)) size = c.getLong(1)
                        }
                    }
                    if (size > 64L shl 20) return@mapNotNull null
                    val bytes = contentResolver.openInputStream(uri)?.use { it.readBytes() } ?: return@mapNotNull null
                    listOf(name, bytes)
                } catch (e: Exception) {
                    null // unreadable: skip it, keep the rest
                }
            }
            runOnUiThread {
                val channel = appChannel
                if (channel != null) channel.invokeMethod("shared", files) else pendingShared = files
            }
        }.start()
        return true
    }

    private companion object {
        const val CLOUD_PROJECT = 779364744809L // Google Cloud project linked in Play Console
        const val CONTACTS_REQUEST = 7
        const val PERMISSION_GRANTED = android.content.pm.PackageManager.PERMISSION_GRANTED
    }
}
