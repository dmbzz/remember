package audio

import android.app.AlarmManager
import android.app.PendingIntent
import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import com.classnotes.assistant.MainActivity

/**
 * 课表到点自动录音广播接收器（利用系统精确闹钟与后台前台服务唤醒）。
 */
class AutoRecordReceiver : BroadcastReceiver() {

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        val courseName = intent.getStringExtra(EXTRA_COURSE_NAME) ?: "课堂课程"
        val location = intent.getStringExtra(EXTRA_LOCATION) ?: ""
        val courseId = intent.getStringExtra(EXTRA_COURSE_ID) ?: "course_default"
        val sessionId = intent.getStringExtra(EXTRA_SESSION_ID) ?: "rec_auto_${System.currentTimeMillis()}"
        val durationMs = intent.getLongExtra(EXTRA_DURATION_MS, 90 * 60 * 1000L) // 默认90分钟

        when (action) {
            ACTION_AUTO_RECORD_START -> {
                // Android 14+ 禁止在后台新建麦克风前台服务。只有提前布防且仍在运行时才能自动录音。
                val started = AudioRecordService.activeInstance?.startAutomatic(courseName, courseId, sessionId) == true
                if (!started) {
                    schedule.CourseReminderScheduler.show(context, "course_${courseId}_${System.currentTimeMillis()}",
                        courseName, location, System.currentTimeMillis(), System.currentTimeMillis() + durationMs,
                        "自动录音服务已停止，点开应用重新布防或手动开始录音", recording = true)
                    return
                }

                // 注册自动停止定时
                val stopIntent = Intent(context, AutoRecordReceiver::class.java).apply {
                    this.action = ACTION_AUTO_RECORD_STOP
                    putExtra(EXTRA_SESSION_ID, sessionId)
                }
                val pendingStop = PendingIntent.getBroadcast(
                    context,
                    sessionId.hashCode() + 1,
                    stopIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
                )
                val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as? AlarmManager
                val triggerAt = System.currentTimeMillis() + durationMs
                try {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                        alarmManager?.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAt, pendingStop)
                    } else {
                        alarmManager?.setExact(AlarmManager.RTC_WAKEUP, triggerAt, pendingStop)
                    }
                } catch (_: SecurityException) {
                    alarmManager?.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAt, pendingStop)
                }
            }

            ACTION_AUTO_RECORD_STOP -> {
                val service = AudioRecordService.activeInstance
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
        const val EXTRA_DURATION_MS = "extra_duration_ms"
    }
}
