package audio

import android.Manifest
import android.app.Application
import android.app.NotificationManager
import android.content.Context
import android.os.Looper
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.Shadows.shadowOf
import org.robolectric.android.controller.ServiceController
import org.robolectric.annotation.Config
import org.robolectric.annotation.LooperMode

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [28])
@LooperMode(LooperMode.Mode.PAUSED)
class RecordingCountdownTest {
    private lateinit var app: Application
    private lateinit var repository: RecordingRepository
    private var controller: ServiceController<AudioRecordService>? = null

    @Before fun setup() {
        app = RuntimeEnvironment.getApplication()
        repository = RecordingRepository(app)
        shadowOf(app).grantPermissions(Manifest.permission.RECORD_AUDIO)
        AudioRecordService.activeInstance = null
    }

    @After fun cleanup() {
        controller?.destroy()
        AudioRecordService.activeInstance = null
    }

    private fun audio(session: String): File =
        repository.createAudioFile(session, "aac").apply { writeText("fictional audio") }

    private fun service(clock: () -> Long): AudioRecordService {
        val created = Robolectric.buildService(AudioRecordService::class.java).create()
        controller = created
        return created.get().also { it.elapsedRealtimeProvider = clock }
    }

    @Test fun countdownStopSavesFileEmitsAutoStoppedAndNotifies() {
        var now = 10_000L
        val record = service { now }
        val file = audio("rec_physics_countdown_stop")
        val events = mutableListOf<Pair<String, Map<String, Any?>>>()
        record.setEventListener { type, data -> events.add(type to data) }

        assertTrue(
            record.startManual(
                courseId = "physics",
                sessionId = "rec_physics_countdown_stop",
                file = file,
                durationLimitMs = 6_000_000L, // 100 minutes (1h 40m)
                limitAction = AudioRecordService.LIMIT_ACTION_STOP
            )
        )

        now += 3_000_000L
        record.evaluateCountdownTick()
        val midStatus = record.getStatus()
        assertEquals(true, midStatus["isRecording"])
        assertEquals(3_000_000L, midStatus["remainingMs"])
        assertEquals("stop", midStatus["limitAction"])
        assertEquals(false, midStatus["limitTriggered"])
        assertFalse(events.any { it.first == "autoStopped" })

        now += 3_000_000L
        record.evaluateCountdownTick()

        val endStatus = record.getStatus()
        assertEquals(false, endStatus["isRecording"])
        assertNull(endStatus["durationLimitMs"])
        assertTrue(file.exists())

        val stopped = events.single { it.first == "autoStopped" }.second
        assertEquals(file.absolutePath, stopped["filePath"])
        assertEquals("physics", stopped["courseId"])
        assertEquals(AudioRecordService.STOP_REASON_COUNTDOWN, stopped["reason"])

        val nm = app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val doneNotification = shadowOf(nm).getNotification(AudioRecordService.COUNTDOWN_DONE_NOTIFICATION_ID)
        assertNotNull(doneNotification)
        assertNotNull(doneNotification.contentIntent)
    }

    @Test fun countdownPausePausesSessionAndResumeContinuesWithoutRepausing() {
        var now = 20_000L
        val record = service { now }
        val file = audio("rec_mechanics_countdown_pause")
        val events = mutableListOf<Pair<String, Map<String, Any?>>>()
        record.setEventListener { type, data -> events.add(type to data) }

        assertTrue(
            record.startManual(
                courseId = "mechanics",
                sessionId = "rec_mechanics_countdown_pause",
                file = file,
                durationLimitMs = 6_000_000L,
                limitAction = AudioRecordService.LIMIT_ACTION_PAUSE
            )
        )

        now += 6_000_000L
        record.evaluateCountdownTick()
        shadowOf(Looper.getMainLooper()).idle()

        val pausedStatus = record.getStatus()
        assertEquals(true, pausedStatus["isRecording"])
        assertEquals(true, pausedStatus["isPaused"])
        assertEquals(0L, pausedStatus["remainingMs"])
        assertEquals(true, pausedStatus["limitTriggered"])
        assertEquals("pause", pausedStatus["limitAction"])
        assertFalse(events.any { it.first == "autoStopped" })
        assertTrue(events.any { it.first == "countdownPaused" })

        // Resume after countdown pause should keep recording freely without re-pausing.
        record.resume()
        shadowOf(Looper.getMainLooper()).idle()
        now += 120_000L
        record.evaluateCountdownTick()
        val resumedStatus = record.getStatus()
        assertEquals(true, resumedStatus["isRecording"])
        assertEquals(false, resumedStatus["isPaused"])
        assertEquals(6_120_000L, resumedStatus["elapsedMs"])
        assertEquals(true, resumedStatus["limitTriggered"])

        // Manual stop after resuming must not emit autoStopped (prevents duplicate enqueue).
        val manualStopResult = record.stop()
        assertEquals(true, manualStopResult["success"])
        assertFalse(events.any { it.first == "autoStopped" })
    }

