package schedule

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class CourseReminderReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action == CourseReminderScheduler.ACTION) {
            val end = intent.getLongExtra("end", 0)
            if (end <= System.currentTimeMillis()) return
            CourseReminderScheduler.show(context, intent.getStringExtra("id") ?: "course",
                intent.getStringExtra("course") ?: "课程", intent.getStringExtra("location") ?: "",
                intent.getLongExtra("start", System.currentTimeMillis()), end)
            return
        }
        if (intent.action in listOf(Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_TIME_CHANGED,
                Intent.ACTION_TIMEZONE_CHANGED, Intent.ACTION_MY_PACKAGE_REPLACED)) {
            try { CourseReminderScheduler.refresh(context) } catch (_: Exception) { }
            try { ScheduleWidgetProvider.updateAll(context) } catch (_: Exception) { }
            // Re-register future recording alarms, never cold-start a microphone service.
            try { audio.AutoRecordAlarmStore.restore(context) } catch (_: Exception) { }
        }
    }
}
