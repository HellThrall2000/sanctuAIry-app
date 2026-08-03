package com.sanctuairy.app

import android.content.Context
import android.os.PowerManager
import android.os.StatFs
import androidx.annotation.NonNull
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity: FlutterActivity() {
    private val WAKELOCK_CHANNEL = "sanctuary/wakelock"
    private val STORAGE_CHANNEL = "sanctuary/storage"
    private var wakeLock: PowerManager.WakeLock? = null

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Free space on the volume holding a given path.
        //
        // Flutter has no API for this, and the model download needs it: writing
        // 2.4 GB onto a volume with 1 GB free fails three-quarters of the way
        // through, after the user has spent the bandwidth. Checking up front
        // turns that into a sentence before anything is downloaded.
        //
        // StatFs is deliberately pointed at the *target directory* rather than
        // at internal storage, because the model normally lands in app-specific
        // external storage, which is frequently a different volume.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, STORAGE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "freeBytes" -> {
                        try {
                            val path = call.argument<String>("path")
                                ?: filesDir.absolutePath
                            // StatFs throws on a path that does not exist yet,
                            // so walk up to the nearest existing ancestor.
                            var dir = File(path)
                            while (!dir.exists() && dir.parentFile != null) {
                                dir = dir.parentFile!!
                            }
                            val stat = StatFs(dir.absolutePath)
                            result.success(stat.availableBytes)
                        } catch (e: Exception) {
                            result.error("STATFS_ERROR", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WAKELOCK_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "acquireWakeLock" -> {
                    try {
                        if (wakeLock == null) {
                            val powerManager = getSystemService(Context.POWER_SERVICE) as PowerManager
                            wakeLock = powerManager.newWakeLock(
                                PowerManager.PARTIAL_WAKE_LOCK,
                                "Sanctuary::LiteRtMemoryLock"
                            )
                        }
                        if (wakeLock?.isHeld == false) {
                            wakeLock?.acquire(10 * 60 * 1000L) // 10 minutes max lock
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("WAKELOCK_ERROR", e.message, null)
                    }
                }
                "releaseWakeLock" -> {
                    try {
                        if (wakeLock?.isHeld == true) {
                            wakeLock?.release()
                        }
                        result.success(true)
                    } catch (e: Exception) {
                        result.error("WAKELOCK_ERROR", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onDestroy() {
        if (wakeLock?.isHeld == true) {
            wakeLock?.release()
        }
        super.onDestroy()
    }
}
