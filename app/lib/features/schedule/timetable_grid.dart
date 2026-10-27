import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../core/shapes.dart';
import 'timetable_layout.dart';
import '../../core/course_palette.dart';

Color courseColor(String name) => CoursePalette.forName(name).fill;

class TimetableGrid extends StatelessWidget {
  final List<Map<String, dynamic>> entries;
  final DateTime weekStart;
  final DateTime today;
  final List<LessonSlot> slots;
  final ValueChanged<Map<String, dynamic>> onOpen;
  final void Function(Map<String, dynamic>, Offset)? onSecondaryTap;
  const TimetableGrid(
      {super.key,
      required this.entries,
      required this.weekStart,
      required this.today,
      required this.onOpen,
      this.onSecondaryTap,
      this.slots = schoolSlots});

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(12) / 12;
    final colors = Theme.of(context).colorScheme;

    final muted = colors.onSurfaceVariant;
    return LayoutBuilder(builder: (context, box) {
      final gutter = 54.0 * math.max(1.0, scale);
      final lanes = List.generate(
              7,
              (day) => layoutDay(entries.where((e) => e["weekday"] == day + 1),
                      slots: slots)
                  .fold<int>(1, (n, block) => math.max(n, block.laneCount)))
          .fold<int>(1, math.max);
      final width = math.max(
          box.maxWidth, gutter + 7 * 50 * lanes * math.max(1.0, scale));
      final column = (width - gutter) / 7;
      final rowHeight = math.max(72.0, 72 * scale);
      final textSize = box.maxWidth > 700 ? 13.0 : 11.5;
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: width,
          height: box.maxHeight,
          child: Column(children: [
            Container(
                height: 62 * math.max(1, scale),
                decoration: BoxDecoration(
                    border: Border(
                        bottom: BorderSide(color: colors.outlineVariant))),
                child: Row(children: [
                  SizedBox(
                      width: gutter,
                      child: Text('${weekStart.month}\n月',
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 12, color: muted))),
                  ...List.generate(7, (index) {
                    final date = weekStart.add(Duration(days: index));
                    final active = civilDate(date) == civilDate(today);
                    return SizedBox(
                        width: column,
                        child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(['一', '二', '三', '四', '五', '六', '日'][index],
                                  style: TextStyle(
                                      fontSize: 13,
                                      color: active ? colors.primary : muted,
                                      fontWeight: active
                                          ? FontWeight.w700
                                          : FontWeight.w400)),
                              const SizedBox(height: 5),
                              Container(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 7, vertical: 3),
                                  decoration: BoxDecoration(
                                      color: active
                                          ? colors.primary
                                          : Colors.transparent,
                                      borderRadius: BorderRadius.circular(10)),
                                  child: Text('${date.day}',
                                      style: TextStyle(
                                          fontSize: 13,
                                          color:
                                              active ? Colors.white : muted))),
                            ]));
                  }),
                ])),
            Expanded(
                child: SingleChildScrollView(
                    padding: EdgeInsets.only(
                        bottom: MediaQuery.paddingOf(context).bottom),
                    child: SizedBox(
                      height: slots.length * rowHeight,
                      child: Stack(children: [
                        ...List.generate(
                            slots.length,
                            (index) => Positioned(
                                top: index * rowHeight,
                                left: 0,
                                right: 0,
                                height: rowHeight,
                                child: Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      SizedBox(
                                          width: gutter,
                                          child: Padding(
                                              padding:
                                                  const EdgeInsets.only(top: 5),
                                              child: Column(children: [
                                                Text('${index + 1}',
                                                    style: TextStyle(
                                                        fontSize: 15,
                                                        color: Theme.of(context)
                                                            .colorScheme
                                                            .onSurface)),
                                                const SizedBox(height: 3),
                                                Text(
                                                    '${slots[index].start}\n${slots[index].end}',
                                                    softWrap: false,
                                                    maxLines: 2,
                                                    textAlign: TextAlign.center,
                                                    style: TextStyle(
                                                        fontSize: 11,
                                                        height: 1.6,
                                                        color: muted)),
                                              ]))),
                                      Expanded(
                                          child: Container(
                                              decoration: BoxDecoration(
                                                  border: Border(
                                                      top: BorderSide(
                                                          color: colors
                                                              .outlineVariant,
                                                          width: .5))))),
                                    ]))),
                        ...List.generate(
                            7,
                            (day) => layoutDay(
                                        entries.where(
                                            (e) => e['weekday'] == day + 1),
                                        slots: slots)
                                    .map((block) {
                                  final name =
                                      (block.entry['course_name'] ?? '课程')
                                          .toString();
                                  final tone = CoursePalette.of(context, name);
                                  final height =
                                      (block.bottom - block.top) * rowHeight -
                                          5;
                                  final available = column / block.laneCount;
                                  return Positioned(
                                    top: block.top * rowHeight + 2,
                                    left: gutter +
                                        day * column +
                                        block.lane * available +
                                        2,
                                    width: available - 4,
                                    height: math.max(24, height),
                                    child: Semantics(
                                        button: true,
                                        label:
                                            '$name，${block.entry['location'] ?? ''}，${block.entry['start_time']}到${block.entry['end_time']}',
                                        child: Material(
                                            color: tone.fill,
                                            clipBehavior: Clip.antiAlias,
                                            shape: RoundedRectangleBorder(
                                                borderRadius:
                                                    BorderRadius.circular(
                                                        StudyShapes.small),
                                                side: BorderSide(
                                                    color: tone.line,
                                                    width: 1)),
                                            child: InkWell(
                                                borderRadius:
                                                    BorderRadius.circular(
                                                        StudyShapes.small),
                                                onTap: () =>
                                                    onOpen(block.entry),
                                                onSecondaryTapDown:
                                                    onSecondaryTap ==
                                                            null
                                                        ? null
                                                        : (details) =>
                                                            onSecondaryTap!(
                                                                block.entry,
                                                                details
                                                                    .globalPosition),
                                                child: Padding(
                                                    padding:
                                                        const EdgeInsets.all(5),
                                                    child: ClipRect(
                                                        child:
                                                            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                                      Flexible(
                                                          child: Text(name,
                                                              maxLines:
                                                                  height > 130
                                                                      ? 4
                                                                      : 2,
                                                              overflow:
                                                                  TextOverflow
                                                                      .ellipsis,
                                                              style: TextStyle(
                                                                  fontSize:
                                                                      textSize,
                                                                  height: 1.35,
                                                                  fontWeight:
                                                                      FontWeight
                                                                          .w600,
                                                                  color: tone
                                                                      .ink))),
                                                      const SizedBox(height: 7),
                                                      Flexible(
                                                          child: Text(
                                                              '@${(block.entry['location'] ?? '').toString().isEmpty ? '教室待定' : block.entry['location']}',
                                                              maxLines:
                                                                  height > 130
                                                                      ? 5
                                                                      : 2,
                                                              overflow:
                                                                  TextOverflow
                                                                      .ellipsis,
                                                              style: TextStyle(
                                                                  fontSize:
                                                                      textSize,
                                                                  height: 1.4,
                                                                  color: tone
                                                                      .ink))),
                                                    ])))))),
                                  );
                                })).expand((items) => items),
                      ]),
                    ))),
          ]),
        ),
      );
    });
  }
}
