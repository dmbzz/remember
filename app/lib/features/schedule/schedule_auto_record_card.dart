import 'package:flutter/material.dart';
import '../../core/motion.dart';
import '../../core/shapes.dart';

/// 课表首页醒目的「本机到点自动录音」快捷开关卡片（仅 Android 展示）。
/// 用于多机/换手机录音场景：一眼确认当前手机是否自动录音，一键开/关并如实区分真实布防状态。
class ScheduleAutoRecordCard extends StatelessWidget {
  final bool enabled;
  final bool armed;
  final bool syncing;
  final int? scheduledCount;
  final String? errorText;
  final bool compact;
  final ValueChanged<bool> onChanged;

  const ScheduleAutoRecordCard({
    super.key,
    required this.enabled,
    required this.armed,
    required this.syncing,
    required this.onChanged,
    this.scheduledCount,
    this.errorText,
    this.compact = false,
  });

  bool get _hasError =>
      !syncing && errorText != null && errorText!.trim().isNotEmpty;

  bool get _hasWarning =>
      enabled && !syncing && !_hasError && (!armed || scheduledCount == 0);

  String _statusPillText() {
    if (syncing) return '同步中';
    if (_hasError) return enabled ? '布防失败' : '撤销失败';
    if (!enabled) return '已关闭';
    if (scheduledCount == 0) return '未选课';
    if (armed) return '已布防';
    return '未布防';
  }

  IconData _statusIcon() {
    if (syncing) return Icons.sync;
    if (_hasError || _hasWarning) return Icons.warning_amber_rounded;
    if (!enabled) return Icons.mic_off_outlined;
    return Icons.mic;
  }

  String _statusSubtitle() {
    if (syncing) {
      return enabled ? '正在更新本机自动录音排期…' : '正在关闭本机自动录音…';
    }
    if (_hasError) {
      return errorText!.trim();
    }
    if (!enabled) {
      return '当前手机不上课自动录；换回这台手机录音时点此开启';
    }
    if (scheduledCount == 0) {
      return '开关已开，但暂无开启自动录音的课程（点下方课程可开启）';
    }
    if (armed) {
      final countPart =
          scheduledCount != null ? '已排 $scheduledCount 节 · ' : '';
      return '已布防 · $countPart换其他手机录音前可在此一键关闭';
    }
    return '开关已开，服务尚未布防（请检查录音与通知权限）';
  }

  String _compactSubtitle() {
    if (syncing) return enabled ? '正在更新排期…' : '正在关闭排期…';
    if (_hasError) return errorText!.trim();
    if (scheduledCount == 0) return '暂无开启自动录音的课程';
    if (enabled && !armed) return '尚未布防，请检查权限';
    return _statusSubtitle();
  }

