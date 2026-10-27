package schedule

import org.junit.Assert.*
import org.junit.Test
import java.time.LocalDate
import java.time.ZonedDateTime

class CourseReminderPlanTest {
    @Test fun configuredSemesterLimitAppliesEvenToEmptyWeeks() {
        val begin = LocalDate.of(2026,8,31)
        val clock = ZonedDateTime.parse("2026-08-31T06:00:00+08:00[Asia/Shanghai]")
        val weekly = ReminderCourse("weekly","每周课","A101",1,495,590,emptySet())
        val result = CourseReminderPlan.build(listOf(weekly),begin,clock,2)
        assertEquals(2,result.size)
        assertTrue(CourseReminderPlan.build(listOf(weekly),begin,clock.plusWeeks(2),2).isEmpty())
    }
    private val semester = LocalDate.of(2026, 8, 31)
    private val now = ZonedDateTime.parse("2026-10-12T06:00:00+08:00[Asia/Shanghai]")
    private val course = ReminderCourse("mechanics", "工程力学", "教学楼4-402", 1, 495, 590, setOf(7,12,19))
    @Test fun offlinePlanIncludesFutureSemesterAndExpandedDetails() {
        val result = CourseReminderPlan.build(listOf(course), semester, now)
        assertEquals(3, result.size)
        assertEquals("教学楼4-402", result.first().course.location)
        assertEquals(95 * 60000L, result.first().endMs - result.first().startMs)
        assertEquals(LocalDate.of(2027,1,4), java.time.Instant.ofEpochMilli(result.last().startMs).atZone(now.zone).toLocalDate())
    }
    @Test fun remindersDoNotDependOnRecordingFlagsAndExcludeUnconfirmedOrCancelledClasses() {
        assertEquals(1, CourseReminderPlan.build(listOf(course.copy(weeks=setOf(7))), semester, now).size)
        assertTrue(CourseReminderPlan.build(listOf(course.copy(confirmed=false)), semester, now).isEmpty())
        assertTrue(CourseReminderPlan.build(listOf(course.copy(weeks=setOf(6))), semester, now).isEmpty())
        assertTrue(CourseReminderPlan.build(listOf(course.copy(start=null)), semester, now).isEmpty())
    }
    @Test fun refreshDoesNotDuplicateOrReplayPastClassStarts() {
        assertEquals(3, CourseReminderPlan.build(listOf(course,course), semester, now).size)
        assertEquals(2, CourseReminderPlan.build(listOf(course), semester, now.withHour(9)).size)
    }
}
