package com.ugoyt.ugo_yt

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat

/**
 * Foreground service that keeps the process alive (and exempt from the
 * cached-app freezer) while the Dart side downloads videos. The actual
 * download logic lives in Dart; this service only pins the process and
 * shows a progress notification.
 */
class DownloadService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "ugoyt:download").apply {
            setReferenceCounted(false)
            acquire(60 * 60 * 1000L) // 1h safety cap
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: "Downloading…"
        val progress = intent?.getIntExtra(EXTRA_PROGRESS, -1) ?: -1
        ensureChannel(this)
        val notification = build(this, text, progress)
        if (Build.VERSION.SDK_INT >= 29) {
            ServiceCompat.startForeground(
                this, NOTIF_ID, notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            )
        } else {
            startForeground(NOTIF_ID, notification)
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL_ID = "downloads"
        private const val NOTIF_ID = 1
        private const val EXTRA_TEXT = "text"
        private const val EXTRA_PROGRESS = "progress"

        fun start(ctx: Context, text: String) {
            val intent = Intent(ctx, DownloadService::class.java).putExtra(EXTRA_TEXT, text)
            if (Build.VERSION.SDK_INT >= 26) {
                ctx.startForegroundService(intent)
            } else {
                ctx.startService(intent)
            }
        }

        /** Update the existing foreground notification (no service restart). */
        fun update(ctx: Context, text: String, progress: Int) {
            ensureChannel(ctx)
            val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.notify(NOTIF_ID, build(ctx, text, progress))
        }

        fun stop(ctx: Context) {
            ctx.stopService(Intent(ctx, DownloadService::class.java))
        }

        private fun ensureChannel(ctx: Context) {
            if (Build.VERSION.SDK_INT >= 26) {
                val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                nm.createNotificationChannel(
                    NotificationChannel(
                        CHANNEL_ID, "Downloads", NotificationManager.IMPORTANCE_LOW
                    )
                )
            }
        }

        private fun build(ctx: Context, text: String, progress: Int): Notification {
            val launch = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)
            val contentIntent = launch?.let {
                PendingIntent.getActivity(
                    ctx, 0, it,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
            }
            val builder = NotificationCompat.Builder(ctx, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.stat_sys_download)
                .setContentTitle("ugo-yt")
                .setContentText(text)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setContentIntent(contentIntent)
            if (progress in 0..100) {
                builder.setProgress(100, progress, false)
            } else {
                builder.setProgress(0, 0, true)
            }
            return builder.build()
        }
    }
}
