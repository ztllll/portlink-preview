package dev.portlink.app

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
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.FlutterEngine

/** A non-sticky, user-started session; not a scheduler or a second SSH engine. */
class TunnelSessionService : Service() {
    // An actual reference to the already running tunnel-owning engine. Do not
    // attach its serviceControlSurface: that would detach its Activity plugins.
    private var retainedEngine: FlutterEngine? = null
    private var ending = false
    private val handler = Handler(Looper.getMainLooper())
    // Best effort while this user-started service is scheduled, not a wake lock.
    // Revoking the visible Stop notification must not silently leave SSH active.
    private val notificationCheck = object : Runnable {
        override fun run() {
            if (ending || retainedEngine == null) return
            SessionRuntime.checkNotificationVisibility()
            if (!ending) handler.postDelayed(this, 5_000L)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            SessionRuntime.requestStop("notification")
            if (retainedEngine == null) stopSelf()
            return START_NOT_STICKY
        }
        if (intent?.action != ACTION_START) {
            stopSelf()
            return START_NOT_STICKY
        }
        if (ending) {
            // If Android reuses an instance already queued for destruction, do
            // not acknowledge a new session on that dying service. Retry in UI.
            SessionRuntime.onServiceStartFailed()
            stopSelf()
            return START_NOT_STICKY
        }
        val existing = SessionRuntime.engineForService()
        if (existing == null) {
            // Never resurrect Dart/SSH from a redelivery or a stale notification.
            stopSelf()
            return START_NOT_STICKY
        }
        retainedEngine = existing
        try {
            createNotificationChannel(this)
            val notification = buildNotification()
            if (Build.VERSION.SDK_INT >= 34) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            SessionRuntime.onServiceForeground(this)
            handler.removeCallbacks(notificationCheck)
            if (!ending) handler.postDelayed(notificationCheck, 5_000L)
        } catch (_: RuntimeException) {
            SessionRuntime.onServiceStartFailed()
            stopFromRuntime()
        }
        return START_NOT_STICKY
    }

    private fun buildNotification(): Notification {
        val stop = PendingIntent.getService(
            this, 1, Intent(this, TunnelSessionService::class.java).setAction(ACTION_STOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val builder = if (Build.VERSION.SDK_INT >= 26) Notification.Builder(this, CHANNEL_ID)
            else Notification.Builder(this)
        builder.setSmallIcon(dev.portlink.portlink.R.drawable.ic_tunnel_session)
            .setContentTitle("PortLink · 本次多端口 SSH 转发")
            .setContentText("打开应用查看各规则 · 使用完请停止转发")
            .setCategory(Notification.CATEGORY_SERVICE)
            .setVisibility(Notification.VISIBILITY_PRIVATE)
            .setOngoing(true)
            // Android 14+ may let users dismiss an ongoing notification. Treat
            // that explicit dismissal as stop instead of hiding a live session.
            .setDeleteIntent(stop)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)
            .addAction(Notification.Action.Builder(null, "停止转发", stop).build())
        // Resolve the generated launcher without coupling the runtime package to
        // MainActivity's package. Tapping this reuses the app's single engine.
        packageManager.getLaunchIntentForPackage(packageName)?.let { launch ->
            launch.addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            builder.setContentIntent(PendingIntent.getActivity(
                this, 0, launch, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            ))
        }
        return builder.build()
    }

    fun stopFromRuntime() {
        ending = true
        handler.removeCallbacks(notificationCheck)
        retainedEngine = null
        if (Build.VERSION.SDK_INT >= 24) stopForeground(STOP_FOREGROUND_REMOVE)
        else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        SessionRuntime.requestStop("taskRemoved")
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        handler.removeCallbacks(notificationCheck)
        retainedEngine = null
        SessionRuntime.onServiceDestroyed(this)
        super.onDestroy()
    }

    companion object {
        const val CHANNEL_ID = "portlink_session_v1"
        const val ACTION_START = "dev.portlink.session.START"
        const val ACTION_STOP = "dev.portlink.session.STOP"
        private const val NOTIFICATION_ID = 3080

        fun createNotificationChannel(context: Context) {
            if (Build.VERSION.SDK_INT < 26) return
            val manager = context.getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(NotificationChannel(
                CHANNEL_ID, "本次端口转发", NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "仅在用户开始的转发会话期间显示，可随时停止。"
                setShowBadge(false)
            })
        }
    }
}
