import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/course_palette.dart';
import '../../core/orientation_capsule.dart';
import '../../core/shapes.dart';
import 'timetable_layout.dart';

/// The Windows day/week view shares actual course and text elements. The side
/// details belong to the caller and never take part in this transition.
class ScheduleAnchorView extends StatefulWidget {
  const ScheduleAnchorView({
    super.key,
    required this.entries,
    required this.weekStart,
    required this.today,
    required this.selectedDay,
    required this.dayMode,
    this.viewportOriginX = 0,
    this.slots = schoolSlots,
    this.selectedEntryId,
    required this.onSelectDay,
    required this.onOpen,
    this.onSecondaryTap,
  }) : assert(selectedDay >= 1 && selectedDay <= 7);

  final List<Map<String, dynamic>> entries;
  final DateTime weekStart, today;
  final int selectedDay;
  final bool dayMode;
  final List<LessonSlot> slots;

  /// Animated leading clearance supplied by the persistent navigation shell.
  /// Geometry is rebased in screen coordinates when this origin moves.
  final double viewportOriginX;
  final String? selectedEntryId;
  final ValueChanged<int> onSelectDay;
  final ValueChanged<Map<String, dynamic>> onOpen;
  final void Function(Map<String, dynamic>, Offset)? onSecondaryTap;

  @override
  ScheduleAnchorViewState createState() => ScheduleAnchorViewState();
}

