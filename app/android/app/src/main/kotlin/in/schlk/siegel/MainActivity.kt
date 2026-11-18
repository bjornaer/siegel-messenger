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
                // Sharing a location: [latitude, longitude, accuracy in m], or null (no permission,
                // location off, or no fix within 30 s). Approximate only is fine.
                "location" -> {
                    val fine = android.Manifest.permission.ACCESS_FINE_LOCATION
                    val coarse = android.Manifest.permission.ACCESS_COARSE_LOCATION
                    if (checkSelfPermission(coarse) == PERMISSION_GRANTED) locate(result) else {
                        locationResult = result
                        requestPermissions(arrayOf(fine, coarse), LOCATION_REQUEST)
                    }
                }
                // Live location: the ongoing notification while it's shared (LiveLocationService).
                "liveStart" -> {
                    startForegroundService(android.content.Intent(this, LiveLocationService::class.java)
                        .putExtra("title", call.arguments as String))
                    result.success(null)
                }
                "liveStop" -> {
                    stopService(android.content.Intent(this, LiveLocationService::class.java))
                    result.success(null)
                }
                // [path]: a video's size (as shown, rotation applied), length and first frame.
                "videoInfo" -> {
                    val path = call.arguments as String
                    Thread {
                        val info = try { videoInfo(path) } catch (e: Exception) { null }
                        runOnUiThread { result.success(info) }
                    }.start()
                }
                // [path, short side, bitrate]: the video re-encoded as H.264/AAC MP4 at most that
                // size, HDR toned down to SDR; the new file's path (in the cache, the app deletes it).
                "transcodeVideo" -> {
                    val (path, side, bitrate) = call.arguments as List<*>
                    transcode(path as String, (side as Number).toInt(), (bitrate as Number).toInt(), result)
                }
                // Uploads under way: the ongoing notification while they go (TransferService).
                "transfersStart" -> {
                    TransferService.start(this, call.arguments as String)
                    result.success(null)
                }
                "transfersStop" -> {
                    TransferService.stop(this)
                    result.success(null)
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
                // [path, mime]: a received file the core decrypted, opened in whatever app handles
                // its type. The core clears those copies at each start.
                "openPath" -> {
                    val (path, mime) = call.arguments as List<*>
                    val uri = androidx.core.content.FileProvider.getUriForFile(
                        this, "$packageName.files", java.io.File(path as String))
                    val view = android.content.Intent(android.content.Intent.ACTION_VIEW)
                        .setDataAndType(uri, mime as String)
                        .addFlags(android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    try {
                        startActivity(android.content.Intent.createChooser(view, null))
                        result.success(null)
                    } catch (e: android.content.ActivityNotFoundException) {
                        result.error("no_app", null, null)
                    }
                }
                // [bytes, name, mime]: a photo straight into Pictures/Siegel, no dialog. Android 10+;
                // false on 9, where that needs a storage permission (the app uses saveFile then).
                "saveToGallery" -> {
                    val (bytes, name, mime) = call.arguments as List<*>
                    if (android.os.Build.VERSION.SDK_INT < android.os.Build.VERSION_CODES.Q) {
                        result.success(false)
                        return@setMethodCallHandler
                    }
                    val values = android.content.ContentValues().apply {
                        put(android.provider.MediaStore.MediaColumns.DISPLAY_NAME, name as String)
                        put(android.provider.MediaStore.MediaColumns.MIME_TYPE, mime as String)
                        put(android.provider.MediaStore.MediaColumns.RELATIVE_PATH, "Pictures/Siegel")
                    }
                    try {
                        val uri = contentResolver.insert(android.provider.MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)!!
                        contentResolver.openOutputStream(uri)!!.use { it.write(bytes as ByteArray) }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("storage", e.message, null)
                    }
                }
                // [path, name, mime]: the system's save dialog, then the file streamed into the
                // chosen place (a 1 GB video never in memory). True once saved, false if cancelled.
                "saveFile" -> {
                    val (path, name, mime) = call.arguments as List<*>
                    saveFrom = path as String
                    saveResult = result
                    startActivityForResult(
                        android.content.Intent(android.content.Intent.ACTION_CREATE_DOCUMENT)
                            .addCategory(android.content.Intent.CATEGORY_OPENABLE)
                            .setType(mime as String)
                            .putExtra(android.content.Intent.EXTRA_TITLE, name as String),
                        SAVE_REQUEST)
                }
                // Stickers received in WhatsApp, newest first: [[name, bytes], ...], or null if the
                // user backs out. The first time, Android's folder screen opens on WhatsApp's
                // sticker folder; the grant is kept, so later imports go straight to the stickers.
                "whatsappStickers" -> {
                    val granted = contentResolver.persistedUriPermissions.firstOrNull { it.isReadPermission }?.uri
                    if (granted != null) readStickerFolder(granted, result) else {
                        stickersResult = result
                        val start = android.provider.DocumentsContract.buildDocumentUri(
                            "com.android.externalstorage.documents", "primary:$WHATSAPP_STICKERS")
                        startActivityForResult(
                            android.content.Intent(android.content.Intent.ACTION_OPEN_DOCUMENT_TREE)
                                .putExtra(android.provider.DocumentsContract.EXTRA_INITIAL_URI, start),
                            STICKERS_REQUEST)
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
    private var stickersResult: MethodChannel.Result? = null

    @Deprecated("FlutterFragmentActivity still routes results here")
    private fun videoInfo(path: String): Map<String, Any> {
        val r = android.media.MediaMetadataRetriever()
        try {
            r.setDataSource(path)
            fun num(key: Int) = r.extractMetadata(key)?.toLongOrNull() ?: 0L
            var w = num(android.media.MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)
            var h = num(android.media.MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)
            val rotation = num(android.media.MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)
            if (rotation == 90L || rotation == 270L) w = h.also { h = w } // as it's shown
            val still = java.io.ByteArrayOutputStream()
            r.getFrameAtTime(0)?.compress(android.graphics.Bitmap.CompressFormat.JPEG, 80, still)
            return mapOf(
                "width" to w, "height" to h,
                "ms" to num(android.media.MediaMetadataRetriever.METADATA_KEY_DURATION),
                "still" to still.toByteArray())
        } finally {
            r.release()
        }
    }

    private fun transcode(src: String, side: Int, bitrate: Int, result: MethodChannel.Result) {
        val out = java.io.File(cacheDir, "video-${System.nanoTime()}.mp4")
        val item = androidx.media3.transformer.EditedMediaItem.Builder(
            androidx.media3.common.MediaItem.fromUri(android.net.Uri.fromFile(java.io.File(src))))
            .setEffects(androidx.media3.transformer.Effects(
                listOf(), listOf(androidx.media3.effect.Presentation.createForShortSide(side))))
            .build()
        val composition = androidx.media3.transformer.Composition.Builder(
            androidx.media3.transformer.EditedMediaItemSequence.Builder(item).build())
            .setHdrMode(androidx.media3.transformer.Composition.HDR_MODE_TONE_MAP_HDR_TO_SDR_USING_OPEN_GL)
            .build()
        val encoders = androidx.media3.transformer.DefaultEncoderFactory.Builder(this)
            .setRequestedVideoEncoderSettings(
                androidx.media3.transformer.VideoEncoderSettings.Builder().setBitrate(bitrate).build())
            .build()
        androidx.media3.transformer.Transformer.Builder(this)
            .setVideoMimeType(androidx.media3.common.MimeTypes.VIDEO_H264)
            .setAudioMimeType(androidx.media3.common.MimeTypes.AUDIO_AAC)
            .setEncoderFactory(encoders)
            .addListener(object : androidx.media3.transformer.Transformer.Listener {
                override fun onCompleted(
                    composition: androidx.media3.transformer.Composition,
                    exportResult: androidx.media3.transformer.ExportResult,
                ) = result.success(out.path)

                override fun onError(
                    composition: androidx.media3.transformer.Composition,
                    exportResult: androidx.media3.transformer.ExportResult,
                    exportException: androidx.media3.transformer.ExportException,
                ) {
                    out.delete()
                    result.error("transcode_failed", exportException.message, null)
                }
            })
            .build()
            .start(composition, out.path)
    }

    private var saveResult: MethodChannel.Result? = null
    private var saveFrom: String? = null

    override fun onActivityResult(code: Int, resultCode: Int, data: android.content.Intent?) {
        super.onActivityResult(code, resultCode, data)
        if (code == SAVE_REQUEST) {
            val result = saveResult ?: return
            val from = saveFrom
            saveResult = null
            val to = data?.data
            if (resultCode != RESULT_OK || to == null || from == null) return result.success(false)
            Thread {
                val ok = try {
                    java.io.File(from).inputStream().use { i ->
                        contentResolver.openOutputStream(to)!!.use { o -> i.copyTo(o, 1 shl 16) }
                    }
                    true
                } catch (e: Exception) {
                    false
                }
                runOnUiThread { if (ok) result.success(true) else result.error("save_failed", null, null) }
            }.start()
            return
        }
        if (code != STICKERS_REQUEST) return
        val result = stickersResult ?: return
        stickersResult = null
        val tree = data?.data
        if (resultCode != RESULT_OK || tree == null) return result.success(null)
        contentResolver.takePersistableUriPermission(tree, android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
        readStickerFolder(tree, result)
    }

    /** The newest WebP files in a granted folder. None there: the grant goes, so next time asks again. */
    private fun readStickerFolder(tree: android.net.Uri, result: MethodChannel.Result) {
        Thread {
            val files = try {
                val docs = android.provider.DocumentsContract.buildChildDocumentsUriUsingTree(
                    tree, android.provider.DocumentsContract.getTreeDocumentId(tree))
                val found = mutableListOf<Triple<String, String, Long>>() // id, name, modified
                val cols = arrayOf(
                    android.provider.DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                    android.provider.DocumentsContract.Document.COLUMN_DISPLAY_NAME,
                    android.provider.DocumentsContract.Document.COLUMN_LAST_MODIFIED,
                    android.provider.DocumentsContract.Document.COLUMN_SIZE)
                contentResolver.query(docs, cols, null, null, null)?.use { c ->
                    while (c.moveToNext()) {
                        val name = c.getString(1) ?: continue
                        if (!name.lowercase().endsWith(".webp") || c.getLong(3) > MAX_STICKER) continue
                        found.add(Triple(c.getString(0), name, c.getLong(2)))
                    }
                }
                found.sortedByDescending { it.third }.take(MAX_STICKERS).mapNotNull { (id, name, _) ->
                    try {
                        val uri = android.provider.DocumentsContract.buildDocumentUriUsingTree(tree, id)
                        contentResolver.openInputStream(uri)?.use { listOf(name, it.readBytes()) }
                    } catch (e: Exception) {
                        null // unreadable: skip it, keep the rest
                    }
                }
            } catch (e: Exception) {
                emptyList() // the folder is gone
            }
            if (files.isEmpty()) {
                try {
                    contentResolver.releasePersistableUriPermission(tree, android.content.Intent.FLAG_GRANT_READ_URI_PERMISSION)
                } catch (e: SecurityException) {}
            }
            runOnUiThread { result.success(files) }
        }.start()
    }
    private var contactsResult: MethodChannel.Result? = null

    override fun onRequestPermissionsResult(code: Int, permissions: Array<out String>, grants: IntArray) {
        super.onRequestPermissionsResult(code, permissions, grants)
        if (code == LOCATION_REQUEST) {
            val result = locationResult ?: return
            locationResult = null
            if (grants.any { it == PERMISSION_GRANTED }) locate(result) else result.success(null)
            return
        }
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
    private var locationResult: MethodChannel.Result? = null

    // A fresh fix from the platform (no Play services); GPS needs the precise permission.
    @Suppress("DEPRECATION", "MissingPermission") // requestSingleUpdate: Android 9 and 10
    private fun locate(result: MethodChannel.Result) {
        val lm = getSystemService(LOCATION_SERVICE) as android.location.LocationManager
        val precise = checkSelfPermission(android.Manifest.permission.ACCESS_FINE_LOCATION) == PERMISSION_GRANTED
        val provider = listOf(android.location.LocationManager.GPS_PROVIDER, android.location.LocationManager.NETWORK_PROVIDER)
            .filter { precise || it != android.location.LocationManager.GPS_PROVIDER }
            .firstOrNull { lm.isProviderEnabled(it) } ?: return result.success(null)
        var done = false
        val reply = { l: android.location.Location? ->
            if (!done) {
                done = true
                result.success(l?.let { listOf(it.latitude, it.longitude, it.accuracy.toDouble()) })
            }
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            lm.getCurrentLocation(provider, null, mainExecutor) { reply(it) } // gives up by itself
        } else {
            val listener = android.location.LocationListener { reply(it) }
            lm.requestSingleUpdate(provider, listener, mainLooper)
            android.os.Handler(mainLooper).postDelayed({
                lm.removeUpdates(listener)
                reply(lm.getLastKnownLocation(provider))
            }, 30_000)
        }
    }

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
        const val LOCATION_REQUEST = 8
        const val STICKERS_REQUEST = 9
        const val SAVE_REQUEST = 10
        const val WHATSAPP_STICKERS = "Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Stickers"
        const val MAX_STICKERS = 120
        const val MAX_STICKER = 1L shl 20 // WhatsApp's are at most 500 KB
        const val PERMISSION_GRANTED = android.content.pm.PackageManager.PERMISSION_GRANTED
    }
}
