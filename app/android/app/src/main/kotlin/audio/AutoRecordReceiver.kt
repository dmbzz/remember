package audio

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

/** Starts only an armed service; alarms never cold-start a microphone service. */
class AutoRecordReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        val sessionId = intent.getStringExtra(EXTRA_SESSION_ID) ?: return
        val service = AudioRecordService.activeInstance
        when (action) {
            ACTION_AUTO_RECORD_START -> {
                val now = System.currentTimeMillis()
                val start = intent.getLongExtra(EXTRA_START_EPOCH_MS, now)
                val end = intent.getLongExtra(EXTRA_END_EPOCH_MS,
                    start + intent.getLongExtra(EXTRA_DURATION_MS, 90 * 60 * 1000L))
                if (end <= now) return
                val status = service?.getStatus()
                val alreadyRecording = status?.get("isRecording") == true && status["sessionId"] == sessionId
                if (!alreadyRecording && AutoRecordAlarmStore.wasStarted(context, sessionId)) return
                val courseName = intent.getStringExtra(EXTRA_COURSE_NAME) ?: "课堂课程"
                val courseId = intent.getStringExtra(EXTRA_COURSE_ID) ?: "course_default"
                val started = alreadyRecording || service?.startAutomatic(courseName, courseId, sessionId) == true
                if (!started) {
                    val message = if (status?.get("isRecording") == true)
                        "当前已有录音，本节课未覆盖正在进行的录音；可进入应用检查"
                    else "自动录音服务未就绪，点开应用重新布防或手动开始录音"
                    schedule.CourseReminderScheduler.show(context, "course_${courseId}_$start",
                        courseName, intent.getStringExtra(EXTRA_LOCATION) ?: "", start, end, message, recording = true)
                    return
                }
                val pendingStop = PendingIntent.getBroadcast(context, sessionId.hashCode() + 1,
                    Intent(context, AutoRecordReceiver::class.java).apply {
                        this.action = ACTION_AUTO_RECORD_STOP
                        putExtra(EXTRA_SESSION_ID, sessionId)
                    }, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
                val manager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
                try {
                    manager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, end, pendingStop)
                } catch (_: SecurityException) {
                    manager.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, end, pendingStop)
                }
            }
            ACTION_AUTO_RECORD_STOP -> {
                if (service?.getStatus()?.get("sessionId") == sessionId) service.stop()
            }
        }
    }

    companion object {
        const val ACTION_AUTO_RECORD_START = "com.classnotes.assistant.ACTION_AUTO_RECORD_START"
        const val ACTION_AUTO_RECORD_STOP = "com.classnotes.assistant.ACTION_AUTO_RECORD_STOP"
        const val EXTRA_COURSE_NAME = "extra_course_name"
        const val EXTRA_COURSE_ID = "extra_course_id"
        const val EXTRA_LOCATION = "extra_location"
        const val EXTRA_SESSION_ID = "extra_session_id"
        const val EXTRA_START_EPOCH_MS = "extra_start_epoch_ms"
        const val EXTRA_END_EPOCH_MS = "extra_end_epoch_ms"
        const val EXTRA_DURATION_MS = "extra_duration_ms"
    }
}
