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
 * Foreground service active while a video is playing, so playback (audio)
 * survives the app being minimized — otherwise Android's cached-app freezer
 * suspends the process and the sound stops.
 */
class PlaybackService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "ugoyt:playback").apply {
            setReferenceCounted(false)
            acquire(4 * 60 * 60 * 1000L) // 4h safety cap
        }
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "Playing"
        ensureChannel(this)
        val notification = build(this, title)
        if (Build.VERSION.SDK_INT >= 29) {
            ServiceCompat.startForeground(
                this, NOTIF_ID, notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
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
        private const val CHANNEL_ID = "playback"
        private const val NOTIF_ID = 2
        private const val EXTRA_TITLE = "title"

        fun start(ctx: Context, title: String) {
            val intent = Intent(ctx, PlaybackService::class.java).putExtra(EXTRA_TITLE, title)
            if (Build.VERSION.SDK_INT >= 26) {
                ctx.startForegroundService(intent)
            } else {
                ctx.startService(intent)
            }
        }

        fun stop(ctx: Context) {
            ctx.stopService(Intent(ctx, PlaybackService::class.java))
        }

        private fun ensureChannel(ctx: Context) {
            if (Build.VERSION.SDK_INT >= 26) {
                val nm = ctx.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                nm.createNotificationChannel(
                    NotificationChannel(
                        CHANNEL_ID, "Playback", NotificationManager.IMPORTANCE_LOW
                    )
                )
            }
        }

        private fun build(ctx: Context, title: String): Notification {
            val launch = ctx.packageManager.getLaunchIntentForPackage(ctx.packageName)
            val contentIntent = launch?.let {
                PendingIntent.getActivity(
                    ctx, 1, it,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
            }
            return NotificationCompat.Builder(ctx, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.ic_media_play)
                .setContentTitle("ugo-yt")
                .setContentText(title)
                .setOngoing(true)
                .setOnlyAlertOnce(true)
                .setContentIntent(contentIntent)
                .build()
        }
    }
}
