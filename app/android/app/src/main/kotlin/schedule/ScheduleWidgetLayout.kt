package schedule

import android.content.Context
import android.graphics.Typeface
import android.text.TextPaint
import android.text.TextUtils
import android.util.TypedValue
import android.view.View
import android.widget.RemoteViews
import android.widget.TextView
import com.classnotes.assistant.R
import kotlin.math.ceil
import kotlin.math.min
import kotlin.math.roundToInt

/** Xiaomi design pixels are physical pixels; host sizes are runtime dp. */
object ScheduleWidgetLayout {
    fun create(context: Context, widthDp: Float, heightDp: Float, screenWidthDp: Float,
        term: String, date: String, state: WidgetState, footer: String): RemoteViews {
        val metrics = context.resources.displayMetrics
        val hostWidth = (widthDp * metrics.density).roundToInt().coerceAtLeast(1)
        val hostHeight = (heightDp * metrics.density).roundToInt().coerceAtLeast(1)
        // A 2x2 cell allocation is not physically square. Keep the visible card
        // square inside it; explicit wide desktop expansions retain their layout.
        val wide = widthDp >= heightDp * 1.7f
        val side = min(hostWidth, hostHeight)
        val cardWidth = if (wide) hostWidth else side
        val cardHeight = if (wide) hostHeight else side
        val leftInset = (hostWidth - cardWidth) / 2
        val topInset = (hostHeight - cardHeight) / 2
        // 42px at 1080p, 56px at 1440p (>= the specified 55px).
        // Use the physical screen ratio, including custom display-density settings.
        val padding = ceil(screenWidthDp * 42f / 1080f * metrics.density).toInt()
        val width = (cardWidth - 2 * padding).coerceAtLeast(1)
        val height = (cardHeight - 2 * padding).toFloat().coerceAtLeast(1f)
        val views = RemoteViews(context.packageName, R.layout.schedule_widget)
        // Root stays transparent and has no launch action. Padding constrains the
        // inner background on API24+ without custom views or API31 size setters.
        views.setViewPadding(R.id.widget_host, leftInset, topInset,
            hostWidth - cardWidth - leftInset, hostHeight - cardHeight - topInset)
        views.setViewPadding(android.R.id.background, padding, padding, padding, padding)
        val cardWidthDp = cardWidth / metrics.density
        val cardHeightDp = cardHeight / metrics.density
        val roomy = cardWidthDp >= 240f && cardHeightDp >= 140f
        // A narrow, large-text card gets a separate hierarchy, rather than scaling
        // all fonts down or capping fontScale. At 200%, 10.25sp becomes 20.5sp (>17sp).
        val fontScale = context.resources.configuration.fontScale
        val largeTextSummary = cardWidthDp < 160f && fontScale > 1.2f
        // Smoothly increase the actual glyph sizes, avoiding a sudden decrease
        // when a font-size setting crosses an adaptive-layout threshold.
        fun summarySize(normal: Float, large: Float): Float = when {
            !largeTextSummary -> normal
            fontScale >= 2f -> large
            else -> (normal * 1.2f + (large * 2f - normal * 1.2f) * (fontScale - 1.2f) / 0.8f) / fontScale
        }
        val sizes = mapOf(R.id.widget_label to summarySize(11f, 8.5f),
            R.id.widget_course to if (roomy) 21f else summarySize(17f, 10.25f),
            R.id.widget_room to 12f, R.id.widget_time to 13f, R.id.widget_term to 10f,
            R.id.widget_date to 10f, R.id.widget_footer to 10f)
        // Preserve real user font scaling using SP, with no 1.15 cap or DIP substitution.
        for ((id, size) in sizes) views.setTextViewTextSize(id, TypedValue.COMPLEX_UNIT_SP, size)
        fun paint(id: Int) = TextPaint().apply {
            textSize = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_SP, sizes.getValue(id), metrics)
            typeface = if (id == R.id.widget_course) Typeface.DEFAULT_BOLD else Typeface.DEFAULT
        }
        fun measured(text: String, id: Int, lines: Int = 1): Float {
            if (text.isEmpty()) return 0f
            // Use the same TextView measurement as RemoteViews, including fallback
            // glyph metrics and Android's font scaling; StaticLayout can undercount.
            return TextView(context).apply {
                this.text = text
                setTextSize(TypedValue.COMPLEX_UNIT_SP, sizes.getValue(id))
                typeface = paint(id).typeface
                includeFontPadding = false
                maxLines = lines
                ellipsize = TextUtils.TruncateAt.END
                minHeight = 0
                setPadding(0, 0, 0, 0)
                measure(View.MeasureSpec.makeMeasureSpec(width, View.MeasureSpec.EXACTLY),
                    View.MeasureSpec.makeMeasureSpec(0, View.MeasureSpec.UNSPECIFIED))
            }.measuredHeight.toFloat()
        }
        val course = state.course
        val title = course?.name ?: if (largeTextSummary) when (state.label) {
            "尚未同步" -> "同步"
            "同步异常" -> "重试"
            "未开学" -> "未开学"
            "今日完成" -> "完成"
            "时间待完善" -> "待定"
            else -> "休息"
        } else state.message
        val room = course?.location?.ifBlank { "教室待定" } ?: ""
        val time = if (course == null) "" else "${ScheduleWidgetLogic.time(course.start)}–${ScheduleWidgetLogic.time(course.end)}"
        val label = if (paint(R.id.widget_label).measureText(state.label) <= width) state.label else when (state.label) {
            "正在上课" -> "上课中"
            "下一节课" -> "下一课"
            "尚未同步" -> "未同步"
            "时间待完善" -> "时间待定"
            else -> state.label
        }
        val statusHeight = measured(label, R.id.widget_label)
        val timeLines = if (paint(R.id.widget_time).measureText(time) <= width) 1 else 2
        val displayedTime = if (timeLines == 2) time.replace("–", "–\n") else time
        var titleLines = 2
        if (statusHeight + measured(title, R.id.widget_course, 2) + measured(displayedTime, R.id.widget_time, timeLines) > height)
            titleLines = 1
        var used = statusHeight + measured(title, R.id.widget_course, titleLines)
        val showTime = time.isNotEmpty() && used + measured(displayedTime, R.id.widget_time, timeLines) <= height
        if (showTime) used += measured(displayedTime, R.id.widget_time, timeLines)
        else if (statusHeight + measured(title, R.id.widget_course, 2) <= height) {
            // If the time still cannot fit, use the freed space for a readable title.
            titleLines = 2
            used = statusHeight + measured(title, R.id.widget_course, titleLines)
        }
        val showRoom = room.isNotEmpty() && used + measured(room, R.id.widget_room) <= height
        if (showRoom) used += measured(room, R.id.widget_room)
        // Metadata yields to the current/next course and its state, time and room.
        val showHeader = used + measured(date, R.id.widget_date) + 4 * metrics.density <= height
        if (showHeader) used += measured(date, R.id.widget_date) + 4 * metrics.density
        val showFooter = footer.isNotEmpty() && used + measured(footer, R.id.widget_footer) + 4 * metrics.density <= height
        views.setTextViewText(R.id.widget_term, term)
        views.setTextViewText(R.id.widget_date, date)
        views.setTextViewText(R.id.widget_label, label)
        views.setTextViewText(R.id.widget_course, title)
        views.setTextViewText(R.id.widget_room, room)
        views.setTextViewText(R.id.widget_time, displayedTime)
        views.setTextViewText(R.id.widget_footer, footer)
        views.setInt(R.id.widget_course, "setMaxLines", titleLines)
        views.setInt(R.id.widget_time, "setMaxLines", timeLines)
        fun visible(id: Int, show: Boolean) = views.setViewVisibility(id, if (show) View.VISIBLE else View.GONE)
        visible(R.id.widget_label, label.isNotEmpty())
        visible(R.id.widget_time, showTime)
        visible(R.id.widget_room, showRoom)
        visible(R.id.widget_header, showHeader)
        visible(R.id.widget_term, showHeader && paint(R.id.widget_term).measureText(term) + paint(R.id.widget_date).measureText(date) + 8 * metrics.density <= width)
        visible(R.id.widget_footer, showFooter)
        // Extremely small cards at 200% become a readable summary. TalkBack and
        // the existing whole-card course-table link retain the complete snapshot.
        views.setContentDescription(android.R.id.background,
            listOf(term, date, state.label, course?.name ?: state.message, room, time, footer, "点击查看课表")
                .filter { it.isNotBlank() }.joinToString("，"))
        return views
    }
}
