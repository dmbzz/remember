package schedule

import java.time.LocalDate
import java.time.temporal.ChronoUnit

data class WidgetCourse(val name: String, val location: String, val weekday: Int,
    val start: Int?, val end: Int?, val weeks: Set<Int>, val confirmed: Boolean = true)
data class WidgetState(val label: String, val course: WidgetCourse?, val message: String,
    val count: Int, val nextMinute: Int?)

object ScheduleWidgetLogic {
    fun minutes(value: String): Int? {
        val match = Regex("^(\\d{1,2}):(\\d{2})(?::\\d{2})?$").matchEntire(value) ?: return null
        val h = match.groupValues[1].toInt(); val m = match.groupValues[2].toInt()
        return if (h in 0..23 && m in 0..59) h * 60 + m else null
    }
    fun state(courses: List<WidgetCourse>, semester: LocalDate, today: LocalDate, minute: Int, semesterWeeks: Int = 30): WidgetState {
        val days = ChronoUnit.DAYS.between(semester, today)
        if (days < 0) return WidgetState("未开学", null, "学期还没开始", 0, null)
        val week = (days / 7 + 1).toInt()
        if (week > semesterWeeks) return WidgetState("学期结束",null,"本学期课程已结束",0,null)
        val entries = courses.filter { it.confirmed && it.weekday == today.dayOfWeek.value &&
            (it.weeks.isEmpty() || week in it.weeks) }
        val valid = entries.filter { it.start != null && it.end != null && it.end > it.start }.sortedBy { it.start }
        val current = valid.firstOrNull { minute >= it.start!! && minute < it.end!! }
        val next = valid.firstOrNull { minute < it.start!! }
        val boundary = valid.flatMap { listOf(it.start!!, it.end!!) }.filter { it > minute }.minOrNull()
        val unknown = valid.size != entries.size
        return when {
            current != null -> WidgetState("正在上课", current, "", entries.size, boundary)
            next != null -> WidgetState("下一节课", next, "", entries.size, boundary)
            unknown -> WidgetState("时间待完善", null, "课程时间待补充", entries.size, boundary)
            entries.isEmpty() -> WidgetState("", null, "今天没有课啦", 0, null)
            else -> WidgetState("今日完成", null, "今天的课上完啦", entries.size, null)
        }
    }
    fun time(value: Int?): String = if (value == null) "待定" else "%02d:%02d".format(value / 60, value % 60)
}
