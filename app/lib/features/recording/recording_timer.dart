import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 定时录音到点后的动作。
enum RecordingTimerAction {
  stop('stop', '停止并保存', '到点自动停止并保存', '到点后自动结束本次录音并加入同步队列'),
  pause('pause', '仅暂停', '到点自动暂停', '到点后自动暂停录音，保留当前会话，可继续录或手动停止');

  final String wireValue;
  final String shortLabel;
  final String detailLabel;
  final String helperText;

  const RecordingTimerAction(
    this.wireValue,
    this.shortLabel,
    this.detailLabel,
    this.helperText,
  );

  static RecordingTimerAction fromWire(String? value) {
    if (value == pause.wireValue) return pause;
    return stop;
  }
}

/// 课堂定时录音配置（持久化于本地偏好）。
class RecordingTimerConfig {
  static const List<int> presetMinutes = [45, 90, 100];
  static const int minMinutes = 1;
  static const int maxMinutes = 360;
  static const String prefMinutesKey = 'cna_recording_timer_minutes';
  static const String prefActionKey = 'cna_recording_timer_action';

  final int? durationMinutes;
  final RecordingTimerAction action;

  const RecordingTimerConfig({
    this.durationMinutes,
    this.action = RecordingTimerAction.stop,
  });

  bool get isTimed =>
      durationMinutes != null &&
      durationMinutes! >= minMinutes &&
      durationMinutes! <= maxMinutes;

  bool get isCustomDuration =>
      isTimed && !presetMinutes.contains(durationMinutes);

  int? get durationLimitMs => isTimed ? durationMinutes! * 60 * 1000 : null;

  RecordingTimerConfig copyWith({
    int? durationMinutes,
    bool clearDuration = false,
    RecordingTimerAction? action,
  }) {
    return RecordingTimerConfig(
      durationMinutes:
          clearDuration ? null : (durationMinutes ?? this.durationMinutes),
      action: action ?? this.action,
    );
  }

  static String presetLabel(int minutes) {
    if (minutes == 45) return '45 分钟';
    if (minutes == 90) return '90 分钟';
    if (minutes == 100) return '1 小时 40 分';
    return formatMinutes(minutes);
  }

  static String formatMinutes(int minutes) {
    if (minutes < 60) return '$minutes 分钟';
    final hours = minutes ~/ 60;
    final rem = minutes % 60;
    if (rem == 0) return '$hours 小时';
    return '$hours 小时 $rem 分';
  }

  String get summaryLabel {
    if (!isTimed) return '不限时';
    return '${formatMinutes(durationMinutes!)} · ${action.shortLabel}';
  }

  static String _normalizeDigits(String raw) {
    final buffer = StringBuffer();
    for (final rune in raw.trim().runes) {
      if (rune >= 0xFF10 && rune <= 0xFF19) {
        buffer.writeCharCode(rune - 0xFF10 + 0x30);
      } else {
        buffer.writeCharCode(rune);
      }
    }
    return buffer.toString();
  }

  /// 解析自定义小时与分钟输入；支持全角数字，范围 1–360 分钟（6 小时）。
  static ({int? minutes, String? error}) parseCustomInput(
    String hoursRaw,
    String minutesRaw,
  ) {
    final hText = _normalizeDigits(hoursRaw);
    final mText = _normalizeDigits(minutesRaw);
    if (hText.isEmpty && mText.isEmpty) {
      return (minutes: null, error: '请输入定时录音时长');
    }
    final digitPattern = RegExp(r'^\d+$');
    if ((hText.isNotEmpty && !digitPattern.hasMatch(hText)) ||
        (mText.isNotEmpty && !digitPattern.hasMatch(mText))) {
      return (minutes: null, error: '小时和分钟请填写非负整数');
    }
    final hours = hText.isEmpty ? 0 : int.tryParse(hText);
    final minutes = mText.isEmpty ? 0 : int.tryParse(mText);
    if (hours == null || minutes == null) {
      return (minutes: null, error: '数值超出范围，请重新输入');
    }
    final total = hours * 60 + minutes;
    if (total < minMinutes || total > maxMinutes) {
      return (
        minutes: null,
        error: '定时时长需在 $minMinutes 分钟至 6 小时（$maxMinutes 分钟）之间'
      );
    }
    return (minutes: total, error: null);
  }