/// Public read-only observations support real widget/frame acceptance tests.
class ScheduleAnchorViewState extends State<ScheduleAnchorView>
    with TickerProviderStateMixin {
  late final AnimationController _motion =
      AnimationController.unbounded(vsync: this, value: widget.dayMode ? 0 : 1)
        ..addStatusListener(_status);
  late final AnimationController _reflow = AnimationController(
      vsync: this, value: 1, duration: const Duration(milliseconds: 490))
    ..addStatusListener(_status);
  final ScrollController _horizontal = ScrollController();
  final ScrollController _vertical = ScrollController();
  Offset _dayOffset = Offset.zero, _weekOffset = Offset.zero;
  Offset _lastActual = Offset.zero;
  bool _weekVisited = false;
  bool _transitioning = false, _programmatic = false, _reduce = false;
  late bool _settledDay = widget.dayMode;
  late String _signature = _dataSignature(widget.entries);
  _AnchorLayout? _layout;
  _LayoutEnvironment? _environment;
  _GeometryCorrection? _correction;
  Size? _reflowCanvasFloor;
  bool _snapshotChanged = false;
  Size? _lastViewport;
  late double _lastOriginX = widget.viewportOriginX;
  Duration _modeDuration = Duration.zero;
  Duration? _correctionModeStart;
  Duration _correctionModeDuration = Duration.zero;
  bool _finishQueued = false;
  bool _finishPending = false;
  final Map<String, Rect> _debugRects = {};

  double get debugProgress => _motion.value.clamp(0.0, 1.0);
  double get debugVelocity => _motion.velocity;
  Offset get debugDayOffset => _dayOffset;
  Offset get debugWeekOffset => _weekOffset;
  Map<String, Rect> get debugCourseRects => Map.unmodifiable(_debugRects);
  bool get debugIsAnimating => _motion.isAnimating || _reflow.isAnimating;
  bool get _moving => _transitioning || _correction != null;

  @override
  void initState() {
    super.initState();
    _horizontal.addListener(_scrolled);
    _vertical.addListener(_scrolled);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduce = MediaQuery.disableAnimationsOf(context);
    if (reduce && !_reduce) _snap();
    _reduce = reduce;
    if (!TickerMode.of(context) && debugIsAnimating) _snap();
    // MediaQuery also changes on every native window resize. Only a change to
    // actual text metrics needs the safe endpoint fallback; size changes are
    // rebased from the current visible geometry in LayoutBuilder below.
    final environment = _LayoutEnvironment.of(context);
    if (_environment != null && _environment != environment) {
      _snap();
      _layout = null;
    }
    _environment = environment;
  }

  @override
  void didUpdateWidget(covariant ScheduleAnchorView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final signature = _dataSignature(widget.entries);
    final slotsChanged =
        oldWidget.slots.map((s) => '${s.start}-${s.end}').join() !=
            widget.slots.map((s) => '${s.start}-${s.end}').join();
    final scopeChanged = slotsChanged ||
        oldWidget.weekStart != widget.weekStart ||
        oldWidget.selectedDay != widget.selectedDay;
    if (scopeChanged || signature != _signature) {
      _signature = signature;
      _layout = null;
      if (scopeChanged) {
        _dayOffset = Offset.zero;
        _weekOffset = Offset.zero;
        _weekVisited = false;
      }
      _snap();
    } else {
      if (oldWidget.dayMode != widget.dayMode) _retarget();
      // A refreshed snapshot may keep the same geometry but carry new action
      // metadata. Rebind it without restarting a mode transition.
      if (!identical(oldWidget.entries, widget.entries)) {
        _snapshotChanged = true;
      }
    }
  }

  Offset get _actual => Offset(_horizontal.hasClients ? _horizontal.offset : 0,
      _vertical.hasClients ? _vertical.offset : 0);

  void _scrolled() {
    final actual = _actual;
    if (_programmatic) {
      _lastActual = actual;
      return;
    }
    final delta = actual - _lastActual;
    _lastActual = actual;
    final layout = _layout;
    if (layout == null || !mounted) return;
    if (_moving) {
      // Wheel/trackpad/keyboard input remains usable during the 490ms motion.
      // Its delta shifts both stored viewports, with each one's own extents.
      _dayOffset = layout.clampOffset(_dayOffset + delta, true);
      _weekOffset = layout.clampOffset(_weekOffset + delta, false);
    } else if (_settledDay) {
      _dayOffset = layout.clampOffset(actual, true);
    } else {
      _weekOffset = layout.clampOffset(actual, false);
      _weekVisited = true;
    }
    setState(() {});
  }

  void _retarget() {
    if (_reduce || _layout == null) {
      _snap();
      return;
    }
    final target = widget.dayMode ? 0.0 : 1.0;
    if (!_moving) {
      if (_settledDay) {
        _dayOffset = _layout!.clampOffset(_actual, true);
      } else {
        _weekOffset = _layout!.clampOffset(_actual, false);
        _weekVisited = true;
      }
      if (!_weekVisited) {
        _weekOffset = _layout!.initialWeekOffset(widget.selectedDay);
      }
    }
    final velocity = _motion.velocity;
    final from = debugProgress;
    final visible = _correction == null
        ? null
        : _geometry(_layout!, _dayOffset, _weekOffset);
    _motion.stop();
    _transitioning = true;
    final simulation = _AnchorSimulation(from, target, velocity);
    _modeDuration = Duration(microseconds: (simulation.seconds * 1e6).round());
    _motion.animateWith(simulation);
    if (visible != null) {
      _correction = _GeometryCorrection.between(
          visible,
          _geometry(_layout!, _dayOffset, _weekOffset,
              includeCorrection: false));
      _correctionModeStart = Duration.zero;
      _correctionModeDuration = _modeDuration;
      _reflow.stop();
    }
  }

  void _snap() {
    _motion.stop();
    _reflow.stop();
    _reflow.value = 1;
    _correction = null;
    _correctionModeStart = null;
    _reflowCanvasFloor = null;
    _motion.value = widget.dayMode ? 0 : 1;
    _transitioning = false;
    _settledDay = widget.dayMode;
    _queueFinish();
  }

  void _status(AnimationStatus status) {
    if (!debugIsAnimating && (_transitioning || _correction != null)) {
      _queueFinish();
    }
  }

  void _queueFinish() {
    if (_finishQueued) return;
    _finishQueued = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _finishQueued = false;
      if (!mounted || debugIsAnimating) return;
      // Never move a Viewport after its compensated children have painted.
      // Commit both the scroll and those children in the next single build.
      setState(() => _finishPending = true);
    });
  }

  void _commitFinish() {
    if (!_finishPending) return;
    _finishPending = false;
    if (debugIsAnimating || _layout == null) return;
    final layout = _layout!;
    final day = widget.dayMode;
    var offset = day ? _dayOffset : _weekOffset;
    if (!day && !_weekVisited) {
      offset = layout.initialWeekOffset(widget.selectedDay);
    }
    offset = layout.clampOffset(offset, day);
    _programmatic = true;
    if (_horizontal.hasClients) _horizontal.jumpTo(offset.dx);
    if (_vertical.hasClients) _vertical.jumpTo(offset.dy);
    _lastActual = _actual;
    _programmatic = false;
    if (day) {
      _dayOffset = offset;
    } else {
      _weekOffset = offset;
      _weekVisited = true;
    }
    _correction = null;
    _correctionModeStart = null;
    _reflowCanvasFloor = null;
    _transitioning = false;
    _settledDay = day;
  }

  @override
  void dispose() {
    _horizontal.dispose();
    _vertical.dispose();
    _reflow.dispose();
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _commitFinish();
    return LayoutBuilder(builder: (context, constraints) {
      final viewport = constraints.biggest;
      final timeInset = StudyFloatingTimeInset.of(context);
      final paragraphTimeInset = StudyFloatingTimeInset.layoutOf(context);
      final originDelta = _lastOriginX - widget.viewportOriginX;
      final resized = _lastViewport != null &&
          (_lastViewport != viewport ||
              originDelta != 0 ||
              _layout?.timeInset != timeInset ||
              _layout?.paragraphTimeInset != paragraphTimeInset);
      final previous = _layout;
      _lastViewport = viewport;
      _lastOriginX = widget.viewportOriginX;
      final media = MediaQuery.of(context), theme = Theme.of(context);
      final next = (!resized && !_snapshotChanged ? _layout : null) ??
          _AnchorLayout.make(
              entries: widget.entries,
              day: widget.selectedDay,
              viewport: viewport,
              timeInset: timeInset,
              slots: widget.slots,
              textScaler: media.textScaler,
              direction: Directionality.of(context),
              titleStyle: theme.textTheme.titleMedium!,
              detailStyle: theme.textTheme.bodySmall!,
              paragraphTimeInset: paragraphTimeInset,
              textBudget: previous);
      _snapshotChanged = false;
      if (resized && previous != null && !_reduce && TickerMode.of(context)) {
        _rebaseResize(previous, next, originDelta);
      }
      _layout = next;
      _dayOffset = next.clampOffset(_dayOffset, true);
      _weekOffset = next.clampOffset(_weekOffset, false);
      if (!widget.dayMode && !_weekVisited && !_transitioning) {
        _weekOffset = next.initialWeekOffset(widget.selectedDay);
        _queueFinish();
      }
      return AnimatedBuilder(
          animation: Listenable.merge([_motion, _reflow]),
          builder: (context, _) => _content(context, next));
    });
  }

  void _rebaseResize(
      _AnchorLayout previous, _AnchorLayout next, double originDelta) {
    final actual = _actual;
    final dayOffset = _moving || !_settledDay ? _dayOffset : actual;
    final weekOffset = _moving || _settledDay ? _weekOffset : actual;
    final visible = _geometry(previous, dayOffset, weekOffset)
        .shift(Offset(originDelta, 0));
    _dayOffset = next.clampOffset(dayOffset, true);
    _weekOffset = !_weekVisited
        ? next.initialWeekOffset(widget.selectedDay)
        : next.clampOffset(weekOffset, false);
    final destination =
        _geometry(next, _dayOffset, _weekOffset, includeCorrection: false);
    // Keep p and its simulation untouched, including its signed velocity when
    // the user crosses the breakpoint again. Only the measured difference
    // between the old visible layout and the new real layout eases away.
    _correction = _GeometryCorrection.between(visible, destination);
    // Flutter corrects a ScrollPosition during layout when its new extent is
    // smaller. Keep the currently visible scroll position valid until the
    // corrected geometry and the destination scroll are committed together.
    _reflowCanvasFloor = Size(next.viewport.width + actual.dx,
        math.max(1.0, next.viewport.height - next.headerHeight) + actual.dy);
    // Navigation can update the viewport on every tick. All of those rebases
    // share the current mode transition's deadline rather than adding another
    // 490ms tail after the navigation has already reached its destination.
    final elapsed = _motion.lastElapsedDuration ?? Duration.zero;
    final remaining = _modeDuration - elapsed;
    if (_motion.isAnimating) {
      _correctionModeStart = elapsed;
      _correctionModeDuration = remaining;
      // Use the existing mode ticker itself. Starting a new ticker during
      // layout would begin one frame later and miss the shared deadline.
      _reflow.stop();
    } else {
      _correctionModeStart = null;
      _reflow.duration = const Duration(milliseconds: 490);
      _reflow.forward(from: 0);
    }
  }

  _GeometryFrame _geometry(_AnchorLayout layout, Offset day, Offset week,
      {bool includeCorrection = true}) {
    final p = debugProgress, q = _part(p, 0, .68);
    final frame = _GeometryFrame(
        cards: {
          for (final card in layout.cards)
            card.id: _CoursePose.at(card, p, q, day, week)
        },
        headers: [
          for (var dayIndex = 1; dayIndex <= 7; dayIndex++)
            Rect.lerp(layout.dayHeader(dayIndex).shift(Offset(-day.dx, 0)),
                layout.weekHeader(dayIndex).shift(Offset(-week.dx, 0)), q)!
        ],
        grid: Rect.fromLTWH(
            -week.dx, -week.dy, layout.weekSize.width, layout.weekSize.height),
        slots: [
          for (var i = 0; i < layout.slots.length; i++)
            Rect.fromLTWH(
                layout.timeInset - week.dx,
                i * layout.rowHeight + 8 - week.dy,
                layout.gutter - layout.timeInset,
                math.max(1.0, layout.rowHeight - 8))
        ]);
    if (!includeCorrection || _correction == null) return frame;
    final modeStart = _correctionModeStart;
    final fraction = modeStart == null
        ? _reflow.value
        : ((_motion.lastElapsedDuration ?? _modeDuration) - modeStart)
                .inMicroseconds /
            math.max(1, _correctionModeDuration.inMicroseconds);
    return _correction!.apply(frame, 1 - _part(fraction, 0, 1));
  }

  Widget _content(BuildContext context, _AnchorLayout g) {
    final p = debugProgress;
    final actual = _actual;
    final dayOffset = _moving ? _dayOffset : actual;
    final weekOffset = _moving ? _weekOffset : actual;
    final geometry = _geometry(g, dayOffset, weekOffset);
    final naturalWidth = _transitioning
        ? math.max(g.daySize.width, g.weekSize.width)
        : (_settledDay ? g.daySize.width : g.weekSize.width);
    final naturalHeight = _transitioning
        ? math.max(g.daySize.height, g.weekSize.height)
        : (_settledDay ? g.daySize.height : g.weekSize.height);
    final canvasWidth = math.max(naturalWidth, _reflowCanvasFloor?.width ?? 0);
    final canvasHeight =
        math.max(naturalHeight, _reflowCanvasFloor?.height ?? 0);
    final header = g.headerHeight;
    final color = Theme.of(context).colorScheme;
    final bodyHeight = math.max(1.0, g.viewport.height - header);
    _debugRects.clear();
    return ScrollConfiguration(
        behavior: const MaterialScrollBehavior().copyWith(dragDevices: {
          PointerDeviceKind.touch,
          PointerDeviceKind.mouse,
          PointerDeviceKind.trackpad,
          PointerDeviceKind.stylus,
        }),
        child: Scrollbar(
            controller: _horizontal,
            thumbVisibility: true,
            notificationPredicate: (notice) =>
                notice.metrics.axis == Axis.horizontal,
            child: SingleChildScrollView(
                key: const ValueKey('schedule-anchor-horizontal'),
                controller: _horizontal,
                primary: false,
                scrollDirection: Axis.horizontal,
                child: SizedBox(
                    width: canvasWidth,
                    height: g.viewport.height,
                    child: Column(children: [
                      SizedBox(
                          height: header,
                          child: Stack(clipBehavior: Clip.hardEdge, children: [
                            for (var day = 1; day <= 7; day++)
                              Positioned.fromRect(
                                  rect: geometry.headers[day - 1]
                                      .shift(Offset(actual.dx, 0)),
                                  child: _DateHeader(
                                      key: ValueKey('schedule-anchor-day-$day'),
                                      day: day,
                                      date: widget.weekStart
                                          .add(Duration(days: day - 1)),
                                      selected: day == widget.selectedDay,
                                      today: civilDate(widget.today) ==
                                          civilDate(widget.weekStart
                                              .add(Duration(days: day - 1))),
                                      onPressed: () =>
                                          widget.onSelectDay(day))),
                          ])),
                      SizedBox(
                          height: bodyHeight,
                          child: Scrollbar(
                              controller: _vertical,
                              thumbVisibility: true,
                              notificationPredicate: (notice) =>
                                  notice.metrics.axis == Axis.vertical,
                              child: SingleChildScrollView(
                                  key: const ValueKey(
                                      'schedule-anchor-vertical'),
                                  controller: _vertical,
                                  primary: false,
                                  child: SizedBox(
                                      key: const ValueKey(
                                          'schedule-anchor-canvas'),
                                      width: canvasWidth,
                                      height:
                                          math.max(bodyHeight, canvasHeight),
                                      child: Stack(
                                          clipBehavior: Clip.hardEdge,
                                          children: [
                                            Positioned.fromRect(
                                                rect:
                                                    geometry.grid.shift(actual),
                                                child: IgnorePointer(
                                                    child: Opacity(
                                                        opacity:
                                                            _part(p, .1, .78),
                                                        child: CustomPaint(
                                                            key: const ValueKey(
                                                                'anchor-grid'),
                                                            painter: _GridPainter(
                                                                g,
                                                                color
                                                                    .outlineVariant))))),
                                            for (var i = 0;
                                                i < g.slots.length;
                                                i++)
                                              Positioned.fromRect(
                                                  rect: geometry.slots[i]
                                                      .shift(actual),
                                                  child: IgnorePointer(
                                                      child: ExcludeSemantics(
                                                          excluding: p < .5,
                                                          child: Opacity(
                                                              opacity: _part(
                                                                  p, .16, .7),
                                                              child: Text(
                                                                  key: ValueKey(
                                                                      'anchor-slot-time-$i'),
                                                                  '${i + 1}\n${g.slots[i].start}\n${g.slots[i].end}',
                                                                  textAlign:
                                                                      TextAlign
                                                                          .center,
                                                                  style: g
                                                                      .detailStyle))))),
                                            Positioned(
                                                left: 18 +
                                                    actual.dx -
                                                    dayOffset.dx,
                                                top: 8 +
                                                    actual.dy -
                                                    dayOffset.dy,
                                                width: g.daySize.width - 36,
                                                child: IgnorePointer(
                                                    child: ExcludeSemantics(
                                                        excluding: p > .5,
                                                        child: Opacity(
                                                            opacity: 1 -
                                                                _part(p, 0, .3),
                                                            child: Text(
                                                                '${widget.weekStart.add(Duration(days: widget.selectedDay - 1)).month}月${widget.weekStart.add(Duration(days: widget.selectedDay - 1)).day}日 · ${g.dayCount} 节课',
                                                                style: g
                                                                    .detailStyle))))),
                                            if (g.dayCount == 0)
                                              Positioned(
                                                  left: 18 +
                                                      actual.dx -
                                                      dayOffset.dx,
                                                  top: g.summaryHeight +
                                                      24 +
                                                      actual.dy -
                                                      dayOffset.dy,
                                                  width: g.daySize.width - 36,
                                                  child: IgnorePointer(
                                                      child: ExcludeSemantics(
                                                          excluding: p > .5,
                                                          child: Opacity(
                                                              opacity: 1 -
                                                                  _part(
                                                                      p, 0, .5),
                                                              child: const Text(
                                                                  '这一天没有课程，可切换整周查看。'))))),
                                            for (final card in g.cards)
                                              _positionCourse(
                                                  context,
                                                  card,
                                                  geometry.cards[card.id]!,
                                                  actual),
                                          ]))))),
                    ])))));
  }

  Widget _positionCourse(BuildContext context, _CourseLayout card,
      _CoursePose pose, Offset actual) {
    final alpha = pose.alpha;
    final visibleRect = pose.rect.shift(actual);
    _debugRects[card.id] = pose.rect;
    return Positioned.fromRect(
        key: ValueKey('schedule-anchor-position-${card.id}'),
        rect: visibleRect,
        child: Offstage(
            offstage: alpha == 0,
            child: ExcludeFocus(
                excluding: alpha < .5,
                child: IgnorePointer(
                    ignoring: alpha < .5,
                    child: ExcludeSemantics(
                        excluding: alpha < .5,
                        child: Opacity(
                            opacity: alpha,
                            child: _CourseCard(
                                key: ValueKey(
                                    'schedule-anchor-course-${card.id}'),
                                card: card,
                                titleAt: pose.titleAt,
                                roomAt: pose.roomAt,
                                timeAt: pose.timeAt,
                                selected: card.entry['id']?.toString() ==
                                    widget.selectedEntryId,
                                onOpen: () => widget.onOpen(card.entry),
                                onSecondaryTap: widget.onSecondaryTap == null
                                    ? null
                                    : (offset) => widget.onSecondaryTap!(
                                        card.entry, offset),
                                onFocus: (context) {
                                  if (!_moving) {
                                    Scrollable.ensureVisible(context,
                                        alignment: .3, duration: Duration.zero);
                                  }
                                })))))));
  }
}

