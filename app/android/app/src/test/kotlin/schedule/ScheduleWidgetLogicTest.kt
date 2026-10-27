package schedule

import org.junit.Assert.*
import org.junit.Test
import java.time.LocalDate

class ScheduleWidgetLogicTest {
    @Test fun configuredSemesterEndDoesNotShowWeeklyLessonsAfterTerm() {
        val start=LocalDate.of(2026,8,31)
        val value=WidgetCourse("每周课","A101",1,495,590,emptySet())
        assertEquals(1,ScheduleWidgetLogic.state(listOf(value),start,start,490,2).count)
        val state=ScheduleWidgetLogic.state(listOf(value),start,start.plusWeeks(2),490,2)
        assertEquals(0,state.count)
        assertEquals("学期结束",state.label)
    }
    private val semester = LocalDate.of(2026, 8, 31)
    private val friday = LocalDate.of(2026, 10, 9)
    private fun course(weeks: Set<Int> = setOf(6), start: String = "08:15", end: String = "09:50", day: Int = 5) =
        WidgetCourse("工程力学", "教学楼4-402", day, ScheduleWidgetLogic.minutes(start), ScheduleWidgetLogic.minutes(end), weeks)
    @Test fun nextCurrentAndFinishedRespectBoundaries() {
        val list = listOf(course())
        assertEquals("下一节课", ScheduleWidgetLogic.state(list, semester, friday, 494).label)
        val now = ScheduleWidgetLogic.state(list, semester, friday, 495)
        assertEquals("正在上课", now.label); assertEquals(590, now.nextMinute)
        assertEquals("教学楼4-402", now.course!!.location)
        assertEquals("今天的课上完啦", ScheduleWidgetLogic.state(list, semester, friday, 590).message)
    }
    @Test fun cancelledWeeksOddWeeksAndPreSemesterAreNotClasses() {
        assertEquals(0, ScheduleWidgetLogic.state(listOf(course(setOf(1,3,5,7))), semester, friday, 495).count)
        assertEquals(0, ScheduleWidgetLogic.state(listOf(course(setOf(1,2,3,4,5,7,8,9))), semester, friday, 495).count)
        assertEquals(0, ScheduleWidgetLogic.state(listOf(course().copy(confirmed = false)), semester, friday, 495).count)
        assertEquals("未开学", ScheduleWidgetLogic.state(listOf(course()), semester, semester.minusDays(1), 0).label)
    }
    @Test fun sundayToMondayUsesCalendarDates() {
        val monday = course(setOf(7), day = 1)
        assertNull(ScheduleWidgetLogic.state(listOf(monday), semester, LocalDate.of(2026,10,11), 500).course)
        assertNotNull(ScheduleWidgetLogic.state(listOf(monday), semester, LocalDate.of(2026,10,12), 500).course)
    }
    @Test fun malformedOrMissingTimesNeverPretendThereAreNoClasses() {
        assertNull(ScheduleWidgetLogic.minutes("24:00")); assertNull(ScheduleWidgetLogic.minutes("08:90"))
        val unknown = ScheduleWidgetLogic.state(listOf(course(start = "待定")), semester, friday, 500)
        assertEquals("时间待完善", unknown.label); assertEquals(1, unknown.count)
        assertEquals("14:15", ScheduleWidgetLogic.time(855))
    }
}
