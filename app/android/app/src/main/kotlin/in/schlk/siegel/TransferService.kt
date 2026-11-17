package `in`.schlk.siegel

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build

// While videos and files upload: an ongoing notification that keeps the app running with the
// screen off or another app open. The app does the uploading; this only holds the process up.
// Started from the open app; stopped when the last upload is done.
class TransferService : Service() {
    override fun onBind(intent: Intent?) = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val title = intent?.getStringExtra("title") ?: "Sending files"
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(CHANNEL, title, NotificationManager.IMPORTANCE_LOW))
        val open = PendingIntent.getActivity(this, 0, packageManager.getLaunchIntentForPackage(packageName),
            PendingIntent.FLAG_IMMUTABLE)
        val n = Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title)
            .setOngoing(true)
            .setContentIntent(open)
            .build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(2, n, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(2, n)
        }
        return START_NOT_STICKY // if Android kills the app, the upload resumes when it's next open
    }

    // Android 15 caps data-sync services at 6 hours a day: past that, stop; the upload resumes later.
    override fun onTimeout(startId: Int, fgsType: Int) = stopSelf()

    private companion object {
        const val CHANNEL = "transfers"
    }
}
