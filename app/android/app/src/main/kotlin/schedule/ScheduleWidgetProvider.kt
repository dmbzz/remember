package schedule

import android.app.AlarmManager
import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Build
import android.util.SizeF
import android.view.View
import android.widget.RemoteViews
import com.classnotes.assistant.MainActivity
import com.classnotes.assistant.R
import org.json.JSONObject
import java.time.LocalDate
import java.time.ZonedDateTime

class ScheduleWidgetProvider : AppWidgetProvider() {
    override fun onUpdate(context: Context, manager: AppWidgetManager, ids: IntArray) = updateAll(context)
    override fun onAppWidgetOptionsChanged(context: Context, manager: AppWidgetManager, id: Int, options: Bundle) = updateAll(context)
    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        if (intent.action in listOf(TICK, Intent.ACTION_BOOT_COMPLETED, Intent.ACTION_TIME_CHANGED,
            Intent.ACTION_TIMEZONE_CHANGED, Intent.ACTION_DATE_CHANGED, Intent.ACTION_LOCALE_CHANGED,
            Intent.ACTION_MY_PACKAGE_REPLACED)) updateAll(context)
    }
    override fun onDisabled(context: Context) {
        (context.getSystemService(Context.ALARM_SERVICE) as AlarmManager).cancel(tickIntent(context))
    }
    companion object {
        const val TICK = "com.classnotes.assistant.SCHEDULE_WIDGET_TICK"
        private const val PREF = "schedule_widget"
        fun save(context: Context, raw: String) {
            val data = JSONObject(raw)
            require(data.getInt("version") == 1)
            data.getJSONArray("entries"); LocalDate.parse(data.getString("semester_start"))
            require(context.getSharedPreferences(PREF, Context.MODE_PRIVATE).edit().putString("snapshot", raw).commit())
            CourseReminderScheduler.refresh(context)
            updateAll(context)
        }
        private fun tickIntent(context: Context): PendingIntent = PendingIntent.getBroadcast(context, 9201,
            Intent(context, ScheduleWidgetProvider::class.java).setAction(TICK), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
        fun updateAll(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(ComponentName(context, ScheduleWidgetProvider::class.java))
            if (ids.isEmpty()) return
            val now = ZonedDateTime.now(); val today = now.toLocalDate()
            val raw = context.getSharedPreferences(PREF, Context.MODE_PRIVATE).getString("snapshot", null)
            var term = "大二上"; var footer = "打开应用同步课表"
            var state = WidgetState("尚未同步", null, "打开应用同步课表", 0, null)
            try {
                if (raw != null) {
                    val data = JSONObject(raw); term = data.optString("term_label", "大二上")
                    val array = data.getJSONArray("entries")
                    val courses = (0 until array.length()).map { index ->
                        val item = array.getJSONObject(index); val weeks = item.optJSONArray("weeks")
                        WidgetCourse(item.optString("course_name", "课程"), item.optString("location", ""), item.optInt("weekday"),
                            ScheduleWidgetLogic.minutes(item.optString("start_time")), ScheduleWidgetLogic.minutes(item.optString("end_time")),
                            if (weeks == null) emptySet() else (0 until weeks.length()).map { weeks.optInt(it) }.filter { it > 0 }.toSet(),
                            item.optBoolean("confirmed", true))
                    }
                    state = ScheduleWidgetLogic.state(courses, LocalDate.parse(data.getString("semester_start")), today, now.hour * 60 + now.minute, data.optInt("semester_weeks",30))
                    val updated = java.time.Instant.ofEpochMilli(data.getLong("updated_at")).atZone(now.zone).toLocalDate()
                    footer = if (updated != today) "课表缓存 · ${updated.monthValue}/${updated.dayOfMonth}同步" else if (state.count > 0) "今天 ${state.count} 节课" else ""
                }
            } catch (_: Exception) { state = WidgetState("同步异常", null, "打开应用重新同步", 0, null) }
            val launch = PendingIntent.getActivity(context, 9200,
                Intent(context, MainActivity::class.java).putExtra("open_schedule", true).addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            val metrics = context.resources.displayMetrics
            val screenWidthDp = minOf(metrics.widthPixels, metrics.heightPixels) / metrics.density
            val date = "${today.monthValue}–${today.dayOfMonth} ${listOf("周一","周二","周三","周四","周五","周六","周日")[today.dayOfWeek.value - 1]}"
            for (id in ids) {
                val options = manager.getAppWidgetOptions(id)
                fun create(size: SizeF): RemoteViews = ScheduleWidgetLayout.create(context,
                    size.width, size.height, screenWidthDp, term, date, state, footer).also {
                    it.setOnClickPendingIntent(android.R.id.background, launch)
                }
                // Android 12 hosts provide actual supported sizes. MIN_WIDTH and
                // MIN_HEIGHT can belong to different orientations, so do not pair them.
                @Suppress("DEPRECATION")
                val exact = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S)
                    options.getParcelableArrayList<SizeF>(AppWidgetManager.OPTION_APPWIDGET_SIZES)
                        ?.filter { it.width > 0 && it.height > 0 }?.distinct()?.take(16)
                    else null
                val views = if (!exact.isNullOrEmpty()) {
                    RemoteViews(exact.associateWith(::create))
                } else {
                    val minW = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, 136).coerceAtLeast(1).toFloat()
                    val minH = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, 136).coerceAtLeast(1).toFloat()
                    val maxW = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH, minW.toInt()).coerceAtLeast(minW.toInt()).toFloat()
                    val maxH = options.getInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT, minH.toInt()).coerceAtLeast(minH.toInt()).toFloat()
                    RemoteViews(create(SizeF(maxW, minH)), create(SizeF(minW, maxH)))
                }
                manager.updateAppWidget(id, views)
            }
            val next = state.nextMinute?.let { today.atStartOfDay(now.zone).plusMinutes(it.toLong()) } ?: today.plusDays(1).atStartOfDay(now.zone)
            val alarm = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            // 仅刷新显示；不借用录音闹钟，不把组件刷新当成上课提醒。
            alarm.set(AlarmManager.RTC, next.toInstant().toEpochMilli(), tickIntent(context))
        }
    }
}