class _LayoutEnvironment {
  _LayoutEnvironment.of(BuildContext context)
      : scaler = MediaQuery.textScalerOf(context),
        bold = MediaQuery.boldTextOf(context),
        direction = Directionality.of(context),
        locale = Localizations.localeOf(context),
        title = Theme.of(context).textTheme.titleMedium,
        detail = Theme.of(context).textTheme.bodySmall;
  final TextScaler scaler;
  final bool bold;
  final TextDirection direction;
  final Locale locale;
  final TextStyle? title, detail;

  @override
  bool operator ==(Object other) =>
      other is _LayoutEnvironment &&
      scaler == other.scaler &&
      bold == other.bold &&
      direction == other.direction &&
      locale == other.locale &&
      title == other.title &&
      detail == other.detail;
  @override
  int get hashCode =>
      Object.hash(scaler, bold, direction, locale, title, detail);
}

class _CoursePose {
  const _CoursePose(
      this.rect, this.titleAt, this.roomAt, this.timeAt, this.alpha);
  factory _CoursePose.at(
      _CourseLayout card, double p, double q, Offset day, Offset week) {
    final active = card.source != null;
    final target = (card.target ?? card.source!).shift(-week);
    final source = (card.source ?? card.target!).shift(-day);
    final alpha = active
        ? (card.target == null ? 1 - _part(p, 0, .68) : 1.0)
        : _part(p, .68, 1);
    final rect = Rect.lerp(active ? source : target, target, active ? q : 1)!;
    // The original time-first choreography and fixed text fields remain shared
    // by button changes and window-driven changes.
    final title = Offset.lerp(
        card.sourceTitle, card.targetTitle, active ? _part(q, .32, .88) : 1)!;
    final room = Offset.lerp(
        card.sourceRoom, card.targetRoom, active ? _part(q, .32, .88) : 1)!;
    final time = Offset.lerp(
        card.sourceTime, card.targetTime, active ? _part(q, 0, .3) : 1)!;
    return _CoursePose(
        Rect.fromLTWH(
            rect.left,
            rect.top,
            rect.width,
            math.max(
                rect.height,
                math.max(room.dy + card.roomHeight, time.dy + card.timeHeight) +
                    card.padding)),
        title,
        room,
        time,
        alpha);
  }
  final Rect rect;
  final Offset titleAt, roomAt, timeAt;
  final double alpha;
}