  Widget _animatedSubtitle(BuildContext context, Widget child) {
    if (MediaQuery.disableAnimationsOf(context)) {
      return child;
    }
    return AnimatedSize(
      duration: StudyMotion.quickDuration,
      curve: StudyMotion.standardCurve,
      alignment: Alignment.topLeft,
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final highContrast = MediaQuery.highContrastOf(context);
    final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
    final iconSize = (20.0 * textScale.clamp(1.0, 1.35)).roundToDouble();
    final badgeRadius = iconSize + 14;
    // 同一模式下保持边框宽度恒定，避免 OFF<->ON 切换产生 1px 布局内缩抖动。
    final borderWidth = highContrast ? 2.0 : 1.5;

    final Color bgColor;
    final Color borderColor;
    final Color iconBg;
    final Color iconFg;
    final Color pillBg;
    final Color pillFg;
    Color? switchActiveTrack;
    Color? switchActiveThumb;

    // 警示态使用冷石板蓝系，与暖陶土橙（已布防）和警示红（失败）一眼拉开色相区分。
    final warningAccent =
        isDark ? const Color(0xFF9FBCE0) : const Color(0xFF2F557A);
    final warningOnAccent = isDark ? const Color(0xFF102033) : Colors.white;
    final warningSurface =
        isDark ? const Color(0xFF222A36) : const Color(0xFFE7EFF7);

    if (_hasError) {
      bgColor = highContrast
          ? colors.errorContainer
          : colors.errorContainer.withOpacity(isDark ? .55 : .78);
      borderColor = colors.error;
      iconBg = colors.error;
      iconFg = colors.onError;
      pillBg = colors.error;
      pillFg = colors.onError;
      switchActiveTrack = colors.error;
      switchActiveThumb = colors.onError;
    } else if (!enabled) {
      bgColor = highContrast ? colors.surface : colors.surfaceContainerLow;
      borderColor = highContrast ? colors.onSurface : colors.outlineVariant;
      iconBg = highContrast ? colors.onSurface : colors.surfaceContainerHighest;
      iconFg = highContrast ? colors.surface : colors.onSurfaceVariant;
      pillBg = highContrast ? colors.onSurface : colors.surfaceContainerHighest;
      pillFg = highContrast ? colors.surface : colors.onSurfaceVariant;
    } else if (_hasWarning) {
      bgColor = warningSurface;
      borderColor = warningAccent;
      iconBg = warningAccent;
      iconFg = warningOnAccent;
      pillBg = warningAccent;
      pillFg = warningOnAccent;
      switchActiveTrack = warningAccent;
      switchActiveThumb = warningOnAccent;
    } else {
      bgColor = highContrast
          ? colors.primaryContainer
          : colors.primaryContainer.withOpacity(isDark ? .48 : .72);
      borderColor = colors.primary;
      iconBg = colors.primary;
      iconFg = colors.onPrimary;
      pillBg = colors.primary;
      pillFg = colors.onPrimary;
    }

    final statusPillText = _statusPillText();
    final subtitle = _statusSubtitle();
    final showSubtitle = !compact || _hasError || _hasWarning || syncing;
    final visibleSubtitle = compact ? _compactSubtitle() : subtitle;
    final largeTextStacked = !compact && textScale >= 1.5;
    final motionDuration = StudyMotion.quick(context);

    final iconBadge = AnimatedContainer(
      duration: motionDuration,
      curve: StudyMotion.standardCurve,
      width: compact ? 32 : badgeRadius,
      height: compact ? 32 : badgeRadius,
      decoration: BoxDecoration(
        color: iconBg,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Icon(
        _statusIcon(),
        size: compact ? 18 : iconSize,
        color: iconFg,
      ),
    );

    final titleAndPill = Wrap(
      spacing: 8,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text(
          '本机到点自动录音',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w700,
            color: colors.onSurface,
          ),
        ),
        AnimatedContainer(
          key: const Key('schedule-auto-record-pill'),
          duration: motionDuration,
          curve: StudyMotion.standardCurve,
          padding: const EdgeInsets.symmetric(
            horizontal: 8,
            vertical: 2,
          ),
          decoration: BoxDecoration(
            color: pillBg,
            borderRadius: BorderRadius.circular(StudyShapes.small),
          ),
          child: Text(
            statusPillText,
            style: theme.textTheme.labelSmall?.copyWith(
              color: pillFg,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );

    final subtitleWidget = Text(
      visibleSubtitle,
      key: const Key('schedule-auto-record-subtitle'),
      maxLines: compact ? 1 : null,
      overflow: compact ? TextOverflow.ellipsis : null,
      style: theme.textTheme.bodySmall?.copyWith(
        color: _hasError
            ? colors.error
            : highContrast
                ? colors.onSurface
                : colors.onSurfaceVariant,
        height: 1.35,
      ),
    );

    final switchControl = ExcludeFocus(
      child: ExcludeSemantics(
        child: Switch(
          key: const Key('schedule-auto-record-switch'),
          value: enabled,
          activeColor: switchActiveThumb,
          activeTrackColor: switchActiveTrack,
          inactiveThumbColor: highContrast ? colors.onSurface : null,
          inactiveTrackColor: highContrast ? colors.surface : null,
          trackOutlineColor: highContrast
              ? WidgetStatePropertyAll(
                  enabled ? borderColor : colors.onSurface,
                )
              : null,
          onChanged: syncing ? null : onChanged,
        ),
      ),
    );

    return Semantics(
      container: true,
      toggled: enabled,
      enabled: !syncing,
      excludeSemantics: true,
      onTap: syncing ? null : () => onChanged(!enabled),
      label: '本机到点自动录音，$statusPillText，$subtitle',
      child: AnimatedContainer(
        duration: motionDuration,
        curve: StudyMotion.standardCurve,
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: StudyShapes.cardBorder,
          border: Border.all(color: borderColor, width: borderWidth),
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: StudyShapes.cardBorder,
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            key: const Key('schedule-auto-record-card'),
            onTap: syncing ? null : () => onChanged(!enabled),
            child: Padding(
              padding: EdgeInsets.symmetric(
                horizontal: compact ? 12 : 14,
                vertical: compact ? 8 : 12,
              ),
              child: largeTextStacked
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            iconBadge,
                            const SizedBox(width: 10),
                            Expanded(child: titleAndPill),
                            const SizedBox(width: 6),
                            switchControl,
                          ],
                        ),
                        const SizedBox(height: 8),
                        _animatedSubtitle(context, subtitleWidget),
                      ],
                    )
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        iconBadge,
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              titleAndPill,
                              _animatedSubtitle(
                                context,
                                showSubtitle
                                    ? Padding(
                                        padding: const EdgeInsets.only(top: 4),
                                        child: subtitleWidget,
                                      )
                                    : const SizedBox.shrink(),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        switchControl,
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
