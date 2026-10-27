import '../../core/weeks.dart';

/// 节次与真实时间对应；不把后端的“大节”序号当成单节序号。
class LessonSlot {
  final int number;
  final String start;
  final String end;
  const LessonSlot(this.number, this.start, this.end);
}

const schoolSlots = [
  LessonSlot(1, '08:15', '09:00'),
  LessonSlot(2, '09:05', '09:50'),
  LessonSlot(3, '10:05', '10:50'),
  LessonSlot(4, '10:55', '11:40'),
  LessonSlot(5, '14:15', '15:00'),
  LessonSlot(6, '15:05', '15:50'),
  LessonSlot(7, '16:00', '16:45'),
  LessonSlot(8, '16:50', '17:35'),
  LessonSlot(9, '19:30', '20:15'),
  LessonSlot(10, '20:20', '21:05'),
];

int? timeMinutes(dynamic value) {
  final match = RegExp(r'^(\d{1,2}):(\d{2})(?::\d{2})?$').firstMatch('$value');
  if (match == null) return null;
  final hour = int.parse(match[1]!);
  final minute = int.parse(match[2]!);
  return hour < 24 && minute < 60 ? hour * 60 + minute : null;
}

DateTime civilDate(DateTime date) => DateTime(date.year, date.month, date.day);
int teachingWeek(DateTime date, DateTime semesterStart) =>
    DateTime.utc(date.year, date.month, date.day)
            .difference(DateTime.utc(
                semesterStart.year, semesterStart.month, semesterStart.day))
            .inDays ~/
        7 +
    (civilDate(date).isBefore(civilDate(semesterStart)) ? 0 : 1);

bool appearsInWeek(Map<String, dynamic> entry, int week) {
  if (week < 1) return false;
  final weeks = WeeksFormatter.normalize(entry['weeks']);
  return entry['confirmed'] != false && (weeks.isEmpty || weeks.contains(week));
}

class TimetableBlock {
  final Map<String, dynamic> entry;
  final double top;
  final double bottom;
  int lane = 0;
  int laneCount = 1;
  TimetableBlock(this.entry, this.top, this.bottom);
}

bool fitsGrid(Map<String, dynamic> entry,
    {List<LessonSlot> slots = schoolSlots}) {
  final start = timeMinutes(entry['start_time']);
  final end = timeMinutes(entry['end_time']);
  return start != null &&
      end != null &&
      end > start &&
      start >= timeMinutes(slots.first.start)! &&
      end <= timeMinutes(slots.last.end)! &&
      _slotPosition(end, slots) > _slotPosition(start, slots);
}

/// Breaks and lunch are compressed, while start/end inside a lesson retain their position.
double _slotPosition(int minutes, List<LessonSlot> slots) {
  for (var index = 0; index < slots.length; index++) {
    final start = timeMinutes(slots[index].start)!;
    final end = timeMinutes(slots[index].end)!;
    if (minutes <= start) return index.toDouble();
    if (minutes <= end) return index + (minutes - start) / (end - start);
  }
  return slots.length.toDouble();
}

List<TimetableBlock> layoutDay(Iterable<Map<String, dynamic>> entries,
    {List<LessonSlot> slots = schoolSlots}) {
  final blocks = <TimetableBlock>[];
  for (final entry in entries) {
    if (!fitsGrid(entry, slots: slots)) continue;
    final start = timeMinutes(entry['start_time']);
    final end = timeMinutes(entry['end_time']);
    if (start == null || end == null || end <= start) continue;
    final top = _slotPosition(start, slots);
    final bottom = _slotPosition(end, slots);
    if (bottom > top) blocks.add(TimetableBlock(entry, top, bottom));
  }
  blocks.sort((a, b) => a.top.compareTo(b.top));
  var cursor = 0;
  while (cursor < blocks.length) {
    final group = <TimetableBlock>[blocks[cursor++]];
    var end = group.first.bottom;
    while (cursor < blocks.length && blocks[cursor].top < end) {
      final block = blocks[cursor++];
      group.add(block);
      if (block.bottom > end) end = block.bottom;
    }
    final laneEnds = <double>[];
    for (final block in group) {
      var lane = laneEnds.indexWhere((end) => end <= block.top);
      if (lane < 0) {
        lane = laneEnds.length;
        laneEnds.add(block.bottom);
      } else {
        laneEnds[lane] = block.bottom;
      }
      block.lane = lane;
    }
    for (final block in group) {
      block.laneCount = laneEnds.length;
    }
  }
  return blocks;
}