class _GeometryFrame {
  const _GeometryFrame(
      {required this.cards,
      required this.headers,
      required this.grid,
      required this.slots});
  final Map<String, _CoursePose> cards;
  final List<Rect> headers;
  final Rect grid;
  final List<Rect> slots;

  _GeometryFrame shift(Offset offset) => _GeometryFrame(
      cards: {
        for (final entry in cards.entries)
          entry.key: _CoursePose(
              entry.value.rect.shift(offset),
              entry.value.titleAt,
              entry.value.roomAt,
              entry.value.timeAt,
              entry.value.alpha)
      },
      headers: [for (final header in headers) header.shift(offset)],
      grid: grid.shift(offset),
      slots: [for (final slot in slots) slot.shift(offset)]);
}

class _GeometryCorrection {
  _GeometryCorrection.between(this.visible, this.baseline);
  final _GeometryFrame visible, baseline;

  _GeometryFrame apply(_GeometryFrame current, double weight) {
    Rect rect(Rect now, Rect from, Rect to) => Rect.fromLTRB(
        now.left + (from.left - to.left) * weight,
        now.top + (from.top - to.top) * weight,
        now.right + (from.right - to.right) * weight,
        now.bottom + (from.bottom - to.bottom) * weight);
    final cards = <String, _CoursePose>{};
    for (final entry in current.cards.entries) {
      final now = entry.value,
          from = visible.cards[entry.key],
          to = baseline.cards[entry.key];
      cards[entry.key] = from == null || to == null
          ? now
          : _CoursePose(
              rect(now.rect, from.rect, to.rect),
              now.titleAt + (from.titleAt - to.titleAt) * weight,
              now.roomAt + (from.roomAt - to.roomAt) * weight,
              now.timeAt + (from.timeAt - to.timeAt) * weight,
              (now.alpha + (from.alpha - to.alpha) * weight).clamp(0.0, 1.0));
    }
    return _GeometryFrame(
        cards: cards,
        headers: [
          for (var i = 0; i < current.headers.length; i++)
            rect(current.headers[i], visible.headers[i], baseline.headers[i])
        ],
        grid: rect(current.grid, visible.grid, baseline.grid),
        slots: [
          for (var i = 0; i < current.slots.length; i++)
            rect(current.slots[i], visible.slots[i], baseline.slots[i])
        ]);
  }
}

