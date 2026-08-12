package com.ugoyt.ugo_yt

import android.content.Intent

import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.core.app.ActivityCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var shareChannel: MethodChannel? = null
    private var pendingShared: String? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        pendingShared = extractShared(intent)
        requestNotificationPermissionIfNeeded()
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val messenger = flutterEngine.dartExecutor.binaryMessenger

        shareChannel = MethodChannel(messenger, "ugoyt/share").also { channel ->
            channel.setMethodCallHandler { call, result ->
                when (call.method) {
                    "getInitialShared" -> {
                        result.success(pendingShared)
                        pendingShared = null
                    }
                    else -> result.notImplemented()
                }
            }
        }

        MethodChannel(messenger, "ugoyt/keepalive").setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    DownloadService.start(this, call.argument<String>("text") ?: "Downloading…")
                    result.success(null)
                }
                "update" -> {
                    DownloadService.update(
                        this,
                        call.argument<String>("text") ?: "Downloading…",
                        call.argument<Int>("progress") ?: -1
                    )
                    result.success(null)
                }
                "stop" -> {
                    DownloadService.stop(this)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val shared = extractShared(intent) ?: return
        val channel = shareChannel
        if (channel != null) {
            channel.invokeMethod("onShared", shared)
        } else {
            pendingShared = shared
        }
    }

    private fun extractShared(intent: Intent?): String? {
        if (intent == null) return null
        if (intent.action == Intent.ACTION_SEND && intent.type == "text/plain") {
            return intent.getStringExtra(Intent.EXTRA_TEXT)
        }
        return null
    }

    private fun requestNotificationPermissionIfNeeded() {
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(android.Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            ActivityCompat.requestPermissions(
                this, arrayOf(android.Manifest.permission.POST_NOTIFICATIONS), 100
            )
        }
    }
}