  static Future<RecordingTimerConfig> load() async {
    final prefs = await SharedPreferences.getInstance();
    final savedMinutes = prefs.getInt(prefMinutesKey);
    final validMinutes = savedMinutes != null &&
            savedMinutes >= minMinutes &&
            savedMinutes <= maxMinutes
        ? savedMinutes
        : null;
    final action =
        RecordingTimerAction.fromWire(prefs.getString(prefActionKey));
    return RecordingTimerConfig(durationMinutes: validMinutes, action: action);
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    if (isTimed) {
      await prefs.setInt(prefMinutesKey, durationMinutes!);
    } else {
      await prefs.remove(prefMinutesKey);
    }
    await prefs.setString(prefActionKey, action.wireValue);
  }
}

/// 自定义定时录音时长输入弹窗（支持小时 + 分钟，或直接填总分钟数）。
Future<int?> showCustomRecordingDurationDialog(
  BuildContext context, {
  int? initialMinutes,
}) {
  final seed = initialMinutes ?? 100;
  final initHours = seed ~/ 60;
  final initMins = seed % 60;
  return showDialog<int>(
    context: context,
    builder: (context) => _CustomRecordingDurationDialog(
      initialHours: initHours,
      initialMinutes: initMins,
    ),
  );
}

class _CustomRecordingDurationDialog extends StatefulWidget {
  final int initialHours;
  final int initialMinutes;

  const _CustomRecordingDurationDialog({
    required this.initialHours,
    required this.initialMinutes,
  });

  @override
  State<_CustomRecordingDurationDialog> createState() =>
      _CustomRecordingDurationDialogState();
}

class _CustomRecordingDurationDialogState
    extends State<_CustomRecordingDurationDialog> {
  late final TextEditingController _hoursController;
  late final TextEditingController _minutesController;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _hoursController = TextEditingController(
      text: widget.initialHours > 0 ? '${widget.initialHours}' : '',
    );
    _minutesController = TextEditingController(
      text: widget.initialMinutes > 0 || widget.initialHours == 0
          ? '${widget.initialMinutes}'
          : '',
    );
  }

  @override
  void dispose() {
    _hoursController.dispose();
    _minutesController.dispose();
    super.dispose();
  }

  void _onChanged(String _) {
    setState(() => _errorText = null);
  }

  void _submit() {
    final parsed = RecordingTimerConfig.parseCustomInput(
      _hoursController.text,
      _minutesController.text,
    );
    if (parsed.minutes == null) {
      setState(() => _errorText = parsed.error);
      return;
    }
    Navigator.of(context).pop(parsed.minutes);
  }

  @override
  Widget build(BuildContext context) {
    final parsed = RecordingTimerConfig.parseCustomInput(
      _hoursController.text,
      _minutesController.text,
    );
    final theme = Theme.of(context);
    final hoursField = TextField(
      key: const Key('custom-timer-hours-field'),
      controller: _hoursController,
      keyboardType: TextInputType.number,
      textInputAction: TextInputAction.next,
      decoration: const InputDecoration(
        labelText: '小时',
        hintText: '0–6',
        suffixText: '时',
      ),
      onChanged: _onChanged,
    );
    final minutesField = TextField(
      key: const Key('custom-timer-minutes-field'),
      controller: _minutesController,
      keyboardType: TextInputType.number,
      textInputAction: TextInputAction.done,
      decoration: const InputDecoration(
        labelText: '分钟',
        hintText: '如 40 或 100',
        suffixText: '分',
      ),
      onChanged: _onChanged,
      onSubmitted: (_) => _submit(),
    );

    final screenWidth = MediaQuery.sizeOf(context).width;
    final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final stackVertically = screenWidth < 340 || textScale >= 1.6;
    final fields = stackVertically
        ? Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              hoursField,
              const SizedBox(height: 10),
              minutesField,
            ],
          )
        : Row(
            children: [
              Expanded(child: hoursField),
              const SizedBox(width: 12),
              Expanded(child: minutesField),
            ],
          );

    return AlertDialog(
      title: const Text('自定义录音时长'),
      scrollable: true,
      content: SizedBox(
        width: (screenWidth - 96).clamp(220.0, 340.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '可填写小时与分钟（如 1 小时 40 分），或直接填总分钟数（最长 6 小时）。',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            fields,
            const SizedBox(height: 12),
            if (_errorText != null)
              Text(
                _errorText!,
                key: const Key('custom-timer-error'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.error,
                ),
              )
            else if (parsed.minutes != null)
              Text(
                '将定时录音 ${RecordingTimerConfig.formatMinutes(parsed.minutes!)}（共 ${parsed.minutes} 分钟）',
                key: const Key('custom-timer-preview'),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('custom-timer-confirm'),
          onPressed: _submit,
          child: const Text('确定'),
        ),
      ],
    );
  }
}
