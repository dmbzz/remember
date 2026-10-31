package com.classnotes.assistant

import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Intent
import android.app.Activity
import android.provider.OpenableColumns
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import schedule.ScheduleWidgetProvider

class MainActivity : FlutterActivity() {
    private var scheduleChannel: MethodChannel? = null
    private var pairingDiscovery: pairing.PairingDiscovery? = null
    private var pickerResult: MethodChannel.Result? = null
    private var notesPickerResult: MethodChannel.Result? = null
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        pairingDiscovery?.dispose()
        pairingDiscovery = pairing.PairingDiscovery(this, flutterEngine.dartExecutor.binaryMessenger)
        flutterEngine.plugins.add(audio.RecordingBridgePlugin())
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "class_notes/course_reminders").setMethodCallHandler { call, result ->
            if (call.method == "openExactAlarms" || call.method == "openNotifications") {
                try {
                    val settings = when {
                        call.method == "openExactAlarms" && Build.VERSION.SDK_INT >= 31 ->
                            Intent(android.provider.Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM, android.net.Uri.parse("package:$packageName"))
                        call.method == "openNotifications" && Build.VERSION.SDK_INT >= 26 ->
                            Intent(android.provider.Settings.ACTION_APP_NOTIFICATION_SETTINGS).putExtra(android.provider.Settings.EXTRA_APP_PACKAGE, packageName)
                        else -> Intent(android.provider.Settings.ACTION_APPLICATION_DETAILS_SETTINGS, android.net.Uri.parse("package:$packageName"))
                    }
                    startActivity(settings); result.success(null)
                } catch (e: Exception) { result.error("SETTINGS", e.message, null) }
            } else {
                Thread {
                    try {
                        val value: Any? = when (call.method) {
                            "status" -> schedule.CourseReminderScheduler.status(this)
                            "refresh" -> { schedule.CourseReminderScheduler.refresh(this); null }
                            "test" -> { schedule.CourseReminderScheduler.test(this); null }
                            else -> throw IllegalArgumentException("未知提醒操作")
                        }
                        runOnUiThread { result.success(value) }
                    } catch (e: Exception) { runOnUiThread { result.error("COURSE_REMINDERS", e.message, null) } }
                }.start()
            }
        }
        val localNotes = LocalNotesRepository(this)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "class_notes/local_notes").setMethodCallHandler { call, result ->
            when (call.method) {
                "getFolder" -> result.success(localNotes.folderLabel())
                "getFolderInfo" -> result.success(localNotes.folderInfo())
                "identityHash" -> result.success(localNotes.identityHash(call.argument<String>("value") ?: ""))
                "pickFolder" -> {
                    if (notesPickerResult != null) { result.error("BUSY", "文件夹选择器已打开", null); return@setMethodCallHandler }
                    notesPickerResult = result
                    try {
                        startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION or Intent.FLAG_GRANT_PREFIX_URI_PERMISSION)
                        }, 5202)
                    } catch (e: Exception) { notesPickerResult = null; result.error("PICK_FAILED", e.message, null) }
                }
                "listNotes" -> Thread {
                    try { val value = localNotes.list(); runOnUiThread { result.success(value) } }
                    catch (e: Exception) { runOnUiThread { result.error("LOCAL_NOTES", e.message, null) } }
                }.start()
                "installNote" -> Thread {
                    try {
                        val value = localNotes.install(call.argument<String>("path") ?: error("缺少路径"),
                            call.argument<ByteArray>("bytes") ?: error("缺少笔记内容"),
                            call.argument<String>("sha256") ?: error("缺少摘要"), call.argument<String>("expectedHash"),
                            call.argument<String>("identity") ?: error("缺少目录身份"),
                            call.argument<Boolean>("keepBackup") ?: true)
                        runOnUiThread { result.success(value) }
                    } catch (e: Exception) { runOnUiThread { result.error("NOTE_SYNC", e.message, null) } }
                }.start()
                "exportNote" -> Thread {
                    try {
                        val value = localNotes.export(call.argument<String>("path") ?: error("缺少路径"),
                            call.argument<String>("sha256") ?: error("缺少摘要"),
                            call.argument<String>("identity") ?: error("缺少目录身份"))
                        runOnUiThread { result.success(value) }
                    } catch (e: Exception) { runOnUiThread { result.error("NOTE_EXPORT", e.message, null) } }
                }.start()
                "readNote" -> Thread {
                    try { val value = localNotes.read(call.argument<String>("id") ?: ""); runOnUiThread { result.success(value) } }
                    catch (e: Exception) { runOnUiThread { result.error("LOCAL_NOTE", e.message, null) } }
                }.start()
                else -> result.notImplemented()
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "class_notes/schedule_import").setMethodCallHandler { call, result ->
            if (call.method != "pickIcs") { result.notImplemented(); return@setMethodCallHandler }
            if (pickerResult != null) { result.error("BUSY", "文件选择器已打开", null); return@setMethodCallHandler }
            pickerResult = result
            try {
                startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                    addCategory(Intent.CATEGORY_OPENABLE)
                    type = "*/*"
                }, 5201)
            } catch (e: Exception) { pickerResult = null; result.error("PICK_FAILED", e.message, null) }
        }
        scheduleChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "class_notes/schedule_widget").also { channel ->
            channel.setMethodCallHandler { call, result ->
                try {
                    when (call.method) {
                        "syncSchedule" -> { ScheduleWidgetProvider.save(this, call.argument<String>("json") ?: error("缺少课表")); result.success(null) }
                        "getLaunchTab" -> {
                            val recording = intent.getBooleanExtra("open_recording", false)
                            intent.removeExtra("open_schedule")
                            intent.removeExtra("open_recording")
                            result.success(if (recording) 2 else 0)
                        }
                        "requestPin" -> {
                            val manager = AppWidgetManager.getInstance(this)
                            result.success(Build.VERSION.SDK_INT >= 26 && manager.isRequestPinAppWidgetSupported &&
                                manager.requestPinAppWidget(ComponentName(this, ScheduleWidgetProvider::class.java), null, null))
                        }
                        else -> result.notImplemented()
                    }
                } catch (e: Exception) { result.error("SCHEDULE_WIDGET", e.message, null) }
            }
        }
    }
    override fun onDestroy() {
        pairingDiscovery?.dispose()
        pairingDiscovery = null
        super.onDestroy()
    }
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == 5202) {
            val result = notesPickerResult ?: return
            notesPickerResult = null
            val uri = data?.data
            if (resultCode != Activity.RESULT_OK || uri == null) { result.success(null); return }
            try { result.success(LocalNotesRepository(this).saveFolder(uri, data.flags)) }
            catch (e: Exception) { result.error("FOLDER_FAILED", e.message, null) }
            return
        }
        if (requestCode != 5201) return
        val result = pickerResult ?: return
        pickerResult = null
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) { result.success(null); return }
        Thread {
            try {
                val name = contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use {
                    if (it.moveToFirst()) it.getString(0) else null
                } ?: "schedule.ics"
                require(name.lowercase().endsWith(".ics")) { "请选择 .ics 日历文件" }
                val bytes = contentResolver.openInputStream(uri)?.use { stream ->
                    val output = java.io.ByteArrayOutputStream()
                    val buffer = ByteArray(8192)
                    while (true) {
                        val read = stream.read(buffer)
                        if (read < 0) break
                        require(output.size() + read <= 5 * 1024 * 1024) { "课表文件超过 5 MB" }
                        output.write(buffer, 0, read)
                    }
                    output.toByteArray()
                } ?: error("无法读取文件")
                runOnUiThread { result.success(mapOf("name" to name, "bytes" to bytes)) }
            } catch (e: Exception) { runOnUiThread { result.error("READ_FAILED", e.message, null) } }
        }.start()
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        if (intent.getBooleanExtra("open_schedule", false)) {
            scheduleChannel?.invokeMethod("openSchedule", null)
            intent.removeExtra("open_schedule")
        }
        if (intent.getBooleanExtra("open_recording", false)) {
            scheduleChannel?.invokeMethod("openRecording", null)
            intent.removeExtra("open_recording")
        }
    }
}