double _part(double p, double a, double b) {
  final t = ((p - a) / (b - a)).clamp(0.0, 1.0);
  return t * t * (3 - 2 * t);
}

String _dataSignature(List<Map<String, dynamic>> entries) => entries
    .map((e) => [
          e['id'],
          e['weekday'],
          e['start_time'],
          e['end_time'],
          e['course_name'],
          e['location']
        ].join('\u001e'))
    .join('\u001f');

class _AnchorSimulation extends Simulation {
  _AnchorSimulation(this.from, this.to, this.initialVelocity)
      : seconds = math.max(.08, .49 * (to - from).abs());
  final double from, to, initialVelocity, seconds;

  @override
  double x(double time) {
    final t = (time / seconds).clamp(0.0, 1.0), t2 = t * t, t3 = t2 * t;
    return ((2 * t3 - 3 * t2 + 1) * from +
            (t3 - 2 * t2 + t) * seconds * initialVelocity +
            (-2 * t3 + 3 * t2) * to)
        .clamp(0.0, 1.0);
  }

  @override
  double dx(double time) {
    if (time >= seconds) return 0;
    final t = (time / seconds).clamp(0.0, 1.0), t2 = t * t;
    return ((6 * t2 - 6 * t) * from +
            (3 * t2 - 4 * t + 1) * seconds * initialVelocity +
            (-6 * t2 + 6 * t) * to) /
        seconds;
  }