    @Test fun manualPauseFreezesCountdownUntilResumed() {
        var now = 5_000L
        val record = service { now }
        val file = audio("rec_ee_manual_pause")

        assertTrue(
            record.startManual(
                courseId = "ee",
                sessionId = "rec_ee_manual_pause",
                file = file,
                durationLimitMs = 120_000L,
                limitAction = AudioRecordService.LIMIT_ACTION_STOP
            )
        )

        now += 40_000L
        record.pause()
        shadowOf(Looper.getMainLooper()).idle()
        assertEquals(40_000L, record.getStatus()["elapsedMs"])
        assertEquals(80_000L, record.getStatus()["remainingMs"])

        // Time passing while paused must not consume countdown.
        now += 300_000L
        record.evaluateCountdownTick()
        assertEquals(true, record.getStatus()["isRecording"])
        assertEquals(true, record.getStatus()["isPaused"])
        assertEquals(80_000L, record.getStatus()["remainingMs"])

        record.resume()
        shadowOf(Looper.getMainLooper()).idle()
        now += 79_000L
        record.evaluateCountdownTick()
        assertEquals(true, record.getStatus()["isRecording"])
        assertEquals(1_000L, record.getStatus()["remainingMs"])

        now += 1_000L
        record.evaluateCountdownTick()
        assertEquals(false, record.getStatus()["isRecording"])
    }

    @Test fun discardCancelsTimedRecordingWithoutAutoStoppedOrDoneNotification() {
        var now = 1_000L
        val record = service { now }
        val session = "rec_linear_discard"
        val file = audio(session)
        val events = mutableListOf<String>()
        record.setEventListener { type, _ -> events.add(type) }

        assertTrue(
            record.startManual(
                courseId = "linear",
                sessionId = session,
                file = file,
                durationLimitMs = 60_000L,
                limitAction = AudioRecordService.LIMIT_ACTION_STOP
            )
        )
        assertTrue(record.discardRecording(session))
        assertFalse(file.exists())
        assertFalse(events.contains("autoStopped"))
        val nm = app.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        assertNull(shadowOf(nm).getNotification(AudioRecordService.COUNTDOWN_DONE_NOTIFICATION_ID))
    }

    @Test fun channelRejectsInvalidCountdownArguments() {
        var now = 1_000L
        val record = service { now }
        val plugin = RecordingBridgePlugin()
        RecordingBridgePlugin::class.java.getDeclaredField("repository")
            .apply { isAccessible = true }.set(plugin, repository)
        RecordingBridgePlugin::class.java.getDeclaredField("audioService")
            .apply { isAccessible = true }.set(plugin, record)

        fun invoke(args: Map<String, Any?>): String? {
            var errorCode: String? = null
            plugin.onMethodCall(
                MethodCall("startRecording", args),
                object : MethodChannel.Result {
                    override fun success(result: Any?) { fail("Expected INVALID_ARGS error") }
                    override fun error(code: String, message: String?, details: Any?) { errorCode = code }
                    override fun notImplemented() { fail("startRecording must be implemented") }
                }
            )
            return errorCode
        }

        assertEquals(
            "INVALID_ARGS",
            invoke(mapOf("courseId" to "c1", "durationLimitMs" to 0L, "limitAction" to "stop"))
        )
        assertEquals(
            "INVALID_ARGS",
            invoke(mapOf("courseId" to "c1", "durationLimitMs" to 30_000L, "limitAction" to "stop"))
        )
        assertEquals(
            "INVALID_ARGS",
            invoke(mapOf("courseId" to "c1", "durationLimitMs" to (7 * 60 * 60 * 1000L)))
        )
        assertEquals(
            "INVALID_ARGS",
            invoke(mapOf("courseId" to "c1", "durationLimitMs" to 60_000L, "limitAction" to "delete"))
        )
        assertEquals(false, record.getStatus()["isRecording"])
    }
}
