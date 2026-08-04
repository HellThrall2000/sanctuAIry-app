package com.sanctuairy.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * Keeps the process alive while the companion is composing a reply.
 *
 * **Why a service and not just a wake lock.** The app already takes a partial
 * wake lock around generation, which stops the CPU sleeping — but it does
 * nothing about Android freezing or killing a backgrounded process, and an app
 * holding a 2.5 GB model resident is the first thing the system reclaims. So a
 * message sent just before the user switched away had its reply thrown away
 * mid-generation, and the conversation was left with a hole in it.
 *
 * A foreground service is the only supported way to finish work the user asked
 * for after they stop looking at it. It runs for the 15–30 seconds a reply
 * takes, then stops itself.
 *
 * **`specialUse`, after `shortService` proved too small.** `shortService` looked
 * right — user-initiated work that must complete and finishes quickly — but its
 * three-minute ceiling is not advisory: the platform calls `onTimeout` and the
 * service must stop. Measured on device, a reply that takes 16-24 seconds in the
 * foreground took **180 seconds** with the screen off, because a backgrounded
 * process gets far less CPU. One run finished at 180s; the next crossed the line
 * and the process was reclaimed mid-generation, losing the reply.
 *
 * `specialUse` is the type for work that does not fit the predefined categories,
 * and has no per-run ceiling. It requires a written subtype in the manifest and
 * Play asks for justification at review — see docs/RELEASE.md.
 *
 * The app is always in the foreground when generation begins — the user has
 * just pressed send — which is what `shortService` requires; it cannot be
 * started from the background.
 *
 * This is not the only defence. If the system kills the process anyway, the
 * unanswered message is detected and answered on next launch (see
 * `_answerUnansweredMessage`). This makes that path rare rather than routine.
 */
class GenerationService : Service() {

    companion object {
        private const val CHANNEL_ID = "sanctuary_generating"
        private const val NOTIFICATION_ID = 42

        fun start(context: Context) {
            val intent = Intent(context, GenerationService::class.java)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, GenerationService::class.java))
        }
    }

    private var wakeLock: android.os.PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        createChannel()
        acquireWakeLock()

        val notification: Notification =
            Notification.Builder(this, CHANNEL_ID)
                .setContentTitle("Writing a reply")
                .setContentText("Your companion is thinking…")
                .setSmallIcon(R.drawable.ic_notification)
                // Quiet: this is housekeeping the user did not ask to watch.
                // It exists because the platform requires a foreground service
                // to be visible, not because it is worth their attention.
                .setOngoing(true)
                .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }

        // NOT_STICKY: if the system kills us mid-reply there is nothing useful
        // to restart into — the engine and its conversation went with the
        // process. The unanswered message is picked up on next launch instead.
        return START_NOT_STICKY
    }

    /**
     * Retained as a backstop. `specialUse` has no per-run ceiling, so this
     * should not fire — but if a future Android applies one, stopping promptly
     * is required and failing to is an ANR-class offence.
     */
    override fun onTimeout(startId: Int) {
        stopSelf()
    }

    override fun onDestroy() {
        releaseWakeLock()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        super.onDestroy()
    }

    /**
     * Holds the CPU awake for the generation window.
     *
     * The foreground service stops the process being frozen or killed; it does
     * not stop the CPU idling. Those are different things, and without this the
     * second one dominated: a reply that takes 16-24 seconds in the foreground
     * took **180 seconds** with the screen off — close enough to the
     * `shortService` ceiling that a slightly longer reply would have been cut
     * off by `onTimeout`.
     *
     * The app already had a wake lock, but only around *model initialisation* —
     * `LiteRtService.initializeModel` takes and releases it — so generation
     * itself ran unprotected. Holding it here instead ties it to exactly the
     * work that needs it, and guarantees it is released with the service rather
     * than depending on a Dart `finally` surviving a process the system is
     * trying to reclaim.
     *
     * Timeout is a backstop, not a plan: the service stops itself when the
     * reply lands, and Android's short-service ceiling is lower anyway.
     */
    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        try {
            val power = getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
            wakeLock = power.newWakeLock(
                android.os.PowerManager.PARTIAL_WAKE_LOCK,
                "sanctuAIry::Generation",
            ).also { it.acquire(4 * 60 * 1000L) }
        } catch (e: Exception) {
            // Generation still runs; it is just slower and at more risk.
            wakeLock = null
        }
    }

    private fun releaseWakeLock() {
        try {
            if (wakeLock?.isHeld == true) wakeLock?.release()
        } catch (_: Exception) {
        } finally {
            wakeLock = null
        }
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return

        val channel = NotificationChannel(
            CHANNEL_ID,
            "Composing a reply",
            // MIN so it stays silent and collapsed. The user is having a
            // conversation, not monitoring a job.
            NotificationManager.IMPORTANCE_MIN,
        ).apply {
            description = "Shown briefly while your companion writes a reply."
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }
}