  @override
  bool isDone(double time) => time >= seconds;
}

class _CourseCard extends StatefulWidget {
  const _CourseCard(
      {super.key,
      required this.card,
      required this.titleAt,
      required this.roomAt,
      required this.timeAt,
      required this.selected,
      required this.onOpen,
      this.onSecondaryTap,
      required this.onFocus});
  final _CourseLayout card;
  final Offset titleAt, roomAt, timeAt;
  final bool selected;
  final VoidCallback onOpen;
  final ValueChanged<Offset>? onSecondaryTap;
  final ValueChanged<BuildContext> onFocus;

  @override
  State<_CourseCard> createState() => _CourseCardState();
}

class _CourseCardState extends State<_CourseCard> {
  final FocusNode _focus = FocusNode();
  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final card = widget.card;
    final tone = CoursePalette.of(context, card.name);
    return Focus(
        canRequestFocus: false,
        onKeyEvent: (node, event) {
          if (event is KeyDownEvent &&
              ((event.logicalKey == LogicalKeyboardKey.f10 &&
                      HardwareKeyboard.instance.isShiftPressed) ||
                  event.logicalKey == LogicalKeyboardKey.contextMenu) &&
              widget.onSecondaryTap != null) {
            final render = context.findRenderObject()! as RenderBox;
            widget.onSecondaryTap!(
                render.localToGlobal(render.size.center(Offset.zero)));
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Semantics(
            button: true,
            selected: widget.selected,
            label:
                '${card.name}，${card.room}，${card.time.replaceAll('\n', '到')}',
            excludeSemantics: true,
            onTap: widget.onOpen,
            child: Material(
                color: tone.fill,
                clipBehavior: Clip.antiAlias,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(StudyShapes.card),
                    side: BorderSide(
                        color: widget.selected ? tone.ink : tone.line,
                        width: widget.selected ? 2 : 1)),
                child: InkWell(
                    focusNode: _focus,
                    onFocusChange: (focused) {
                      if (focused) widget.onFocus(context);
                    },
                    onTap: widget.onOpen,
                    onSecondaryTapDown: widget.onSecondaryTap == null
                        ? null
                        : (details) =>
                            widget.onSecondaryTap!(details.globalPosition),
                    child: LayoutBuilder(
                        builder: (context, box) =>
                            Stack(clipBehavior: Clip.none, children: [
                              Positioned(
                                  left: widget.titleAt.dx,
                                  top: widget.titleAt.dy,
                                  width: card.textWidth,
                                  height: card.titleHeight,
                                  child: Text(card.name,
                                      key: ValueKey('anchor-title-${card.id}'),
                                      maxLines: 4,
                                      overflow: TextOverflow.ellipsis,
                                      style: card.titleStyle
                                          .copyWith(color: tone.ink))),
                              Positioned(
                                  left: widget.roomAt.dx,
                                  top: widget.roomAt.dy,
                                  width: card.textWidth,
                                  height: card.roomHeight,
                                  child: Text(card.room,
                                      key: ValueKey('anchor-room-${card.id}'),
                                      maxLines: 3,
                                      overflow: TextOverflow.ellipsis,
                                      style: card.detailStyle
                                          .copyWith(color: tone.ink))),
                              Positioned(
                                  left: widget.timeAt.dx,
                                  top: widget.timeAt.dy,
                                  width: card.timeWidth,
                                  height: card.timeHeight,
                                  child: Opacity(
                                      opacity: ((box.maxWidth -
                                                  widget.timeAt.dx -
                                                  card.timeWidth -
                                                  card.padding) /
                                              4)
                                          .clamp(0.0, 1.0),
                                      child: Text(card.time,
                                          key: ValueKey(
                                              'anchor-time-${card.id}'),
                                          maxLines: 2,
                                          overflow: TextOverflow.ellipsis,
                                          style: card.detailStyle
                                              .copyWith(color: tone.ink)))),
                            ]))))));
  }
}

class _DateHeader extends StatelessWidget {
  const _DateHeader(
      {super.key,
      required this.day,
      required this.date,
      required this.selected,
      required this.today,
      required this.onPressed});
  final int day;
  final DateTime date;
  final bool selected, today;
  final VoidCallback onPressed;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 4),
        child: TextButton(
            style: TextButton.styleFrom(
                minimumSize: const Size(48, 48),
                padding: EdgeInsets.zero,
                backgroundColor:
                    selected ? colors.primary.withOpacity(.12) : null,
                side: today
                    ? BorderSide(color: colors.primary.withOpacity(.5))
                    : null,
                shape: const StadiumBorder()),
            onPressed: onPressed,
            child: Text(
                '${['一', '二', '三', '四', '五', '六', '日'][day - 1]}\n${date.day}',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: selected || today
                        ? colors.primary
                        : colors.onSurfaceVariant,
                    fontWeight:
                        selected ? FontWeight.w600 : FontWeight.w400))));
  }
}

