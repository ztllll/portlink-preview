package dev.portlink.app

import android.Manifest
import android.app.Activity
import android.app.Application
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference

/**
 * One application-owned engine: the UI and the foreground service retain the
 * SAME engine/main Dart isolate. Backgrounding an Activity only pauses frames;
 * it does not transfer, suspend, or recreate that isolate's SSH sockets.
 * All mutable state and channel callbacks run on Android's main thread.
 */
object SessionRuntime : Application.ActivityLifecycleCallbacks {
    private const val CHANNEL = "dev.portlink/session"
    private const val NOTIFICATION_PERMISSION_REQUEST = 3080
    private val handler = Handler(Looper.getMainLooper())
    private lateinit var application: Application
    private var engine: FlutterEngine? = null
    private var channel: MethodChannel? = null
    private var activity = WeakReference<Activity>(null)
    private var resumed = false
    private var dartReady = false
    private var service: TunnelSessionService? = null
    private var starting = false
    private var active = false
    private var stopping = false
    private var stopGeneration = 0
    private var permissionPending = false
    private val startResults = mutableListOf<MethodChannel.Result>()
    private var startTimeout: Runnable? = null
    private var stopTimeout: Runnable? = null

    fun initialize(app: Application) {
        if (::application.isInitialized) return
        application = app
        app.registerActivityLifecycleCallbacks(this)
    }

    /** Called only by MainActivity.provideFlutterEngine, never from a service. */
    fun engineForActivity(context: android.content.Context): FlutterEngine {
        initialize(context.applicationContext as Application)
        engine?.let { return it }
        val created = FlutterEngine(application)
        engine = created
        channel = MethodChannel(created.dartExecutor.binaryMessenger, CHANNEL).also {
            it.setMethodCallHandler(::onMethodCall)
        }
        created.dartExecutor.executeDartEntrypoint(DartExecutor.DartEntrypoint.createDefault())
        return created
    }

