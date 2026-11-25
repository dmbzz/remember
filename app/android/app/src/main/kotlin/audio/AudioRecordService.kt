package audio

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.MediaRecorder
import android.os.Binder
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.SystemClock
import androidx.core.app.NotificationCompat
import com.classnotes.assistant.MainActivity
import com.classnotes.assistant.R
import java.io.File
import java.util.Timer
import java.util.TimerTask

/**
 * 原生录音前台服务（FR-03、架构设计 §1.6.2，硬约定 #15：不使用三方录音插件）。
 * - 结合 PARTIAL_WAKE_LOCK 与 ForegroundService，降低锁屏/切后台时被系统终止的概率，不能保证系统绝不停止服务。
 * - 录制 AAC / 16kHz / 单声道，专为 Whisper 离线转写调优，体积小且高信噪比。
 */
class AudioRecordService : Service() {

    private val binder = LocalBinder()
    private var wakeLock: PowerManager.WakeLock? = null
    private var recorder: MediaRecorder? = null
    private var currentFile: File? = null

    private var isRecording = false
    private var isPaused = false
    private var isArmed = false
    private var startTimeMs: Long = 0L
    private var elapsedMs: Long = 0L
    private var accumulatedActiveMs: Long = 0L
    private var activeSegmentStartRealtimeMs: Long? = null
    private var currentSessionId: String? = null
    private var automaticEndEpochMs: Long? = null
    private var durationLimitMs: Long? = null
    private var limitAction: String = LIMIT_ACTION_STOP
    private var limitTriggered: Boolean = false

    internal var elapsedRealtimeProvider: () -> Long = { SystemClock.elapsedRealtime() }

    private var timer: Timer? = null
    private val mainHandler = Handler(Looper.getMainLooper())
    private var eventListener: ((type: String, data: Map<String, Any?>) -> Unit)? = null

    inner class LocalBinder : Binder() {
        fun getService(): AudioRecordService = this@AudioRecordService
    }

