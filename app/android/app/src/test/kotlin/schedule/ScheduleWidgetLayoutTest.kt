package schedule

import android.content.Context
import android.app.PendingIntent
import android.app.Activity
import android.content.Intent
import android.content.res.Configuration
import android.graphics.Bitmap
import android.graphics.Canvas
import android.view.View
import android.view.ViewGroup
import android.view.MotionEvent
import android.widget.FrameLayout
import android.widget.TextView
import com.classnotes.assistant.R
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Robolectric
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import java.io.File

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [33])
@GraphicsMode(GraphicsMode.Mode.NATIVE)
class ScheduleWidgetLayoutTest {
    private fun context(density: Float, font: Float, night: Boolean): Context {
        val base = RuntimeEnvironment.getApplication()
        val cfg = Configuration(base.resources.configuration).apply {
            fontScale = font
            densityDpi = (density * 160).toInt()
            uiMode = Configuration.UI_MODE_TYPE_NORMAL or if (night) Configuration.UI_MODE_NIGHT_YES else Configuration.UI_MODE_NIGHT_NO
        }
        return base.createConfigurationContext(cfg).also {
            it.resources.displayMetrics.apply {
                this.density = density
                scaledDensity = density * font
            }
        }
    }
    private fun render(px: Int, density: Float, font: Float, night: Boolean, name: String, empty: Boolean = false,
        screenPx: Int = if (density == 4f) 1440 else 1080, heightPx: Int = px,
        emptyLabel: String = "尚未同步", emptyMessage: String = "打开应用同步课表"): View {
        val context = context(density, font, night)
        val state = if (empty) WidgetState(emptyLabel, null, emptyMessage, 0, null) else
            WidgetState("下一节课", WidgetCourse(name, "教学楼4-402", 3, 495, 590, emptySet()), "", 3, 495)
        val views = ScheduleWidgetLayout.create(context, px / density, heightPx / density,
            screenPx / density,
            "大二上（2026–2027）", "10–14 周三", state, "课表缓存 · 10/13同步")
        views.setOnClickPendingIntent(android.R.id.background, PendingIntent.getActivity(context, 9910,
            Intent().setClassName(context.packageName, "com.classnotes.assistant.MainActivity")
                .putExtra("open_schedule", true), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT))
        val root = views.apply(context, FrameLayout(context))
        root.measure(View.MeasureSpec.makeMeasureSpec(px, View.MeasureSpec.EXACTLY), View.MeasureSpec.makeMeasureSpec(heightPx, View.MeasureSpec.EXACTLY))
        root.layout(0, 0, px, heightPx)
        val card = root.findViewById<View>(android.R.id.background)
        fun verify(view: View, parentY: Int) {
            if (view.visibility != View.VISIBLE) return
            val top = parentY + view.top
            if (view is TextView) {
                assertTrue("Vertical clipping: ${view.text} ($px,font=$font), top=$top,bottom=${top + view.height}", top >= card.top + card.paddingTop && top + view.height <= card.bottom - card.paddingBottom)
                assertTrue("Text overflow: ${view.text}", view.layout.height <= view.height)
                if (view.id == R.id.widget_time || view.id == R.id.widget_label)
                    for (line in 0 until view.lineCount) assertEquals("Essential text ellipsized: ${view.text}", 0, view.layout.getEllipsisCount(line))
            }
            if (view is ViewGroup) for (i in 0 until view.childCount) verify(view.getChildAt(i), top)
        }
        verify(root, 0)
        assertEquals(if (state.label.isEmpty()) View.GONE else View.VISIBLE, root.findViewById<View>(R.id.widget_label).visibility)
        if (!empty) {
            assertTrue(card.contentDescription.contains("工程") || card.contentDescription.contains(name))
            assertTrue(card.contentDescription.contains("教学楼4-402"))
            assertTrue(card.contentDescription.contains("08:15–09:50"))
        }
        val expectedPadding = if (screenPx == 1440) 55 else 42
        assertTrue("Unsafe padding: ${card.paddingLeft}", card.paddingLeft >= expectedPadding)
        val output = File(System.getProperty("widget.output", "../widget-test-images"))
        output.mkdirs()
        val bitmap = Bitmap.createBitmap(px, heightPx, Bitmap.Config.ARGB_8888)
        root.draw(Canvas(bitmap))
        File(output, "widget-${px}x${heightPx}-${density}-$font-$night-${if (empty) "empty" else "course"}.png").outputStream().use {
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, it)
        }
        return root
    }
    @Test fun officialSizesAndLargeFontsPreserveBoundsAndCompleteAccessibility() {
        for (density in listOf(3f, 2.75f)) for (px in listOf(334, 412, 424, 440))
            for (font in listOf(1f, 2f)) render(px, density, font, false, "工程力学与空间力系的简化")
        for (px in listOf(444, 548, 562, 584)) for (font in listOf(1f, 2f))
            render(px, 4f, font, true, "工程力学与空间力系的简化")
    }
    @Test fun emptyStatesDoNotClipAtSmallAndLargeFonts() {
        for (font in listOf(1f, 2f)) render(334, 3f, font, true, "", true)
    }
    @Test fun smallCardHasRealLargeFontsRatherThanTheOldCap() {
        val ordinary = render(334, 3f, 1f, false, "工程力学")
        val large = render(334, 3f, 2f, false, "工程力学")
        assertTrue(large.findViewById<TextView>(R.id.widget_course).textSize >
            ordinary.findViewById<TextView>(R.id.widget_course).textSize * 1.15f)
        assertEquals(20.5f * 3, large.findViewById<TextView>(R.id.widget_course).textSize, 0.5f)
        val title = large.findViewById<TextView>(R.id.widget_course)
        assertEquals("Two-line summary should show the complete course", 0, title.layout.getEllipsisCount(title.lineCount - 1))
    }
    @Test fun displayDensityChangesAndWideWidgetsUsePhysicalScreenSafetyMargins() {
        render(334, 2f, 1f, false, "工程力学", screenPx = 1080)
        render(444, 2.5f, 2f, true, "工程力学", screenPx = 1440)
        for (font in listOf(1f, 2f)) {
            render(918, 3f, font, false, "工程力学", heightPx = 412)
            render(918, 3f, font, true, "工程力学", heightPx = 918)
        }
    }
    @Test fun narrowFontHierarchyIncreasesSmoothlyAsSystemFontGrows() {
        var previous = 0f
        for (font in listOf(1f, 1.2f, 1.3f, 1.5f, 1.6f, 1.8f, 2f)) {
            val root = render(334, 3f, font, false, "工程力学")
            val title = root.findViewById<TextView>(R.id.widget_course)
            assertTrue("Larger font setting made text smaller", title.textSize >= previous)
            previous = title.textSize
        }
    }
    @Test fun emptySummaryStatesHaveRecognizableActionsAndCompleteDescriptions() {
        for ((label, message) in listOf("尚未同步" to "打开应用同步课表", "同步异常" to "打开应用重新同步",
            "未开学" to "学期还没开始", "今日完成" to "今天的课上完啦", "时间待完善" to "课程时间待补充", "" to "今天没有课啦")) {
            val root = render(334, 3f, 2f, true, "", true, emptyLabel = label, emptyMessage = message)
            val title = root.findViewById<TextView>(R.id.widget_course)
            assertEquals(0, title.layout.getEllipsisCount(title.lineCount - 1))
            assertTrue(root.findViewById<View>(android.R.id.background).contentDescription.contains(message))
        }
    }
    @Test fun portraitAndLandscapeTwoCellSlotsKeepSquareVisibleBackground() {
        for ((w, h) in listOf(580 to 673, 673 to 580)) for (font in listOf(1f, 2f)) for (dark in listOf(false, true)) {
            val root = render(w, 4f, font, dark, "工程力学", screenPx = 1440, heightPx = h)
            val card = root.findViewById<View>(android.R.id.background)
            assertEquals(580, card.width)
            assertEquals(580, card.height)
            assertTrue(kotlin.math.abs(card.left - (w - card.right)) <= 1)
            assertTrue(kotlin.math.abs(card.top - (h - card.bottom)) <= 1)
            assertNull(root.background)
            assertFalse(root.isClickable)
            assertFalse(root.isFocusable)
            assertEquals(View.IMPORTANT_FOR_ACCESSIBILITY_NO, root.importantForAccessibility)
            assertTrue(card.clipToOutline)
        }
        render(580, 4f, 1f, false, "", true, screenPx = 1440, heightPx = 673,
            emptyLabel = "", emptyMessage = "今天没有课啦")
    }
    @Test fun wideExpansionAndItsBoundaryHaveExplicitGeometry() {
        for ((w, h, square) in listOf(Triple(1019, 600, true), Triple(1020, 600, false), Triple(1220, 548, false))) {
            val root = render(w, 4f, 1f, false, "工程力学", screenPx = 1440, heightPx = h)
            val card = root.findViewById<View>(android.R.id.background)
            assertEquals(if (square) h else w, card.width)
            assertEquals(h, card.height)
        }
    }
    @Test fun transparentMarginsDoNotLaunchButCardTapOpensSchedule() {
        val root = render(580, 4f, 1f, false, "工程力学", screenPx = 1440, heightPx = 673)
        val controller = Robolectric.buildActivity(Activity::class.java).setup().visible()
        controller.get().setContentView(root)
        shadowOf(android.os.Looper.getMainLooper()).idle()
        root.measure(View.MeasureSpec.makeMeasureSpec(580, View.MeasureSpec.EXACTLY),
            View.MeasureSpec.makeMeasureSpec(673, View.MeasureSpec.EXACTLY))
        root.layout(0, 0, 580, 673)
        val application = RuntimeEnvironment.getApplication()
        fun tap(x: Float, y: Float) {
            for (action in listOf(MotionEvent.ACTION_DOWN, MotionEvent.ACTION_UP)) {
                val event = MotionEvent.obtain(0, 0, action, x, y, 0)
                root.dispatchTouchEvent(event)
                event.recycle()
            }
            shadowOf(android.os.Looper.getMainLooper()).idle()
        }
        tap(290f, 10f)
        tap(290f, 663f)
        assertNull(shadowOf(application).nextStartedActivity)
        val bitmap = Bitmap.createBitmap(580, 673, Bitmap.Config.ARGB_8888)
        root.draw(Canvas(bitmap))
        assertEquals(0, android.graphics.Color.alpha(bitmap.getPixel(290, 10)))
        assertEquals(255, android.graphics.Color.alpha(bitmap.getPixel(290, 330)))
        assertTrue(root.findViewById<View>(android.R.id.background).isClickable)
        tap(290f, 330f)
        val launched = shadowOf(application).nextStartedActivity
        assertNotNull(launched)
        assertTrue(launched.getBooleanExtra("open_schedule", false))
        controller.pause().stop().destroy()
    }
    @Test fun genuineWideCardsDoNotBecomeSquareAtDifferentDisplayDensities() {
        for ((w, h, density) in listOf(Triple(740, 334, 3.25f), Triple(918, 412, 4f))) {
            val root = render(w, density, 1f, false, "工程力学", screenPx = if (density == 4f) 1440 else 1080, heightPx = h)
            val card = root.findViewById<View>(android.R.id.background)
            assertEquals(w, card.width)
            assertEquals(h, card.height)
        }
    }
}
