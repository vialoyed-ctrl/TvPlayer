package com.tvplayer.app

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
import android.util.Log

/**
 * 把进程「钉」住，并在通知栏显示下载进度。
 *
 * 真正在下载的是 Dart 侧的 `DownloadService`。Android 上 App 退到后台之后，
 * 没有前台服务的进程随时可能被系统杀掉，下载就断了；起一个前台服务之后进程
 * 会被保活，Flutter 的 Dart isolate 也就能继续跑 —— 这是各类 Flutter 下载器
 * 的通用做法。
 *
 * 这里**只**做两件事：保活 + 通知。下载逻辑（解析播放列表、断点续传、重试、
 * 合并）一律留在 Dart 侧复用已有的解析器和 dio，在 Kotlin 里重写一遍毫无意义。
 *
 * targetSdk 是 36（Android 16），所以有几处必须按新规来：
 * * Android 10+ 起 `startForeground` 要带服务类型，这里用 `dataSync`；
 * * 清单里必须同时声明 `FOREGROUND_SERVICE_DATA_SYNC` 权限，否则直接抛异常；
 * * Android 13+ 的通知需要 `POST_NOTIFICATIONS` 运行时权限 —— 没给也不影响
 *   服务运行（只是通知不显示），所以这里不做强制。
 */
class DownloadForegroundService : Service() {

    companion object {
        private const val TAG = "TvPlayerDownload"
        private const val CHANNEL_ID = "tvplayer_download"
        private const val NOTIFICATION_ID = 0x484B444C // 'HKDL'

        private const val EXTRA_TITLE = "title"
        private const val EXTRA_TEXT = "text"
        private const val EXTRA_PROGRESS = "progress"
        private const val EXTRA_MAX = "max"
        private const val ACTION_STOP = "com.tvplayer.app.STOP_DOWNLOAD_SERVICE"

        /** 服务是否正在运行。用它决定走 startService 还是 startForegroundService。 */
        @Volatile
        private var running = false

        private fun newIntent(
            context: Context,
            title: String,
            text: String,
            progress: Int,
            max: Int
        ): Intent = Intent(context, DownloadForegroundService::class.java).apply {
            putExtra(EXTRA_TITLE, title)
            putExtra(EXTRA_TEXT, text)
            putExtra(EXTRA_PROGRESS, progress)
            putExtra(EXTRA_MAX, max)
        }

        /**
         * 起服务 / 刷新通知。
         *
         * 为什么分两种情况：Android 12+ 在后台调用 `startForegroundService` 会抛
         * `ForegroundServiceStartNotAllowedException`；而服务**已经在跑**的时候
         * 普通 `startService` 就能刷新通知，也不需要那个豁免。
         */
        fun post(context: Context, title: String, text: String, progress: Int, max: Int) {
            val intent = newIntent(context, title, text, progress, max)
            try {
                if (running) {
                    context.startService(intent)
                } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                // 后台启动被系统拒绝是预期内的情况，不能当致命错误：
                // 通知停在上一帧而已，下载本身还在 Dart 侧继续。
                Log.w(TAG, "post() failed: ${e.message}")
            }
        }

        /** 下载全部结束（或用户主动停止）时撤掉通知与保活。 */
        fun stop(context: Context) {
            if (!running) return
            try {
                context.startService(
                    Intent(context, DownloadForegroundService::class.java)
                        .setAction(ACTION_STOP)
                )
            } catch (e: Exception) {
                Log.w(TAG, "stop() failed: ${e.message}")
            }
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var isForeground = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            releaseWakeLock()
            stopForeground(Service.STOP_FOREGROUND_REMOVE)
            isForeground = false
            running = false
            stopSelf()
            return Service.START_NOT_STICKY
        }

        val title = intent?.getStringExtra(EXTRA_TITLE) ?: "正在下载"
        val text = intent?.getStringExtra(EXTRA_TEXT) ?: ""
        val progress = intent?.getIntExtra(EXTRA_PROGRESS, -1) ?: -1
        val max = intent?.getIntExtra(EXTRA_MAX, 0) ?: 0

        ensureChannel()
        acquireWakeLock()

        val notification = buildNotification(title, text, progress, max)
        try {
            if (!isForeground) {
                startForegroundCompat(notification)
                isForeground = true
            } else {
                notificationManager().notify(NOTIFICATION_ID, notification)
            }
            running = true
        } catch (e: Exception) {
            // 例如用户关掉了本应用的通知权限、或 ROM 对前台服务有额外限制。
            // 记一笔就退出，不要让整个进程崩掉 —— 下载还在 Dart 侧跑。
            Log.w(TAG, "startForeground failed: ${e.message}")
            running = false
        }
        return Service.START_NOT_STICKY
    }

    override fun onDestroy() {
        releaseWakeLock()
        isForeground = false
        running = false
        super.onDestroy()
    }

    private fun startForegroundCompat(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun notificationManager(): NotificationManager =
        getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    private fun ensureChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = notificationManager()
        if (nm.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "下载",
            // IMPORTANCE_LOW：下载进度不需要提示音和悬浮横幅。
            // 否则每刷新一次进度就响一声，几十个分片下来会疯掉。
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "影视缓存下载进度"
            setShowBadge(false)
        }
        nm.createNotificationChannel(channel)
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        val pm = getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return
        try {
            // PARTIAL_WAKE_LOCK：只保证 CPU 不睡，屏幕该关就关 —— 下载不需要亮屏。
            // 超时给 6 小时兜底，防止异常路径下忘了释放把电池耗干。
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "tvplayer:download").apply {
                setReferenceCounted(false)
                acquire(6 * 60 * 60 * 1000L)
            }
        } catch (e: Exception) {
            Log.w(TAG, "acquireWakeLock failed: ${e.message}")
        }
    }

    private fun releaseWakeLock() {
        try {
            wakeLock?.let { if (it.isHeld) it.release() }
        } catch (e: Exception) {
            Log.w(TAG, "releaseWakeLock failed: ${e.message}")
        }
        wakeLock = null
    }

    private fun buildNotification(
        title: String,
        text: String,
        progress: Int,
        max: Int
    ): Notification {
        // 注：@Suppress 必须挂在「局部变量声明」上。挂在 if/else 分支里的表达式上
        // 语法上能过、但可读性差且容易被后续改动破坏，这里刻意绕开。
        @Suppress("DEPRECATION")
        val builder: Notification.Builder =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(this, CHANNEL_ID)
            } else {
                Notification.Builder(this)
            }

        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        if (launchIntent != null) {
            builder.setContentIntent(
                PendingIntent.getActivity(
                    this,
                    0,
                    launchIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
            )
        }

        builder
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setShowWhen(false)

        if (max > 0 && progress >= 0) {
            builder.setProgress(max, progress, false)
        } else {
            builder.setProgress(0, 0, true)
        }

        return builder.build()
    }
}