    override fun onBind(intent: Intent?): IBinder = binder

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        activeInstance = this
    }

    private var currentCourseName: String? = null
    private var currentCourseId: String? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_ARM -> arm()
            ACTION_DISARM -> disarm()
            ACTION_START_AUTO_RECORD -> {
                val courseName = intent.getStringExtra(EXTRA_COURSE_NAME) ?: "课堂课程"
                val sessionId = intent.getStringExtra(EXTRA_SESSION_ID) ?: "rec_auto_${System.currentTimeMillis()}"
                this.currentCourseName = courseName
                this.durationLimitMs = null
                this.limitAction = LIMIT_ACTION_STOP
                this.limitTriggered = false
                val repo = RecordingRepository(this)
                val file = repo.createAudioFile(sessionId, "aac")
                start(sessionId, file)
            }
            ACTION_STOP_AUTO_RECORD -> {
                stop()
            }
        }
        return START_NOT_STICKY
    }

    fun setEventListener(listener: ((type: String, data: Map<String, Any?>) -> Unit)?) {
        this.eventListener = listener
    }

    private fun acquireWakeLock(requestedDurationMs: Long? = null) {
        val powerManager = getSystemService(Context.POWER_SERVICE) as? PowerManager
        val holdMs = maxOf(4 * 60 * 60 * 1000L, (requestedDurationMs ?: 0L) + 10 * 60 * 1000L)
        wakeLock = powerManager?.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "ClassNotes:AudioRecordWakeLock"
        )?.apply {
            setReferenceCounted(false)
            acquire(holdMs) // 默认至少4小时，定时录音时自动覆盖目标时长与缓冲
        }
    }

    private fun releaseWakeLock() {
        try {
            if (wakeLock?.isHeld == true) {
                wakeLock?.release()
            }
        } catch (_: Exception) {}
    }

    fun arm() {
        if (!isRecording) showForeground(buildIdleNotification())
        isArmed = true
    }

    fun disarm() {
        isArmed = false
        if (!isRecording) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
    }

    fun startManual(
        courseId: String,
        sessionId: String,
        file: File,
        durationLimitMs: Long? = null,
        limitAction: String = LIMIT_ACTION_STOP
    ): Boolean {
        if (isRecording) return false
        if (durationLimitMs != null) {
            require(durationLimitMs in MIN_DURATION_LIMIT_MS..MAX_DURATION_LIMIT_MS) {
                "定时时长需在 1 分钟至 6 小时之间"
            }
        }
        require(limitAction == LIMIT_ACTION_STOP || limitAction == LIMIT_ACTION_PAUSE) {
            "不支持的到点动作：$limitAction"
        }
        automaticEndEpochMs = null
        currentCourseName = null
        currentCourseId = courseId
        this.durationLimitMs = durationLimitMs
        this.limitAction = if (durationLimitMs != null) limitAction else LIMIT_ACTION_STOP
        this.limitTriggered = false
        val started = start(sessionId, file)
        if (!started) {
            this.durationLimitMs = null
            this.limitAction = LIMIT_ACTION_STOP
            this.limitTriggered = false
        }
        return started
    }

    fun startAutomatic(courseName: String, courseId: String, sessionId: String, endEpochMs: Long? = null,
                       nowMs: Long = System.currentTimeMillis()): Boolean {
        if (!isArmed || AutoRecordAlarmStore.wasStarted(this, sessionId)) return false
        // Equal-time START and STOP broadcasts have no ordering contract. Only an
        // automatically started, already expired session may be handed over here.
        if (isRecording && automaticEndEpochMs?.let { it <= nowMs } == true) {
            stop()
        }
        if (isRecording) return false
        currentCourseName = courseName
        currentCourseId = courseId
        durationLimitMs = null
        limitAction = LIMIT_ACTION_STOP
        limitTriggered = false
        val file = RecordingRepository(this).createAudioFile(sessionId, "aac")
        val started = start(sessionId, file)
        if (started) {
            automaticEndEpochMs = endEpochMs
            AutoRecordAlarmStore.markStarted(this, sessionId)
        }
        return started
    }

    private fun showForeground(notification: Notification) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    fun start(sessionId: String, outputFile: File): Boolean {
        if (isRecording) return false

        try {
            this.currentSessionId = sessionId
            this.currentFile = outputFile

            val rec = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                MediaRecorder(this)
            } else {
                @Suppress("DEPRECATION")
                MediaRecorder()
            }

            rec.setAudioSource(MediaRecorder.AudioSource.MIC)
            rec.setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
            rec.setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
            rec.setAudioChannels(1) // 单声道
            rec.setAudioSamplingRate(16000) // 16kHz 专为 Whisper 调优
            rec.setAudioEncodingBitRate(64000) // 64kbps 高保真且省存储
            rec.setOutputFile(outputFile.absolutePath)
            this.recorder = rec
            rec.prepare()
            rec.start()
            acquireWakeLock(durationLimitMs)

            this.recorder = rec
            this.isRecording = true
            this.isPaused = false
            this.startTimeMs = System.currentTimeMillis()
            this.elapsedMs = 0L
            this.accumulatedActiveMs = 0L
            this.activeSegmentStartRealtimeMs = elapsedRealtimeProvider()

            // 启动前台服务通知
            val notification = buildNotification(0L)
            showForeground(notification)

            startTimer()
            return true
        } catch (e: Exception) {
            e.printStackTrace()
            stop()
            return false
        }
    }

    private fun computeElapsedMs(): Long {
        if (!isRecording) return elapsedMs
        val segStart = activeSegmentStartRealtimeMs
        if (isPaused || segStart == null) return accumulatedActiveMs
        val delta = (elapsedRealtimeProvider() - segStart).coerceAtLeast(0L)
        return accumulatedActiveMs + delta
    }

    fun pause(fromCountdown: Boolean = false): Boolean {
        if (isRecording && !isPaused && Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            try {
                recorder?.pause()
                accumulatedActiveMs = computeElapsedMs()
                elapsedMs = accumulatedActiveMs
                activeSegmentStartRealtimeMs = null
                isPaused = true
                if (fromCountdown) {
                    limitTriggered = true
                }
                updateNotification(elapsedMs)
                val statusSnapshot = getStatus()
                mainHandler.post {
                    eventListener?.invoke("status", statusSnapshot)
                    if (fromCountdown) {
                        eventListener?.invoke("countdownPaused", statusSnapshot)
                    }
                }
                return true
            } catch (e: Exception) {
                mainHandler.post {
                    eventListener?.invoke(
                        "error",
                        mapOf("message" to (e.message ?: "暂停录音失败"))
                    )
                }
                return false
            }
        }
        return false
    }

    fun resume(): Boolean {
        if (isRecording && isPaused && Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            try {
                recorder?.resume()
                activeSegmentStartRealtimeMs = elapsedRealtimeProvider()
                isPaused = false
                updateNotification(computeElapsedMs())
                val statusSnapshot = getStatus()
                mainHandler.post {
                    eventListener?.invoke("status", statusSnapshot)
                }
                return true
            } catch (e: Exception) {
                mainHandler.post {
                    eventListener?.invoke(
                        "error",
                        mapOf("message" to (e.message ?: "继续录音失败"))
                    )
                }
                return false
            }
        }
        return false
    }

    fun stop(emitAutoStopped: Boolean = true, stopReason: String? = null): Map<String, Any?> {
        stopTimer()
        val wasRecording = isRecording
        val finalElapsed = computeElapsedMs()
        var duration = finalElapsed
        val file = currentFile
        val sessionIdSnapshot = currentSessionId
        val courseIdSnapshot = currentCourseId
        val isCountdownStop = stopReason == STOP_REASON_COUNTDOWN
        var success = false

        try {
            recorder?.stop()
            recorder?.release()
            success = wasRecording
        } catch (e: Exception) {
            e.printStackTrace()
        } finally {
            try { recorder?.release() } catch (_: Exception) { }
            recorder = null
            isRecording = false
            isPaused = false
            elapsedMs = finalElapsed
            accumulatedActiveMs = finalElapsed
            activeSegmentStartRealtimeMs = null
            automaticEndEpochMs = null
            durationLimitMs = null
            limitAction = LIMIT_ACTION_STOP
            limitTriggered = false
        }

        if (isArmed) showForeground(buildIdleNotification())
        else stopForeground(STOP_FOREGROUND_REMOVE)
        releaseWakeLock()
        if (success && file != null) {
            val measured = RecordingRepository(this).durationMs(file)
            if (measured > 0) duration = measured
        }

        val shouldEmitAutoStopped = emitAutoStopped && success &&
            (isCountdownStop || sessionIdSnapshot?.startsWith("rec_auto_") == true)
        if (shouldEmitAutoStopped) {
            eventListener?.invoke("autoStopped", mapOf(
                "filePath" to (file?.absolutePath ?: ""),
                "courseId" to (courseIdSnapshot ?: ""),
                "durationMs" to duration,
                "classDate" to java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.getDefault()).format(java.util.Date(startTimeMs)),
                "reason" to (stopReason ?: "schedule")
            ))
        }
        if (isCountdownStop && success) {
            notifyCountdownCompleted(duration)
        }

        return mapOf(
            "sessionId" to (sessionIdSnapshot ?: ""),
            "filePath" to (file?.absolutePath ?: ""),
            "durationMs" to duration,
            "sizeBytes" to (file?.length() ?: 0L),
            "courseId" to courseIdSnapshot,
            "classDate" to java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.getDefault()).format(java.util.Date(startTimeMs)),
            "success" to success
        )
    }

    fun cancel() {
        discardRecording(currentSessionId ?: error("没有正在进行的录音"))
    }

    fun discardRecording(expectedSessionId: String): Boolean {
        check(isRecording && currentSessionId == expectedSessionId) {
            "当前录音已变化，请重新确认要删除的录音"
        }
        val file = currentFile ?: error("没有正在进行的录音")
        val repository = RecordingRepository(this)
        // Persist the intent before stopping. If deletion fails, recovery can
        // offer deletion again without automatically uploading this recording.
        repository.markDiscardRequested(file.absolutePath)
        stop(emitAutoStopped = false)
        return repository.deleteAudioFile(file.absolutePath)
    }

    fun deleteSavedRecording(filePath: String): Boolean {
        return RecordingRepository(this).deleteAudioFile(
            filePath, if (isRecording || recorder != null) currentFile else null)
    }

    fun getStatus(): Map<String, Any?> {
        val maxAmp = if (isRecording && !isPaused) {
            try {
                recorder?.maxAmplitude ?: 0
            } catch (_: Exception) {
                0
            }
        } else {
            0
        }
        val currentElapsed = computeElapsedMs()
        val activeLimit = if (isRecording) durationLimitMs else null
        val remaining = if (activeLimit != null) {
            (activeLimit - currentElapsed).coerceAtLeast(0L)
        } else {
            null
        }
        return mapOf(
            "isRecording" to isRecording,
            "isPaused" to isPaused,
            "isArmed" to isArmed,
            "courseId" to currentCourseId,
            "sessionId" to currentSessionId,
            "elapsedMs" to currentElapsed,
            "amplitude" to maxAmp,
            "durationLimitMs" to activeLimit,
            "remainingMs" to remaining,
            "limitAction" to if (activeLimit != null) limitAction else null,
            "limitTriggered" to (isRecording && limitTriggered)
        )
    }

    internal fun evaluateCountdownTick() {
        if (!isRecording || isPaused) return
        val current = computeElapsedMs()
        elapsedMs = current
        val limit = durationLimitMs
        if (limit != null && !limitTriggered && current >= limit) {
            if (limitAction == LIMIT_ACTION_PAUSE) {
                pause(fromCountdown = true)
            } else {
                limitTriggered = true
                stop(emitAutoStopped = true, stopReason = STOP_REASON_COUNTDOWN)
                eventListener?.invoke("status", getStatus())
            }
            return
        }
        updateNotification(current)
        eventListener?.invoke("status", getStatus())
    }

    private fun startTimer() {
        timer?.cancel()
        timer = Timer()
        timer?.scheduleAtFixedRate(object : TimerTask() {
            override fun run() {
                if (isRecording && !isPaused) {
                    mainHandler.post {
                        evaluateCountdownTick()
                    }
                }
            }
        }, 1000L, 1000L)
    }

    private fun stopTimer() {
        timer?.cancel()
        timer = null
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "课堂录音保活服务",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "保证上课录音在切后台或锁屏状态下稳定进行"
                setShowBadge(false)
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager?.createNotificationChannel(channel)
        }
    }

    private fun formatTime(ms: Long): String {
        val totalSec = (ms / 1000L).coerceAtLeast(0L)
        val seconds = totalSec % 60L
        val minutes = (totalSec / 60L) % 60L
        val hours = totalSec / 3600L
        return if (hours > 0L) {
            String.format("%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            String.format("%02d:%02d", minutes, seconds)
        }
    }

    private fun buildOpenRecordingPendingIntent(requestCode: Int): PendingIntent {
        val launch = Intent(this, MainActivity::class.java)
            .putExtra("open_recording", true)
            .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        return PendingIntent.getActivity(
            this,
            requestCode,
            launch,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    private fun buildNotification(elapsed: Long): Notification {
        val timeStr = formatTime(elapsed)
        val limit = durationLimitMs
        val remaining = if (limit != null) (limit - elapsed).coerceAtLeast(0L) else null
        val actionHint = if (limitAction == LIMIT_ACTION_PAUSE) "到点暂停" else "到点停止"

        val title = when {
            isPaused && limitTriggered -> "定时已到 · 录音已自动暂停"
            isPaused -> "课堂录音已暂停"
            currentCourseName != null -> "【自动录音】$currentCourseName"
            limit != null -> "正在定时录音"
            else -> "正在录制课堂音频"
        }
        val text = when {
            isPaused && limitTriggered -> "已录制 $timeStr ｜ 返回应用可继续录音或停止并同步"
            isPaused && remaining != null -> "已录制 $timeStr · 倒计时已暂停（剩余 ${formatTime(remaining)}）"
            isPaused -> "已录制 $timeStr ｜ 返回应用可继续或停止录音"
            remaining != null && !limitTriggered -> "已录制 $timeStr · 剩余 ${formatTime(remaining)}（$actionHint）"
            else -> "已录制 $timeStr ｜ 锁屏与后台持续运行中"
        }

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(R.drawable.ic_notification_remember)
            .setContentIntent(buildOpenRecordingPendingIntent(NOTIFICATION_ID))
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    private fun notifyCountdownCompleted(durationMs: Long) {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("定时录音已自动停止")
            .setContentText("已录制 ${formatTime(durationMs)}，音频已保存并等待同步")
            .setSmallIcon(R.drawable.ic_notification_remember)
            .setContentIntent(buildOpenRecordingPendingIntent(COUNTDOWN_DONE_NOTIFICATION_ID))
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
        try {
            manager?.notify(COUNTDOWN_DONE_NOTIFICATION_ID, notification)
        } catch (_: SecurityException) {
        }
    }

    private fun buildIdleNotification(): Notification =
        NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("课堂自动录音已布防")
            .setContentText("到点录音需要此通知保持运行；关闭布防可停止")
            .setSmallIcon(R.drawable.ic_notification_remember)
            .setContentIntent(buildOpenRecordingPendingIntent(NOTIFICATION_ID))
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()

    private fun updateNotification(elapsed: Long) {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as? NotificationManager
        manager?.notify(NOTIFICATION_ID, buildNotification(elapsed))
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        // 当用户在近期任务列表划掉 App 时，前台服务依然保护当前已录制文件
        super.onTaskRemoved(rootIntent)
    }

    override fun onDestroy() {
        activeInstance = null
        isArmed = false
        stop()
        super.onDestroy()
    }

    companion object {
        const val CHANNEL_ID = "class_notes_audio_record_channel"
        const val NOTIFICATION_ID = 20260916
        const val COUNTDOWN_DONE_NOTIFICATION_ID = 20260917

        const val LIMIT_ACTION_STOP = "stop"
        const val LIMIT_ACTION_PAUSE = "pause"
        const val STOP_REASON_COUNTDOWN = "countdown"
        const val MIN_DURATION_LIMIT_MS = 60 * 1000L
        const val MAX_DURATION_LIMIT_MS = 6 * 60 * 60 * 1000L

        const val ACTION_START_AUTO_RECORD = "com.classnotes.assistant.ACTION_START_AUTO_RECORD"
        const val ACTION_STOP_AUTO_RECORD = "com.classnotes.assistant.ACTION_STOP_AUTO_RECORD"
        const val ACTION_ARM = "com.classnotes.assistant.ACTION_ARM"
        const val ACTION_DISARM = "com.classnotes.assistant.ACTION_DISARM"
        @Volatile var activeInstance: AudioRecordService? = null

        const val EXTRA_COURSE_NAME = "extra_course_name"
        const val EXTRA_COURSE_ID = "extra_course_id"
        const val EXTRA_SESSION_ID = "extra_session_id"
        const val EXTRA_DURATION_MS = "extra_duration_ms"
    }
}
