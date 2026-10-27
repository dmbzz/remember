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
import androidx.core.app.NotificationCompat
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
    private var currentSessionId: String? = null

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

    private fun acquireWakeLock() {
        val powerManager = getSystemService(Context.POWER_SERVICE) as? PowerManager
        wakeLock = powerManager?.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "ClassNotes:AudioRecordWakeLock"
        )?.apply {
            setReferenceCounted(false)
            acquire(4 * 60 * 60 * 1000L) // 最大持有4小时（覆盖最长四节连堂）
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

    fun startManual(courseId: String, sessionId: String, file: File): Boolean {
        currentCourseName = null
        currentCourseId = courseId
        return start(sessionId, file)
    }

    fun startAutomatic(courseName: String, courseId: String, sessionId: String): Boolean {
        if (!isArmed || isRecording) return false
        currentCourseName = courseName
        currentCourseId = courseId
        val file = RecordingRepository(this).createAudioFile(sessionId, "aac")
        return start(sessionId, file)
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
            acquireWakeLock()

            this.recorder = rec
            this.isRecording = true
            this.isPaused = false
            this.startTimeMs = System.currentTimeMillis()
            this.elapsedMs = 0L

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

    fun pause() {
        if (isRecording && !isPaused && Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            try {
                recorder?.pause()
                isPaused = true
            } catch (_: Exception) {}
        }
    }

    fun resume() {
        if (isRecording && isPaused && Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            try {
                recorder?.resume()
                isPaused = false
            } catch (_: Exception) {}
        }
    }

    fun stop(): Map<String, Any?> {
        stopTimer()
        val wasRecording = isRecording
        val duration = elapsedMs
        val file = currentFile
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
        }

        if (isArmed) showForeground(buildIdleNotification())
        else stopForeground(STOP_FOREGROUND_REMOVE)
        releaseWakeLock()

        if (success && currentSessionId?.startsWith("rec_auto_") == true) {
            eventListener?.invoke("autoStopped", mapOf(
                "filePath" to (file?.absolutePath ?: ""),
                "courseId" to (currentCourseId ?: ""),
                "classDate" to java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.getDefault()).format(java.util.Date(startTimeMs))
            ))
        }

        return mapOf(
            "sessionId" to (currentSessionId ?: ""),
            "filePath" to (file?.absolutePath ?: ""),
            "durationMs" to duration,
            "sizeBytes" to (file?.length() ?: 0L),
            "courseId" to currentCourseId,
            "classDate" to java.text.SimpleDateFormat("yyyy-MM-dd", java.util.Locale.getDefault()).format(java.util.Date(startTimeMs)),
            "success" to success
        )
    }

    fun cancel() {
        val file = currentFile
        stop()
        try {
            if (file?.exists() == true) {
                file.delete()
            }
        } catch (_: Exception) {}
    }

    fun getStatus(): Map<String, Any?> {
        val maxAmp = try {
            recorder?.maxAmplitude ?: 0
        } catch (_: Exception) {
            0
        }
        return mapOf(
            "isRecording" to isRecording,
            "isPaused" to isPaused,
            "isArmed" to isArmed,
            "courseId" to currentCourseId,
            "sessionId" to currentSessionId,
            "elapsedMs" to elapsedMs,
            "amplitude" to maxAmp
        )
    }

    private fun startTimer() {
        timer?.cancel()
        timer = Timer()
        timer?.scheduleAtFixedRate(object : TimerTask() {
            override fun run() {
                if (isRecording && !isPaused) {
                    elapsedMs += 1000L
                    updateNotification(elapsedMs)
                    mainHandler.post {
                        val status = getStatus()
                        eventListener?.invoke("status", status)
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

    private fun buildNotification(elapsed: Long): Notification {
        val seconds = (elapsed / 1000) % 60
        val minutes = (elapsed / (1000 * 60)) % 60
        val hours = elapsed / (1000 * 60 * 60)
        val timeStr = if (hours > 0) {
            String.format("%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            String.format("%02d:%02d", minutes, seconds)
        }

        val title = if (currentCourseName != null) "【自动录音】$currentCourseName" else "正在录制课堂音频"
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText("已录制 $timeStr ｜ 锁屏与后台持续运行中")
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
            .setOngoing(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }

    private fun buildIdleNotification(): Notification =
        NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("课堂自动录音已布防")
            .setContentText("到点录音需要此通知保持运行；关闭布防可停止")
            .setSmallIcon(android.R.drawable.ic_btn_speak_now)
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
