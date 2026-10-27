package schedule

import android.app.AlarmManager
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.BitmapFactory
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import com.classnotes.assistant.MainActivity
import com.classnotes.assistant.R
import org.json.JSONObject
import java.time.LocalDate
import java.time.ZonedDateTime
import java.time.Instant

object CourseReminderScheduler {
    const val ACTION = "com.classnotes.assistant.COURSE_REMINDER"
    const val CHANNEL = "class_notes_courses_v2"
    private const val PREF = "class_notes_course_reminders"
    private fun plan(context: Context): List<CourseOccurrence> {
        val raw = context.getSharedPreferences("schedule_widget", Context.MODE_PRIVATE).getString("snapshot", null) ?: return emptyList()
        val data = JSONObject(raw); val entries = data.getJSONArray("entries")
        val courses = (0 until entries.length()).map { index ->
            val item = entries.getJSONObject(index); val weeks = item.optJSONArray("weeks")
            ReminderCourse(item.optString("course_id"), item.optString("course_name", "课程"), item.optString("location"),
                item.optInt("weekday"), ScheduleWidgetLogic.minutes(item.optString("start_time")),
                ScheduleWidgetLogic.minutes(item.optString("end_time")),
                if (weeks == null) emptySet() else (0 until weeks.length()).map { weeks.optInt(it) }.filter { it > 0 }.toSet(),
                item.optBoolean("confirmed", true))
        }
        return CourseReminderPlan.build(courses, LocalDate.parse(data.getString("semester_start")), ZonedDateTime.now(), data.optInt("semester_weeks",30))
    }
    private fun pending(context: Context, code: Int, intent: Intent) = PendingIntent.getBroadcast(context, code,
        intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
    @Synchronized fun refresh(context: Context) {
        val alarm = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val prefs = context.getSharedPreferences(PREF, Context.MODE_PRIVATE)
        // Parse first so a corrupt snapshot cannot silently erase existing alarms.
        val next = plan(context)
        for (code in prefs.getString("codes", "")!!.split(',').mapNotNull { it.toIntOrNull() }) {
            val old = PendingIntent.getBroadcast(context, code,
                Intent(context, CourseReminderReceiver::class.java).setAction(ACTION),
                PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE)
            if (old != null) { alarm.cancel(old); old.cancel() }
        }
        val codes = mutableListOf<Int>()
        for (item in next) {
            val intent = Intent(context, CourseReminderReceiver::class.java).setAction(ACTION)
                .putExtra("id", item.id).putExtra("course", item.course.name)
                .putExtra("location", item.course.location).putExtra("start", item.startMs).putExtra("end", item.endMs)
            val code = item.id.hashCode(); val target = pending(context, code, intent)
            if (Build.VERSION.SDK_INT < 31 || alarm.canScheduleExactAlarms()) {
                try { alarm.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, item.startMs, target) }
                catch (_: SecurityException) { alarm.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, item.startMs, target) }
            } else alarm.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, item.startMs, target)
            codes.add(code)
        }
        prefs.edit().putString("codes", codes.joinToString(",")).apply()
    }
    fun status(context: Context): Map<String, Any?> {
        val alarm = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val enabled = NotificationManagerCompat.from(context).areNotificationsEnabled() &&
            (Build.VERSION.SDK_INT < 26 || manager.getNotificationChannel(CHANNEL)?.importance != NotificationManager.IMPORTANCE_NONE)
        val focus: Boolean? = try {
            val extras = Bundle().apply { putString("package", context.packageName) }
            context.contentResolver.call(Uri.parse("content://miui.statusbar.notification.public"), "canShowFocus", null, extras)
                ?.getBoolean("canShowFocus", false)
        } catch (_: Exception) { null }
        val metadata = try { context.packageManager.getApplicationInfo(context.packageName, PackageManager.GET_META_DATA).metaData }
            catch (_: Exception) { null }
        return mapOf("notifications" to enabled,
            "exactAlarms" to (Build.VERSION.SDK_INT < 31 || alarm.canScheduleExactAlarms()),
            "scheduled" to (try { plan(context).size } catch (_: Exception) { 0 }),
            "armed" to (audio.AudioRecordService.activeInstance?.getStatus()?.get("isArmed") == true),
            "focusPermission" to focus,
            "focusProtocol" to Settings.System.getInt(context.contentResolver, "notification_focus_protocol", 0),
            "islandConfigured" to !metadata?.getString("com.xiaomi.xms.APP_ID").isNullOrBlank())
    }
    fun show(context: Context, id: String, course: String, location: String, start: Long, end: Long,
        note: String = "", recording: Boolean = false) {
        if (!NotificationManagerCompat.from(context).areNotificationsEnabled()) return
        val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) manager.createNotificationChannel(NotificationChannel(CHANNEL, "课程开始提醒", NotificationManager.IMPORTANCE_HIGH)
            .apply { description = "本地课表到点提醒，包含教室和上课时间" })
        val zone = java.time.ZoneId.systemDefault()
        val from = Instant.ofEpochMilli(start).atZone(zone); val until = Instant.ofEpochMilli(end).atZone(zone)
        val time = "%02d:%02d–%02d:%02d".format(from.hour, from.minute, until.hour, until.minute)
        val room = location.ifBlank { "教室待定" }
        val details = "${from.monthValue}月${from.dayOfMonth}日\n上课时间：$time\n教室：$room" + if (note.isBlank()) "" else "\n$note"
        val launch = Intent(context, MainActivity::class.java)
            .putExtra(if (recording) "open_recording" else "open_schedule", true)
            .addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        val open = PendingIntent.getActivity(context, id.hashCode(), launch, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        val notification = NotificationCompat.Builder(context, CHANNEL)
            .setSmallIcon(R.drawable.ic_notification_remember)
            .setLargeIcon(BitmapFactory.decodeResource(context.resources, R.drawable.remember_brand))
            .setContentTitle("现在上课：$course")
            .setContentText("$room · $time").setStyle(NotificationCompat.BigTextStyle().bigText(details))
            .setContentIntent(open).setAutoCancel(true).setPriority(NotificationCompat.PRIORITY_HIGH)
            .setCategory(NotificationCompat.CATEGORY_EVENT).setTimeoutAfter((end - System.currentTimeMillis()).coerceAtLeast(1000))
            .addAction(0, if (recording) "打开录音" else "查看课表", open).build()
        try { manager.notify(id.hashCode(), notification) } catch (_: SecurityException) { }
    }
    fun test(context: Context) {
        require(NotificationManagerCompat.from(context).areNotificationsEnabled()) { "请先在通知设置中允许 remember 发送通知" }
        val next = plan(context).firstOrNull()
        val now = System.currentTimeMillis()
        show(context, "course_test", next?.course?.name ?: "课程通知测试", next?.course?.location ?: "教室示例 A-101",
            next?.startMs ?: now, next?.endMs ?: now + 60000,
            "这是一条测试通知；真实课程会在开始时间由手机本地闹钟触发")
    }
}