class _CourseLayout {
  _CourseLayout(
      {required this.id,
      required this.entry,
      required this.name,
      required this.room,
      required this.time,
      required this.titleStyle,
      required this.detailStyle,
      required this.textWidth,
      required this.timeWidth,
      required this.titleHeight,
      required this.roomHeight,
      required this.timeHeight,
      required this.padding,
      required this.sourceTitle,
      required this.sourceRoom,
      required this.sourceTime,
      required this.targetTitle,
      required this.targetRoom,
      required this.targetTime});
  final String id, name, room, time;
  final Map<String, dynamic> entry;
  final TextStyle titleStyle, detailStyle;
  final double textWidth,
      timeWidth,
      titleHeight,
      roomHeight,
      timeHeight,
      padding;
  final Offset sourceTitle,
      sourceRoom,
      sourceTime,
      targetTitle,
      targetRoom,
      targetTime;
  Rect? source, target;
  double get contentHeight => targetTime.dy + timeHeight + padding;
}

class _AnchorLayout {
  _AnchorLayout(
      {required this.viewport,
      required this.daySize,
      required this.weekSize,
      required this.headerHeight,
      required this.gutter,
      required this.timeInset,
      required this.paragraphTimeInset,
      required this.slots,
      required this.column,
      required this.rowHeight,
      required this.summaryHeight,
      required this.dayCount,
      required this.cards,
      required this.detailStyle});
  final Size viewport, daySize, weekSize;
  final List<LessonSlot> slots;
  final double headerHeight,
      gutter,
      column,
      rowHeight,
      summaryHeight,
      timeInset,
      paragraphTimeInset;
  final int dayCount;
  final List<_CourseLayout> cards;
  final TextStyle detailStyle;

  Rect dayHeader(int day) => Rect.fromLTWH(
      12 + (day - 1) * (daySize.width - 24) / 7,
      0,
      (daySize.width - 24) / 7,
      headerHeight);
  Rect weekHeader(int day) =>
      Rect.fromLTWH(gutter + (day - 1) * column, 0, column, headerHeight);

  Offset clampOffset(Offset value, bool day) {
    final size = day ? daySize : weekSize;
    return Offset(
        value.dx.clamp(0.0, math.max(0.0, size.width - viewport.width)),
        value.dy.clamp(0.0,
            math.max(0.0, size.height - (viewport.height - headerHeight))));
  }

  Offset initialWeekOffset(int day) => clampOffset(
      Offset(gutter + (day - .5) * column - viewport.width / 2, 0), false);

