package com.ugoyt.ugo_yt

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.BitmapFactory
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.support.v4.media.MediaMetadataCompat
import android.support.v4.media.session.MediaSessionCompat
import android.support.v4.media.session.PlaybackStateCompat
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat

/** Routes media-session actions (lock screen, headsets) back into Dart. */
object PlaybackBridge {
    @Volatile
    var channel: io.flutter.plugin.common.MethodChannel? = null
    private val main = Handler(Looper.getMainLooper())

    fun sendAction(action: String) {
        main.post { channel?.invokeMethod("mediaAction", action) }
    }

    fun sendSeek(positionMs: Long) {
        main.post { channel?.invokeMethod("mediaSeek", positionMs) }
    }
}

/**
 * Foreground service active while the player panel is open. Hosts the
 * MediaSession + MediaStyle notification that puts play/pause (and a seek
 * bar) on the lock screen, and keeps the process alive so audio continues
 * when the app is minimized or the screen is off.
 *
 * Lock-screen actions flip the visible play/pause state on the NATIVE side
 * immediately (so the control responds even if the Flutter engine is briefly
 * frozen) and are then forwarded to Dart, which drives the actual player and
 * pushes back the authoritative state.
 */
class PlaybackService : Service() {
    private var wakeLock: PowerManager.WakeLock? = null
    private var session: MediaSessionCompat? = null

