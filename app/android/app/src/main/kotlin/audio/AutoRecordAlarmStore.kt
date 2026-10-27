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
    fun restore(context: Context) {
        val raw = context.getSharedPreferences(PREF, Context.MODE_PRIVATE).getString("alarms", null) ?: return
        val array = JSONArray(raw)
        val items = (0 until array.length()).map { i ->
            val item = array.getJSONObject(i)
            item.keys().asSequence().associateWith { item.opt(it) }
        }
        schedule(context, items)
    }
    fun schedule(context: Context, alarms: List<Map<String, Any?>>): Boolean {
        val manager = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        if (alarms.isNotEmpty() && (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED ||
            (Build.VERSION.SDK_INT >= 33 && ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) ||
            (Build.VERSION.SDK_INT >= 31 && !manager.canScheduleExactAlarms()))) return false
        val prefs = context.getSharedPreferences(PREF, Context.MODE_PRIVATE)
        prefs.edit().putString("alarms", JSONArray(alarms).toString()).apply()
        for (code in prefs.getString("codes", "")!!.split(',').mapNotNull { it.toIntOrNull() }) {
            val old = PendingIntent.getBroadcast(context, code,
                Intent(context, AutoRecordReceiver::class.java).setAction(AutoRecordReceiver.ACTION_AUTO_RECORD_START),
                PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE)
            if (old != null) { manager.cancel(old); old.cancel() }
        }
        val codes = mutableListOf<Int>()
        for (item in alarms) {
            val start = item["startTime"]?.toString()?.let { ScheduleWidgetLogic.minutes(it) }
            val date = item["classDate"]?.toString()
            val trigger = if (date != null && start != null)
                LocalDate.parse(date).atStartOfDay(ZoneId.systemDefault()).plusMinutes(start.toLong()).toInstant().toEpochMilli()
                else (item["triggerEpochMs"] as? Number)?.toLong() ?: 0L
            if (trigger <= System.currentTimeMillis()) continue
            val courseId = item["courseId"] as? String ?: continue
            val sessionId = "rec_auto_${courseId}_$trigger"
            val intent = Intent(context, AutoRecordReceiver::class.java).setAction(AutoRecordReceiver.ACTION_AUTO_RECORD_START)
                .putExtra(AutoRecordReceiver.EXTRA_COURSE_NAME, item["courseName"] as? String ?: "课程")
                .putExtra(AutoRecordReceiver.EXTRA_COURSE_ID, courseId)
                .putExtra(AutoRecordReceiver.EXTRA_LOCATION, item["location"] as? String ?: "")
                .putExtra(AutoRecordReceiver.EXTRA_SESSION_ID, sessionId)
                .putExtra(AutoRecordReceiver.EXTRA_DURATION_MS, (item["durationMs"] as? Number)?.toLong() ?: 90 * 60000L)
            val pending = PendingIntent.getBroadcast(context, sessionId.hashCode(), intent, PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            manager.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, trigger, pending)
            codes.add(sessionId.hashCode())
        }
        prefs.edit().putString("codes", codes.joinToString(",")).apply()
        return true
    }
}
