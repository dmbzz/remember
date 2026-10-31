package audio

import android.Manifest
import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat
import org.json.JSONArray
import java.time.LocalDate
import java.time.ZoneId
import schedule.ScheduleWidgetLogic

object AutoRecordAlarmStore {
    private const val PREF = "class_notes_record_alarms"
    private const val STARTED = "started_sessions"

    fun hasPermissions(context: Context): Boolean {
        val manager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        return ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED &&
            (Build.VERSION.SDK_INT < 33 || ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED) &&
            (Build.VERSION.SDK_INT < 31 || manager.canScheduleExactAlarms())
    }

    fun wasStarted(context: Context, sessionId: String): Boolean =
        context.getSharedPreferences(PREF, Context.MODE_PRIVATE)
            .getStringSet(STARTED, emptySet())!!.contains(sessionId)

    fun markStarted(context: Context, sessionId: String) {
        val prefs = context.getSharedPreferences(PREF, Context.MODE_PRIVATE)
        val sessions = prefs.getStringSet(STARTED, emptySet())!!.toMutableSet()
        sessions.add(sessionId)
        prefs.edit().putStringSet(STARTED, sessions).apply()
    }

    fun restore(context: Context) {
        val raw = context.getSharedPreferences(PREF, Context.MODE_PRIVATE).getString("alarms", null) ?: return
        val array = JSONArray(raw)
        val items = (0 until array.length()).map { i ->
            val item = array.getJSONObject(i)
            item.keys().asSequence().associateWith { item.opt(it) }
        }
        schedule(context, items)
    }

    fun schedule(context: Context, alarms: List<Map<String, Any?>>, nowMs: Long = System.currentTimeMillis()): Boolean {
        val manager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        if (alarms.isNotEmpty() && !hasPermissions(context)) return false

        val prefs = context.getSharedPreferences(PREF, Context.MODE_PRIVATE)
        val oldCodes = prefs.getString("codes", "")!!.split(',').mapNotNull { it.toIntOrNull() }.toSet()
        val codes = mutableSetOf<Int>()
        for (item in alarms) {
            val date = (item["classDate"] as? String)?.let { LocalDate.parse(it) }
            val startMinutes = (item["startTime"] as? String)?.let { ScheduleWidgetLogic.minutes(it) }
            val start = if (date != null && startMinutes != null)
                date.atStartOfDay(ZoneId.systemDefault()).plusMinutes(startMinutes.toLong()).toInstant().toEpochMilli()
                else (item["triggerEpochMs"] as? Number)?.toLong() ?: continue
            val endMinutes = (item["endTime"] as? String)?.let { ScheduleWidgetLogic.minutes(it) }
            val end = if (date != null && endMinutes != null)
                date.atStartOfDay(ZoneId.systemDefault()).plusMinutes(endMinutes.toLong()).toInstant().toEpochMilli()
                else (item["endEpochMs"] as? Number)?.toLong()
                    ?: start + ((item["durationMs"] as? Number)?.toLong() ?: 90 * 60000L)
            val now = nowMs
            if (end <= now || end <= start) continue
            val courseId = item["courseId"] as? String ?: continue
            val sessionId = "rec_auto_${courseId}_$start"
            if (wasStarted(context, sessionId)) continue
            val intent = Intent(context, AutoRecordReceiver::class.java).setAction(AutoRecordReceiver.ACTION_AUTO_RECORD_START)
                .putExtra(AutoRecordReceiver.EXTRA_COURSE_NAME, item["courseName"] as? String ?: "课程")
                .putExtra(AutoRecordReceiver.EXTRA_COURSE_ID, courseId)
                .putExtra(AutoRecordReceiver.EXTRA_LOCATION, item["location"] as? String ?: "")
                .putExtra(AutoRecordReceiver.EXTRA_SESSION_ID, sessionId)
                .putExtra(AutoRecordReceiver.EXTRA_START_EPOCH_MS, start)
                .putExtra(AutoRecordReceiver.EXTRA_END_EPOCH_MS, end)
                .putExtra(AutoRecordReceiver.EXTRA_DURATION_MS, end - start)
            val code = sessionId.hashCode()
            val pending = PendingIntent.getBroadcast(context, code, intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            // Original start identifies the session; a just-crossed start catches up.
            manager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, maxOf(start, now), pending)
            codes.add(code)
        }
        // Replace retained alarms before cancelling only removed sessions.
        for (code in oldCodes - codes) {
            val old = PendingIntent.getBroadcast(context, code,
                Intent(context, AutoRecordReceiver::class.java).setAction(AutoRecordReceiver.ACTION_AUTO_RECORD_START),
                PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE)
            if (old != null) { manager.cancel(old); old.cancel() }
        }
        prefs.edit().putString("alarms", JSONArray(alarms).toString())
            .putString("codes", codes.joinToString(",")).apply()
        return true
    }
}
