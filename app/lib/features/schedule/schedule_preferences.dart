import 'timetable_layout.dart';

class SchedulePreferences {
  const SchedulePreferences(
      {this.slots = schoolSlots,
      this.semesterWeeks = 30,
      this.firstWeekOdd = true,
      this.defaultRule = 'every'});
  final List<LessonSlot> slots;
  final int semesterWeeks;
  final bool firstWeekOdd;
  final String defaultRule;
  factory SchedulePreferences.fromJson(Map<String, dynamic>? value) {
    if (value == null) return const SchedulePreferences();
    final raw = value['slots'];
    return SchedulePreferences(
        slots: raw is List && raw.isNotEmpty
            ? [
                for (var i = 0; i < raw.length; i++)
                  LessonSlot(i + 1, '${raw[i]['start']}', '${raw[i]['end']}')
              ]
            : schoolSlots,
        semesterWeeks: (value['semester_weeks'] as num?)?.toInt() ?? 30,
        firstWeekOdd: value['first_week_odd'] != false,
        defaultRule: '${value['default_rule'] ?? 'every'}');
  }
  Map<String, dynamic> toJson() => {
        'slots': [
          for (final s in slots) {'start': s.start, 'end': s.end}
        ],
        'semester_weeks': semesterWeeks,
        'first_week_odd': firstWeekOdd,
        'default_rule': defaultRule
      };
  List<int> weeksFor(String rule, int start, int end) => [
        for (var w = start; w <= end; w++)
          if (rule == 'every' || ((w.isOdd == firstWeekOdd) == (rule == 'odd')))
            w
      ];
}