    /** A service may retain an existing engine, but may NEVER create/restart one. */
    fun engineForService(): FlutterEngine? = if (starting || active) engine else null

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "initialize" -> {
                dartReady = true
                result.success(null)
            }
            "start" -> start(result)
            "stop" -> {
                failStart("cancelled", "本次会话已停止")
                // Native stop waits for the Dart disconnect acknowledgement before
                // dropping FGS. Dart stop itself must not deadlock that handshake.
                if (!stopping) endService()
                result.success(null)
                if (!stopping) releaseIdleEngine()
            }
            else -> result.notImplemented()
        }
    }

    private fun start(result: MethodChannel.Result) {
        if (stopping) {
            result.error("stopping", "正在结束上一次会话，请稍后重试", null)
            return
        }
        if (!dartReady || engine == null) {
            result.error("engine_unavailable", "Flutter 会话引擎尚未就绪", null)
            return
        }
        if (active && service != null) {
            result.success(null)
            return
        }
        startResults.add(result)
        if (startResults.size == 1) {
            armStartTimeout(10_000, "请返回 PortLink 前台再开始连接")
        }
        tryStartWhenVisible()
    }

    private fun tryStartWhenVisible() {
        if (startResults.isEmpty() || starting || permissionPending || stopping) return
        val host = activity.get() ?: return
        if (!resumed || host.isFinishing || host.isDestroyed) return
        TunnelSessionService.createNotificationChannel(application)
        if (Build.VERSION.SDK_INT >= 33 &&
            host.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            permissionPending = true
            armStartTimeout(120_000, "通知权限请求超时，未开始连接")
            try {
                host.requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), NOTIFICATION_PERMISSION_REQUEST)
            } catch (_: RuntimeException) {
                permissionPending = false
                failStart("notification_permission_failed", "无法请求通知权限，请返回应用重试")
            }
            return
        }
        if (!notificationsEnabled()) {
            failStart("notifications_disabled", "请在系统设置中允许 PortLink 的本次转发通知，然后重试")
            return
        }
        starting = true
        armStartTimeout(10_000, "Android 未能及时启动前台会话，未开始连接")
        try {
            val intent = Intent(application, TunnelSessionService::class.java)
                .setAction(TunnelSessionService.ACTION_START)
            if (Build.VERSION.SDK_INT >= 26) host.startForegroundService(intent)
            else host.startService(intent)
        } catch (_: RuntimeException) {
            failStart("foreground_start_failed", "Android 拒绝启动前台会话，请返回应用重试")
        }
    }

    private fun notificationsEnabled(): Boolean {
        val manager = application.getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= 24 && !manager.areNotificationsEnabled()) return false
        if (Build.VERSION.SDK_INT >= 26 &&
            manager.getNotificationChannel(TunnelSessionService.CHANNEL_ID)?.importance == NotificationManager.IMPORTANCE_NONE
        ) return false
        return true
    }

    fun onRequestPermissionsResult(requestCode: Int): Boolean {
        if (requestCode != NOTIFICATION_PERMISSION_REQUEST) return false
        permissionPending = false
        if (startResults.isEmpty()) return true
        if (Build.VERSION.SDK_INT >= 33 && application.checkSelfPermission(
                Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            failStart("notification_permission_denied", "需要通知权限显示本次转发及停止按钮；尚未开始连接")
        } else {
            armStartTimeout(10_000, "请返回 PortLink 前台再开始连接")
            tryStartWhenVisible()
        }
        return true
    }

    fun onServiceForeground(value: TunnelSessionService) {
        if (active && service === value && !stopping) return
        if (!starting || startResults.isEmpty() || stopping || engine == null) {
            value.stopFromRuntime()
            return
        }
        service = value
        starting = false
        active = true
        clearStartTimeout()
        val results = startResults.toList()
        startResults.clear()
        results.forEach { it.success(null) }
    }

    fun onServiceStartFailed() {
        failStart("foreground_start_failed", "Android 前台会话启动失败，尚未开始连接")
    }

    fun onServiceDestroyed(value: TunnelSessionService) {
        if (service !== value) return
        service = null
        active = false
        requestStop("serviceDestroyed")
    }

    /** Notification stop, task removal, or a finishing Activity ends this session. */
    fun requestStop(reason: String) {
        if (stopping) return
        stopping = true
        val generation = ++stopGeneration
        failStart("cancelled", "本次会话已停止")
        val bridge = channel
        if (engine == null || bridge == null || !dartReady) {
            finishNativeStop(generation, false)
            return
        }
        stopTimeout = Runnable { finishNativeStop(generation, false) }.also { handler.postDelayed(it, 7_000) }
        bridge.invokeMethod("stopRequested", mapOf("reason" to reason), object : MethodChannel.Result {
            override fun success(result: Any?) { finishNativeStop(generation, result == true) }
            override fun error(code: String, message: String?, details: Any?) { finishNativeStop(generation, false) }
            override fun notImplemented() { finishNativeStop(generation, false) }
        })
    }

    private fun finishNativeStop(generation: Int, disconnected: Boolean) {
        if (!stopping || generation != stopGeneration) return
        stopping = false
        stopTimeout?.let { handler.removeCallbacks(it) }
        stopTimeout = null
        if (!disconnected) {
            // A notification without a live stop path is not sufficient. Destroy
            // the tunnel-owning isolate if the controller cannot confirm cleanup.
            val host = activity.get()
            if (host is FlutterActivity && !host.isDestroyed) host.detachFromFlutterEngine()
            host?.finish()
            destroyEngine()
        }
        endService()
        releaseIdleEngine()
    }

    private fun endService() {
        active = false
        starting = false
        val old = service
        service = null
        old?.stopFromRuntime()
        application.stopService(Intent(application, TunnelSessionService::class.java))
    }

    private fun armStartTimeout(delayMillis: Long, message: String) {
        clearStartTimeout()
        startTimeout = Runnable {
            failStart("foreground_start_timeout", message)
            endService()
            releaseIdleEngine()
        }.also { handler.postDelayed(it, delayMillis) }
    }

    private fun clearStartTimeout() {
        startTimeout?.let { handler.removeCallbacks(it) }
        startTimeout = null
    }

    private fun failStart(code: String, message: String) {
        clearStartTimeout()
        starting = false
        val results = startResults.toList()
        startResults.clear()
        results.forEach { it.error(code, message, null) }
    }

    private fun releaseIdleEngine() {
        // Post to allow the current platform-channel response to reach Dart.
        handler.post {
            if (activity.get() == null && !active && !starting && !stopping && startResults.isEmpty()) {
                destroyEngine()
            }
        }
    }

    private fun destroyEngine() {
        channel?.setMethodCallHandler(null)
        channel = null
        dartReady = false
        val old = engine
        engine = null
        old?.destroy()
    }

    override fun onActivityCreated(value: Activity, state: Bundle?) {
        if (value is FlutterActivity) activity = WeakReference(value)
    }

    override fun onActivityResumed(value: Activity) {
        if (value !is FlutterActivity) return
        activity = WeakReference(value)
        resumed = true
        tryStartWhenVisible()
    }

    override fun onActivityPaused(value: Activity) {
        if (activity.get() === value) resumed = false
    }

    override fun onActivityDestroyed(value: Activity) {
        if (activity.get() !== value) return
        activity.clear()
        resumed = false
        // A recreated Activity can receive a restored permission result or start
        // a fresh request; never leave a dead host owning this gate forever.
        permissionPending = false
        if (value.isChangingConfigurations) return
        if (value.isFinishing && (active || starting || startResults.isNotEmpty())) {
            // Application callbacks can run from Activity.super.onDestroy, before
            // FlutterActivity has detached its view/plugins. Finish that first.
            handler.post { requestStop("activityClosed") }
        } else if (!active && !starting && !stopping) {
            releaseIdleEngine()
        }
    }

    override fun onActivityStarted(value: Activity) = Unit
    override fun onActivityStopped(value: Activity) = Unit
    override fun onActivitySaveInstanceState(value: Activity, state: Bundle) = Unit
}
