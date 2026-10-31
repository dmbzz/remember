package audio

import android.Manifest
import android.app.AlarmManager
import android.app.Application
import android.content.Context
import android.content.Intent
import android.content.ComponentName
import android.content.ServiceConnection
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.time.Duration
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
import org.robolectric.shadows.ShadowAlarmManager
import org.robolectric.shadows.ShadowSystemClock

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [28])
@LooperMode(LooperMode.Mode.PAUSED)
class AutoRecordBoundaryTest {
    private lateinit var app: Application
    private lateinit var manager: AlarmManager
    private var controller: ServiceController<AudioRecordService>? = null
    private val now get() = System.currentTimeMillis()
    private fun alarms() = shadowOf(manager).scheduledAlarms
    private fun item(start: Long, end: Long) = mapOf<String, Any?>(
        "courseId" to "fictional", "courseName" to "测试课程", "triggerEpochMs" to start,
        "endEpochMs" to end, "durationMs" to end - start)
    private fun startIntent(start: Long, end: Long) = Intent(app, AutoRecordReceiver::class.java).apply {
        action = AutoRecordReceiver.ACTION_AUTO_RECORD_START
        putExtra(AutoRecordReceiver.EXTRA_COURSE_ID, "fictional")
        putExtra(AutoRecordReceiver.EXTRA_COURSE_NAME, "测试课程")
        putExtra(AutoRecordReceiver.EXTRA_SESSION_ID, "rec_auto_fictional_$start")
        putExtra(AutoRecordReceiver.EXTRA_START_EPOCH_MS, start)
        putExtra(AutoRecordReceiver.EXTRA_END_EPOCH_MS, end)
    }
    private fun service(armed: Boolean = true): AudioRecordService {
        val created = Robolectric.buildService(AudioRecordService::class.java).create()
        controller = created
        return created.get().also { if (armed) it.arm() }
    }

    @Before fun setup() {
        app = RuntimeEnvironment.getApplication()
        app.getSharedPreferences("class_notes_record_alarms", Context.MODE_PRIVATE).edit().clear().commit()
        shadowOf(app).grantPermissions(Manifest.permission.RECORD_AUDIO)
        manager = app.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        ShadowAlarmManager.setAutoSchedule(false)
        AudioRecordService.activeInstance = null
    }
    @After fun cleanup() {
        controller?.destroy()
        AudioRecordService.activeInstance = null
    }

    @Test fun futureStartKeepsOriginalTimeAndAbsoluteEnd() {
        val start = now + 60000L
        val end = start + 3600000L
        assertTrue(AutoRecordAlarmStore.schedule(app, listOf(item(start, end))))
        val alarm = alarms().single()
        assertEquals(start, alarm.triggerAtTime)
        assertEquals(end, shadowOf(alarm.operation).savedIntent.getLongExtra(AutoRecordReceiver.EXTRA_END_EPOCH_MS, -1L))
    }

    @Test fun enablingExactlyAtStartCatchesUp() {
        val start = now
        assertTrue(AutoRecordAlarmStore.schedule(app, listOf(item(start, start + 3600000L)), nowMs = start))
        assertEquals(start, alarms().single().triggerAtTime)
    }

    @Test fun enablingAfterStartCatchesUpWithStableSession() {
        val at = now
        val start = at - 30000L
        val end = at + 100000L
        assertTrue(AutoRecordAlarmStore.schedule(app, listOf(item(start, end)), nowMs = at))
        val alarm = alarms().single()
        assertEquals(at, alarm.triggerAtTime)
        assertEquals("rec_auto_fictional_$start", shadowOf(alarm.operation).savedIntent.getStringExtra(AutoRecordReceiver.EXTRA_SESSION_ID))
    }

    @Test fun refreshCrossingStartReplacesRatherThanLosesDueAlarm() {
        val start = now + 1000L
        val end = start + 60000L
        assertTrue(AutoRecordAlarmStore.schedule(app, listOf(item(start, end)), nowMs = start - 1L))
        val original = alarms().single().operation
        assertTrue(AutoRecordAlarmStore.schedule(app, listOf(item(start, end)), nowMs = start + 1L))
        assertEquals(original, alarms().single().operation)
        assertEquals(start + 1L, alarms().single().triggerAtTime)
    }

    @Test fun endedLessonDoesNotReplay() {
        assertTrue(AutoRecordAlarmStore.schedule(app, listOf(item(now - 1000L, now))))
        assertTrue(alarms().isEmpty())
    }

    @Test fun legacyCacheDerivesAbsoluteEndFromOriginalStart() {
        val start = now - 30000L
        val legacy = item(start, start + 60000L).toMutableMap().apply { remove("endEpochMs") }
        assertTrue(AutoRecordAlarmStore.schedule(app, listOf(legacy)))
        assertEquals(start + 60000L, shadowOf(alarms().single().operation).savedIntent.getLongExtra(AutoRecordReceiver.EXTRA_END_EPOCH_MS, -1L))
    }