    private var title: String = "Playing"
    private var playing: Boolean = true
    private var positionMs: Long = 0
    private var durationMs: Long = 0
    private var thumbPath: String? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "ugoyt:playback")
            .apply { setReferenceCounted(false) }
        session = MediaSessionCompat(this, "ugoyt-playback").apply {
            setCallback(object : MediaSessionCompat.Callback() {
                override fun onPlay() = onTransport(wantPlaying = true)
                override fun onPause() = onTransport(wantPlaying = false)
                override fun onStop() = onTransport(wantPlaying = false)
                override fun onSeekTo(pos: Long) {
                    positionMs = pos
                    refreshSessionAndNotification()
                    PlaybackBridge.sendSeek(pos)
                }
            })
            isActive = true
        }
    }

    /** A play/pause request from the lock screen, headset, or notification. */
    private fun onTransport(wantPlaying: Boolean) {
        // Optimistically flip native state so the lock-screen control updates
        // instantly, then tell Dart to actually play/pause the video.
        playing = wantPlaying
        refreshSessionAndNotification()
        PlaybackBridge.sendAction(if (wantPlaying) "play" else "pause")
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_PLAY -> {
                onTransport(wantPlaying = true)
                return START_NOT_STICKY
            }
            ACTION_PAUSE -> {
                onTransport(wantPlaying = false)
                return START_NOT_STICKY
            }
        }
        applyUpdate(
            intent?.getStringExtra(EXTRA_TITLE) ?: title,
            if (intent?.hasExtra(EXTRA_PLAYING) == true) {
                intent.getBooleanExtra(EXTRA_PLAYING, true)
            } else {
                playing
            },
            intent?.getLongExtra(EXTRA_POSITION, positionMs) ?: positionMs,
            intent?.getLongExtra(EXTRA_DURATION, durationMs) ?: durationMs,
            intent?.getStringExtra(EXTRA_THUMB) ?: thumbPath,
        )
        return START_NOT_STICKY
    }

    fun applyUpdate(
        title: String,
        playing: Boolean,
        positionMs: Long,
        durationMs: Long,
        thumbPath: String?,
    ) {
        this.title = title
        this.playing = playing
        this.positionMs = positionMs
        this.durationMs = durationMs
        this.thumbPath = thumbPath

        // Hold the CPU only while actually playing.
        if (playing) {
            wakeLock?.acquire(4 * 60 * 60 * 1000L)
        } else {
            wakeLock?.let { if (it.isHeld) it.release() }
        }

        ensureChannel(this)
        updateSession()
        val notification = build()
        if (Build.VERSION.SDK_INT >= 29) {
            ServiceCompat.startForeground(
                this, NOTIF_ID, notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
            )
        } else {
            startForeground(NOTIF_ID, notification)
        }
    }

    /** Re-render session + notification without touching foreground state. */
    private fun refreshSessionAndNotification() {
        updateSession()
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        nm.notify(NOTIF_ID, build())
    }

    private fun updateSession() {
        val s = session ?: return
        val meta = MediaMetadataCompat.Builder()
            .putString(MediaMetadataCompat.METADATA_KEY_TITLE, title)
            .putString(MediaMetadataCompat.METADATA_KEY_ARTIST, "ugo-yt")
        if (durationMs > 0) {
            meta.putLong(MediaMetadataCompat.METADATA_KEY_DURATION, durationMs)
        }
        thumbPath?.let { path ->
            try {
                BitmapFactory.decodeFile(path)?.let { bmp ->
                    meta.putBitmap(MediaMetadataCompat.METADATA_KEY_ALBUM_ART, bmp)
                }
            } catch (_: Throwable) {
            }
        }
        s.setMetadata(meta.build())
        s.setPlaybackState(
            PlaybackStateCompat.Builder()
                .setActions(
                    PlaybackStateCompat.ACTION_PLAY
                        or PlaybackStateCompat.ACTION_PAUSE
                        or PlaybackStateCompat.ACTION_PLAY_PAUSE
                        or PlaybackStateCompat.ACTION_STOP
                        or PlaybackStateCompat.ACTION_SEEK_TO
                )
                .setState(
                    if (playing) PlaybackStateCompat.STATE_PLAYING
                    else PlaybackStateCompat.STATE_PAUSED,
                    positionMs,
                    if (playing) 1f else 0f,
                )
                .build()
        )
    }

    private fun build(): Notification {
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        val contentIntent = launch?.let {
            PendingIntent.getActivity(
                this, 1, it,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        }
        // Distinct play and pause intents so the OS media controller maps the
        // button unambiguously (a single toggle intent can go stale when the
        // notification isn't rebuilt between taps).
        val action = if (playing) {
            NotificationCompat.Action(
                android.R.drawable.ic_media_pause, "Pause",
                servicePendingIntent(ACTION_PAUSE, 2),
            )
        } else {
            NotificationCompat.Action(
                android.R.drawable.ic_media_play, "Play",
                servicePendingIntent(ACTION_PLAY, 3),
            )
        }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentTitle(title)
            .setContentText(if (playing) "Playing" else "Paused")
            .addAction(action)
            .setStyle(
                androidx.media.app.NotificationCompat.MediaStyle()
                    .setMediaSession(session?.sessionToken)
                    .setShowActionsInCompactView(0)
            )
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setOngoing(playing)
            .setOnlyAlertOnce(true)
            .setContentIntent(contentIntent)
            .build()
    }

    private fun servicePendingIntent(action: String, requestCode: Int): PendingIntent {
        return PendingIntent.getService(
            this, requestCode,
            Intent(this, PlaybackService::class.java).setAction(action),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    override fun onDestroy() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        session?.release()
        session = null
        instance = null
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL_ID = "playback"
        private const val NOTIF_ID = 2
        private const val ACTION_PLAY = "com.ugoyt.ugo_yt.PLAY"
        private const val ACTION_PAUSE = "com.ugoyt.ugo_yt.PAUSE"
        private const val EXTRA_TITLE = "title"
        private const val EXTRA_PLAYING = "playing"
        private const val EXTRA_POSITION = "positionMs"
        private const val EXTRA_DURATION = "durationMs"
        private const val EXTRA_THUMB = "thumbPath"

        @Volatile
        private var instance: PlaybackService? = null

        /** Start the service if needed, then apply the playback state. */
        fun update(
            ctx: Context,
            title: String,
            playing: Boolean,
            positionMs: Long,
            durationMs: Long,
            thumbPath: String?,
        ) {
            val running = instance
            if (running != null) {
                running.applyUpdate(title, playing, positionMs, durationMs, thumbPath)
                return
            }
            val intent = Intent(ctx, PlaybackService::class.java)
                .putExtra(EXTRA_TITLE, title)
                .putExtra(EXTRA_PLAYING, playing)
                .putExtra(EXTRA_POSITION, positionMs)
                .putExtra(EXTRA_DURATION, durationMs)
                .putExtra(EXTRA_THUMB, thumbPath)
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
    }
}
