package schedule

import java.time.ZonedDateTime
import java.time.LocalDate
import java.time.temporal.ChronoUnit

data class ReminderCourse(val id: String, val name: String, val location: String,
    val weekday: Int, val start: Int?, val end: Int?, val weeks: Set<Int>, val confirmed: Boolean = true)
data class CourseOccurrence(val id: String, val course: ReminderCourse, val startMs: Long, val endMs: Long)

object CourseReminderPlan {
    fun build(courses: List<ReminderCourse>, semester: LocalDate, now: ZonedDateTime, semesterWeeks: Int = 30): List<CourseOccurrence> {
        val lastWeek = semesterWeeks.coerceIn(1,30)
        val end = semester.plusWeeks(lastWeek.toLong())
        val days = ChronoUnit.DAYS.between(now.toLocalDate(), end).coerceIn(0, 365)
        val result = linkedMapOf<String, CourseOccurrence>()
        for (offset in 0..days) {
            val date = now.toLocalDate().plusDays(offset)
            val week = (ChronoUnit.DAYS.between(semester, date) / 7 + 1).toInt()
            if (date.isBefore(semester) || !date.isBefore(end)) continue
            for (course in courses) {
                val start = course.start ?: continue; val finish = course.end ?: continue
                if (!course.confirmed || course.id.isBlank() || finish <= start ||
                    course.weekday != date.dayOfWeek.value || (course.weeks.isNotEmpty() && week !in course.weeks)) continue
                val startMs = date.atStartOfDay(now.zone).plusMinutes(start.toLong()).toInstant().toEpochMilli()
                val endMs = date.atStartOfDay(now.zone).plusMinutes(finish.toLong()).toInstant().toEpochMilli()
                if (startMs <= now.toInstant().toEpochMilli()) continue
                val id = "course_${course.id}_$startMs"
                result[id] = CourseOccurrence(id, course, startMs, endMs)
            }
        }
        return result.values.sortedBy { it.startMs }
    }
}