  static _AnchorLayout make(
      {required List<Map<String, dynamic>> entries,
      required int day,
      required Size viewport,
      required double timeInset,
      required List<LessonSlot> slots,
      required TextScaler textScaler,
      required TextDirection direction,
      required TextStyle titleStyle,
      required TextStyle detailStyle,
      required double paragraphTimeInset,
      _AnchorLayout? textBudget}) {
    final scale = math.max(1.0, textScaler.scale(13) / 13);
    Size measure(String value, TextStyle style, double width, int lines) {
      final painter = TextPainter(
          text: TextSpan(text: value, style: style),
          textDirection: direction,
          textScaler: textScaler,
          maxLines: lines,
          ellipsis: '…')
        ..layout(maxWidth: width);
      return Size(
          painter.width.ceilToDouble() + 1, painter.height.ceilToDouble() + 1);
    }

    final headerHeight = math.max(
        60.0, measure('一\n15', detailStyle, double.infinity, 2).height + 12);
    final summaryHeight = measure('10月15日 · 3节课', detailStyle,
                math.max(100, viewport.width - 36), 1)
            .height +
        24;
    final gutter = math.max(
        60.0, measure('08:15', detailStyle, double.infinity, 1).width + 16);
    final blocks = <Map<String, dynamic>, TimetableBlock>{};
    for (var weekday = 1; weekday <= 7; weekday++) {
      for (final block in layoutDay(
          entries.where((e) => e['weekday'] == weekday),
          slots: slots)) {
        blocks[block.entry] = block;
      }
    }
    // The transparent time gutter alone protects the labels. All seven days
    // fit the actual viewport; course text can never enlarge the whole canvas.
    final timeGutter = timeInset + gutter;
    final column = math.max(1.0, (viewport.width - timeGutter) / 7);
    final paragraphColumn =
        math.max(1.0, (viewport.width - paragraphTimeInset - gutter) / 7);
    final glyphWidth = measure('课', titleStyle, double.infinity, 1).width;
    bool stackConflict(TimetableBlock? block) =>
        block != null &&
        block.laneCount > 1 &&
        paragraphColumn / block.laneCount - 8 < glyphWidth + 8;
    final previousCards = {
      for (final card in textBudget?.cards ?? <_CourseLayout>[]) card.id: card
    };
    final dayWidth = math.max(viewport.width, 7 * 54.0 * scale + 24);
    final sourceWidth = dayWidth - 36;
    final cards = <_CourseLayout>[];
    final ids = <String, int>{};
    var rowHeight = 72.0 * scale;
    for (var index = 0; index < entries.length; index++) {
      final entry = entries[index], block = blocks[entry];
      final rawId = (entry['id'] ??
              '${entry['weekday']}:${entry['start_time']}:${entry['end_time']}:${entry['course_id'] ?? index}')
          .toString();
      final duplicate = ids.update(rawId, (v) => v + 1, ifAbsent: () => 0);
      final id = duplicate == 0 ? rawId : '$rawId::dup$duplicate';
      final previous = previousCards[id];
      final name = '${entry['course_name'] ?? '课程'}';
      final roomValue = '${entry['location'] ?? ''}';
      final room =
          '${stackConflict(block) ? '同时段 · ' : ''}${roomValue.isEmpty ? '教室待定' : '@$roomValue'}';
      final time =
          '${entry['start_time'] ?? '时间待定'}\n${entry['end_time'] ?? ''}';
      final targetWidth = paragraphColumn /
              (stackConflict(block) ? 1 : (block?.laneCount ?? 1)) -
          8;
      final measuredTime = measure(time, detailStyle, double.infinity, 2);
      final padding = math.min(
          12.0 * scale,
          math.max(
              4.0,
              (targetWidth - math.max(glyphWidth, measuredTime.width) - 8) /
                  2));
      final available = sourceWidth -
          paragraphTimeInset -
          padding * 2 -
          measuredTime.width -
          14 * scale;
      final stacked = available < 72 * scale;
      final maxTextWidth = math.max(
          1.0,
          math.min(
              targetWidth - 2 * padding,
              stacked
                  ? sourceWidth - paragraphTimeInset - padding * 2
                  : available));
      // Day/week share one paragraph budget at the same viewport. A native
      // resize must remeasure in both directions, otherwise the narrowest
      // historical window permanently pins the title and room to one glyph.
      final budget =
          previous != null && (previous.textWidth - maxTextWidth).abs() <= .01
              ? previous
              : null;
      final textWidth = budget?.textWidth ?? maxTextWidth;
      final title = budget == null
          ? measure(name, titleStyle, textWidth, 4)
          : Size(textWidth, budget.titleHeight);
      final place = budget == null
          ? measure(room, detailStyle, textWidth, 3)
          : Size(textWidth, budget.roomHeight);
      final timeWidth = measuredTime.width;
      final timeSize = measure(time, detailStyle, timeWidth, 2);
      final titleX =
          timeInset + (stacked ? padding : padding + timeWidth + 14 * scale);
      final roomY = padding + title.height + 5 * scale;
      final timeY = roomY + place.height + 8 * scale;
      final card = _CourseLayout(
          id: id,
          entry: entry,
          name: name,
          room: room,
          time: time,
          titleStyle: titleStyle,
          detailStyle: detailStyle,
          textWidth: textWidth,
          timeWidth: timeWidth,
          titleHeight: title.height,
          roomHeight: place.height,
          timeHeight: timeSize.height,
          padding: padding,
          sourceTitle: Offset(titleX, padding),
          sourceRoom: Offset(titleX, roomY),
          sourceTime: Offset(timeInset + padding, stacked ? timeY : padding),
          targetTitle: Offset(padding, padding),
          targetRoom: Offset(padding, roomY),
          targetTime: Offset(padding, timeY));
      cards.add(card);
      if (block != null) {
        rowHeight = math.max(
            rowHeight,
            (card.contentHeight + 8) *
                (stackConflict(block) ? block.laneCount : 1) /
                (block.bottom - block.top));
      }
    }
    var sourceY = summaryHeight;
    final active = cards.where((c) => c.entry['weekday'] == day).toList()
      ..sort((a, b) =>
          '${a.entry['start_time']}'.compareTo('${b.entry['start_time']}'));
    for (final card in active) {
      // Reserve the final text budget so moving the left-hand time below the
      // title cannot temporarily clip it or push through the following card.
      final height = math.max(96 * scale, card.contentHeight);
      card.source = Rect.fromLTWH(18, sourceY, sourceWidth, height);
      sourceY += height + 12;
    }
    for (final card in cards) {
      final block = blocks[card.entry];
      final weekday = (card.entry['weekday'] as num?)?.toInt();
      if (block == null || weekday == null || weekday < 1 || weekday > 7) {
        continue;
      }
      final stack = stackConflict(block);
      final laneWidth = stack ? column : column / block.laneCount;
      final height = (block.bottom - block.top) *
          rowHeight /
          (stack ? block.laneCount : 1);
      card.target = Rect.fromLTWH(
          timeGutter +
              (weekday - 1) * column +
              (stack ? 0 : block.lane * laneWidth) +
              4,
          block.top * rowHeight + (stack ? block.lane * height : 0) + 4,
          laneWidth - 8,
          height - 8);
    }
    // Entries with neither a valid day source nor a real grid destination are
    // left to the caller's existing invalid-course entry, never given fake cells.
    cards.removeWhere((card) => card.source == null && card.target == null);
    return _AnchorLayout(
        viewport: viewport,
        daySize: Size(dayWidth, math.max(sourceY + 24, 160 * scale)),
        weekSize: Size(viewport.width, slots.length * rowHeight + 24),
        headerHeight: headerHeight,
        gutter: timeGutter,
        timeInset: timeInset,
        paragraphTimeInset: paragraphTimeInset,
        slots: slots,
        column: column,
        rowHeight: rowHeight,
        summaryHeight: summaryHeight,
        dayCount: active.length,
        cards: cards,
        detailStyle: detailStyle);
  }
}

class _GridPainter extends CustomPainter {
  _GridPainter(this.layout, this.color);
  final _AnchorLayout layout;
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = .6;
    final rowHeight = (size.height - 24) / layout.slots.length;
    final column = (size.width - layout.gutter) / 7;
    for (var slot = 0; slot <= layout.slots.length; slot++) {
      final y = slot * rowHeight;
      canvas.drawLine(Offset(layout.gutter, y), Offset(size.width, y), paint);
    }
    for (var day = 0; day <= 7; day++) {
      final x = layout.gutter + day * column;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(_GridPainter oldDelegate) =>
      oldDelegate.layout.rowHeight != layout.rowHeight ||
      oldDelegate.layout.column != layout.column ||
      oldDelegate.color != color;
}