    @Test fun catchUpStopsAtOriginalEndAndDuplicateBroadcastDoesNotRestart() {
        val record = service()
        val start = now - 30000L
        val end = now + 60000L
        val intent = startIntent(start, end)
        AutoRecordReceiver().onReceive(app, intent)
        assertEquals(true, record.getStatus()["isRecording"])
        assertEquals(end, alarms().single().triggerAtTime)
        ShadowSystemClock.advanceBy(Duration.ofSeconds(5))
        AutoRecordReceiver().onReceive(app, intent)
        assertEquals(end, alarms().single().triggerAtTime)
        assertEquals("rec_auto_fictional_$start", record.getStatus()["sessionId"])
    }

    @Test fun manualStopPersistsAndRepeatedScheduleDoesNotRestartSession() {
        val record = service()
        val start = now - 1000L
        val end = now + 60000L
        AutoRecordReceiver().onReceive(app, startIntent(start, end))
        assertEquals(true, record.getStatus()["isRecording"])
        record.stop()
        assertTrue(AutoRecordAlarmStore.wasStarted(app, "rec_auto_fictional_$start"))
        AutoRecordReceiver().onReceive(app, startIntent(start, end))
        assertEquals(false, record.getStatus()["isRecording"])
        AutoRecordAlarmStore.schedule(app, listOf(item(start, end)))
        assertTrue(alarms().none { shadowOf(it.operation).savedIntent.action == AutoRecordReceiver.ACTION_AUTO_RECORD_START })
    }

    @Test fun manualRecordingIsNotReplacedByCatchUp() {
        val record = service()
        val file = RecordingRepository(app).createAudioFile("manual_session", "aac")
        assertTrue(record.startManual("manual", "manual_session", file))
        AutoRecordReceiver().onReceive(app, startIntent(now - 1000L, now + 60000L))
        assertEquals("manual_session", record.getStatus()["sessionId"])
        assertEquals(true, record.getStatus()["isRecording"])
    }

    @Test fun missingServiceOnlyNotifiesAndDoesNotColdStartMicrophone() {
        AutoRecordReceiver().onReceive(app, startIntent(now - 1000L, now + 60000L))
        assertNull(AudioRecordService.activeInstance)
        assertFalse(AutoRecordAlarmStore.wasStarted(app, "rec_auto_fictional_${now - 1000L}"))
    }

    @Test fun staleStopDoesNotStopAnotherSession() {
        val record = service()
        assertTrue(record.startManual("manual", "new_session", RecordingRepository(app).createAudioFile("new_session", "aac")))
        AutoRecordReceiver().onReceive(app, Intent(app, AutoRecordReceiver::class.java).apply {
            action = AutoRecordReceiver.ACTION_AUTO_RECORD_STOP
            putExtra(AutoRecordReceiver.EXTRA_SESSION_ID, "old_session")
        })
        assertEquals(true, record.getStatus()["isRecording"])
        assertEquals("new_session", record.getStatus()["sessionId"])
    }

    private class Reply : MethodChannel.Result {
        var returned = false
        var value: Any? = null
        var errorCode: String? = null
        override fun success(result: Any?) { check(!returned); returned = true; value = result }
        override fun error(code: String, message: String?, details: Any?) { check(!returned); returned = true; errorCode = code }
        override fun notImplemented() { error("NOT_IMPLEMENTED", null, null) }
    }
    private fun bridge(): RecordingBridgePlugin = RecordingBridgePlugin().also { plugin ->
        RecordingBridgePlugin::class.java.getDeclaredField("context").apply { isAccessible = true }.set(plugin, app)
        RecordingBridgePlugin::class.java.getDeclaredField("isBound").apply { isAccessible = true }.set(plugin, true)
    }

    @Test fun coldBridgeWaitsForArmedServiceBeforeRegisteringAlarms() {
        val plugin = bridge()
        val reply = Reply()
        val start = now + 60000L
        plugin.onMethodCall(MethodCall("syncScheduleAlarms", mapOf("alarms" to listOf(item(start, start + 60000L)))), reply)
        assertFalse(reply.returned)
        assertTrue(alarms().isEmpty())
        val record = service(armed = false)
        val connection = RecordingBridgePlugin::class.java.getDeclaredField("serviceConnection")
            .apply { isAccessible = true }.get(plugin) as ServiceConnection
        connection.onServiceConnected(ComponentName(app, AudioRecordService::class.java), record.onBind(null))
        assertEquals(true, reply.value)
        assertEquals(true, record.getStatus()["isArmed"])
        assertEquals(start, alarms().single().triggerAtTime)
    }

    @Test fun permissionRefusalDoesNotReportArmedOrRegisterAlarm() {
        shadowOf(app).denyPermissions(Manifest.permission.RECORD_AUDIO)
        val reply = Reply()
        bridge().onMethodCall(MethodCall("syncScheduleAlarms", mapOf("alarms" to listOf(item(now, now + 60000L)))), reply)
        assertTrue(reply.returned)
        assertEquals(false, reply.value)
        assertTrue(alarms().isEmpty())
    }
}
