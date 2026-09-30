/// Trace — an agent run timeline. MIT © 2026 Yagnik Barasiya.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

/// What a step in the timeline is.
enum TraceStepKind { reasoning, tool, parallel, message, finish }

/// Where a step is in its life.
enum StepState { running, done, failed, cancelled }

/// What can happen to a step.
enum StepEvent { done, fail, cancel, retry }

/// How a new tool relates to the step before it.
enum GroupDecision { join, wrap, create }

/// The name of a parallel group created for you.
const defaultGroupName = 'Running in parallel';

/// The only legal step state changes. Anything else is a bug in the caller.
StepState transition(StepState state, StepEvent event) {
  final next = switch ((state, event)) {
    (StepState.running, StepEvent.done) => StepState.done,
    (StepState.running, StepEvent.fail) => StepState.failed,
    (StepState.running, StepEvent.cancel) => StepState.cancelled,
    (StepState.failed, StepEvent.retry) => StepState.running,
    _ => null,
  };
  if (next == null) throw StateError('Trace: cannot ${event.name} a ${state.name} step');
  return next;
}

/// 1.3s under ten seconds, 12s under a minute, then 1m 05s.
String formatDuration(Duration duration) {
  final seconds = (duration.isNegative ? 0 : duration.inMicroseconds) / 1e6;
  if (seconds < 9.95) return '${seconds.toStringAsFixed(1)}s';
  final whole = seconds.round();
  if (whole < 60) return '${whole}s';
  return '${whole ~/ 60}m ${(whole % 60).toString().padLeft(2, '0')}s';
}

/// Indented JSON for tool arguments and results, with long strings cut short.
String summarizeJson(Object? value, {int maxLen = 80}) {
  if (value == null) return '';
  String cut(String s) => s.length > maxLen ? '${s.substring(0, maxLen - 1)}…' : s;
  if (value is String) return cut(value);
  Object? trim(Object? v) => switch (v) {
    final String s => cut(s),
    final Map<dynamic, dynamic> m => m.map((key, x) => MapEntry('$key', trim(x))),
    final List<dynamic> l => l.map(trim).toList(),
    _ => v,
  };
  try {
    return const JsonEncoder.withIndent('  ').convert(trim(value));
  } catch (_) {
    return value.toString();
  }
}

/// Tools that start before the previous one finishes run in parallel: wrap a
/// lone running tool into a group, or join a running group.
GroupDecision groupDecision({TraceStepKind? kind, StepState? state, bool nested = false}) {
  if (kind == null || nested) return GroupDecision.create;
  if (kind == TraceStepKind.parallel && state == StepState.running) return GroupDecision.join;
  if (kind == TraceStepKind.tool && state == StepState.running) return GroupDecision.wrap;
  return GroupDecision.create;
}

/// Which provider's stream [TraceController.fromEvents] reads.
enum TraceFormat { openai, anthropic, aiSdk }

/// One timeline operation, e.g. `{'op': 'tool.start', 'id': 'fc_1', 'name': 'search'}`.
typedef TraceOp = Map<String, Object?>;

/// Turns one decoded stream event into operations.
typedef TraceMapper = List<TraceOp> Function(Map<String, dynamic> event);

Object? _parseArgs(Object? text) {
  if (text is! String) return text;
  try {
    return jsonDecode(text);
  } catch (_) {
    return text;
  }
}

String _message(Object? error) => switch (error) {
  null => 'Run failed',
  final Map<dynamic, dynamic> m => '${m['message'] ?? 'Run failed'}',
  _ => '$error',
};

TraceMapper _openaiMapper() {
  final started = <Object?>{};
  return (event) {
    switch (event['type']) {
      case 'response.reasoning_summary_text.delta':
        final id = event['item_id'];
        return [
          if (started.add(id)) {'op': 'reasoning.start', 'id': id},
          {'op': 'reasoning.append', 'id': id, 'text': event['delta']},
        ];
      case 'response.output_item.done':
        final item = event['item'] as Map?;
        if (item?['type'] == 'reasoning' && started.contains(item?['id'])) {
          return [
            {'op': 'reasoning.done', 'id': item!['id']},
          ];
        }
        return const [];
      case 'response.output_item.added':
        final item = event['item'] as Map?;
        if (item?['type'] == 'function_call') {
          return [
            {'op': 'tool.start', 'id': item!['id'], 'name': item['name']},
          ];
        }
        return const [];
      case 'response.function_call_arguments.done':
        return [
          {'op': 'tool.args', 'id': event['item_id'], 'args': _parseArgs(event['arguments'])},
        ];
      case 'response.completed':
        return [
          {'op': 'finish'},
        ];
      case 'response.failed':
        return [
          {'op': 'error', 'message': _message((event['response'] as Map?)?['error'])},
        ];
      case 'error':
        return [
          {'op': 'error', 'message': _message(event)},
        ];
      default:
        return const [];
    }
  };
}

TraceMapper _anthropicMapper() {
  final blocks = <Object?, ({String kind, String id, StringBuffer json})>{};
  var turn = 0;
  String? stopReason;
  return (event) {
    switch (event['type']) {
      case 'message_start':
        turn++;
        stopReason = null;
        return const [];
      case 'content_block_start':
        final block = event['content_block'] as Map;
        final index = event['index'];
        if (block['type'] == 'thinking') {
          final id = 'thinking-$turn-$index';
          blocks[index] = (kind: 'thinking', id: id, json: StringBuffer());
          return [
            {'op': 'reasoning.start', 'id': id},
          ];
        }
        if (block['type'] == 'tool_use') {
          blocks[index] = (kind: 'tool', id: '${block['id']}', json: StringBuffer());
          return [
            {'op': 'tool.start', 'id': block['id'], 'name': block['name']},
          ];
        }
        return const [];
      case 'content_block_delta':
        final block = blocks[event['index']];
        final delta = event['delta'] as Map;
        if (block?.kind == 'thinking' && delta['type'] == 'thinking_delta') {
          return [
            {'op': 'reasoning.append', 'id': block!.id, 'text': delta['thinking']},
          ];
        }
        if (block?.kind == 'tool' && delta['type'] == 'input_json_delta') block!.json.write(delta['partial_json']);
        return const [];
      case 'content_block_stop':
        final block = blocks.remove(event['index']);
        if (block?.kind == 'thinking') {
          return [
            {'op': 'reasoning.done', 'id': block!.id},
          ];
        }
        if (block?.kind == 'tool') {
          final json = block!.json.toString();
          return [
            {'op': 'tool.args', 'id': block.id, 'args': json.isEmpty ? <String, dynamic>{} : _parseArgs(json)},
          ];
        }
        return const [];
      case 'message_delta':
        stopReason = (event['delta'] as Map?)?['stop_reason'] as String? ?? stopReason;
        return const [];
      case 'message_stop':
        // A tool_use stop means the agent loop continues with another message.
        if (stopReason == 'tool_use') return const [];
        return [
          {'op': 'finish'},
        ];
      case 'error':
        return [
          {'op': 'error', 'message': _message(event['error'])},
        ];
      default:
        return const [];
    }
  };
}

TraceMapper _aiSdkMapper() {
  final started = <Object?>{};
  List<TraceOp> start(Object? id) => [
    if (started.add(id)) {'op': 'reasoning.start', 'id': id},
  ];
  return (part) {
    switch (part['type']) {
      case 'reasoning-start':
        return start(part['id']);
      case 'reasoning-delta':
        return [
          ...start(part['id']),
          {'op': 'reasoning.append', 'id': part['id'], 'text': part['text'] ?? part['delta'] ?? ''},
        ];
      case 'reasoning-end':
        return [
          {'op': 'reasoning.done', 'id': part['id']},
        ];
      case 'tool-call':
        return [
          {'op': 'tool.start', 'id': part['toolCallId'], 'name': part['toolName']},
          {'op': 'tool.args', 'id': part['toolCallId'], 'args': part['input'] ?? part['args'] ?? <String, dynamic>{}},
        ];
      case 'tool-result':
        return [
          {'op': 'tool.done', 'id': part['toolCallId'], 'result': part['output'] ?? part['result']},
        ];
      case 'tool-error':
        return [
          {'op': 'tool.fail', 'id': part['toolCallId'], 'message': _message(part['error'])},
        ];
      case 'finish':
        return [
          {'op': 'finish'},
        ];
      case 'error':
        return [
          {'op': 'error', 'message': _message(part['error'])},
        ];
      default:
        return const [];
    }
  };
}

/// Turns one provider's stream events into timeline operations. Stateful: make one per run.
TraceMapper createMapper(TraceFormat format) => switch (format) {
  TraceFormat.openai => _openaiMapper(),
  TraceFormat.anthropic => _anthropicMapper(),
  TraceFormat.aiSdk => _aiSdkMapper(),
};

int _uid = 0;

/// One step in the timeline. Get steps from a [TraceController].
class TraceStep {
  TraceStep._(this._controller, {required this.kind, this.name = '', String? id, this.parent})
    : id = id ?? 'step-${++_uid}',
      _startedAt = DateTime.now(),
      open = kind == TraceStepKind.reasoning;

  final TraceController _controller;
  final String id;
  final TraceStepKind kind;
  final String name;
  final TraceStep? parent;
  final List<TraceStep> _children = [];

  StepState _state = StepState.running;
  DateTime _startedAt;
  DateTime? _endedAt;
  final StringBuffer _text = StringBuffer();
  Object? _args;
  Object? _result;
  String? _error;
  double? _fraction;

  /// Whether the body is expanded in the timeline.
  bool open;

  List<TraceStep> get children => List.unmodifiable(_children);
  StepState get state => _state;
  DateTime get startedAt => _startedAt;
  DateTime? get endedAt => _endedAt;
  Duration get elapsed => (_endedAt ?? DateTime.now()).difference(_startedAt);
  String get text => _text.toString();
  Object? get args => _args;
  Object? get result => _result;
  String? get error => _error;
  double? get fraction => _fraction;

  /// The header text.
  String get title {
    switch (kind) {
      case TraceStepKind.reasoning:
        return _state == StepState.running ? 'Thinking' : 'Reasoned for ${formatDuration(elapsed)}';
      case TraceStepKind.parallel:
        final label = _state != StepState.running && name == defaultGroupName ? 'Ran ${_children.length} in parallel' : name;
        return _error == null ? label : '$label · $_error';
      case TraceStepKind.tool:
      case TraceStepKind.message:
      case TraceStepKind.finish:
        return name;
    }
  }

  void append(String text) {
    _text.write(text);
    _controller._changed();
  }

  void setArgs(Object? value) {
    _args = value;
    _controller._changed();
  }

  void progress(double fraction) {
    _fraction = fraction.clamp(0.0, 1.0);
    _controller._changed();
  }

  void done({Object? result}) {
    _move(StepEvent.done);
    if (result != null) _result = result;
    if (kind == TraceStepKind.reasoning) open = false;
    if (kind == TraceStepKind.tool || kind == TraceStepKind.reasoning) {
      _controller._announce('${kind == TraceStepKind.reasoning ? 'Reasoning' : name} finished in ${formatDuration(elapsed)}');
    }
    _settle();
  }

  void fail(String message) {
    _move(StepEvent.fail);
    _error = message;
    _controller._announce('${kind == TraceStepKind.reasoning ? 'Reasoning' : name} failed: $message');
    _settle();
  }

  void cancel() {
    _move(StepEvent.cancel);
    _settle();
  }

  /// Back to running after a failure; call this from `onRetry`, then run the tool again.
  void retry() {
    _state = transition(_state, StepEvent.retry);
    _error = null;
    _result = null;
    _fraction = null;
    _startedAt = DateTime.now();
    _endedAt = null;
    _settle();
  }

  /// Parallel steps only: adds a lane.
  TraceStep tool(String name, {String? id, Object? args}) {
    if (kind != TraceStepKind.parallel) throw StateError('Trace: only a parallel step has lanes');
    final lane = TraceStep._(_controller, kind: TraceStepKind.tool, name: name, id: id, parent: this);
    _children.add(lane);
    _controller._register(lane);
    if (args != null) lane._args = args;
    _childChanged();
    return lane;
  }

  void _move(StepEvent event) {
    _state = transition(_state, event);
    _endedAt = DateTime.now();
  }

  void _settle() {
    parent?._childChanged();
    _controller._changed();
  }

  void _childChanged() {
    final states = _children.map((c) => c._state).toList();
    final running = states.contains(StepState.running);
    if (running && _state != StepState.running) {
      _state = StepState.running;
      _endedAt = null;
      _error = null;
    } else if (!running && _state == StepState.running && states.isNotEmpty) {
      final failed = states.where((s) => s == StepState.failed).length;
      _endedAt = DateTime.now();
      _state = failed > 0 ? StepState.failed : StepState.done;
      _error = failed > 0 ? '$failed of ${states.length} failed' : null;
    }
    _controller._changed();
  }
}

/// Holds an agent run's steps. Pass it to a [Trace] widget.
///
/// ```dart
/// final trace = TraceController();
/// final call = trace.tool('analytics.summary', args: {'days': 30});
/// call.done(result: {'reach': 7200});
/// trace.finish('Post scheduled');
/// ```
class TraceController extends ChangeNotifier {
  final List<TraceStep> _steps = [];
  final Map<String, TraceStep> _byId = {};
  final StreamController<String> _announcements = StreamController<String>.broadcast();
  bool _disposed = false;

  List<TraceStep> get steps => List.unmodifiable(_steps);
  TraceStep? get last => _steps.isEmpty ? null : _steps.last;
  bool get isRunning => _byId.values.any((step) => step.state == StepState.running);

  /// Sentences for screen readers: a tool finished or failed, the run ended.
  Stream<String> get announcements => _announcements.stream;

  TraceStep? get(String id) => _byId[id];

  TraceStep reasoning({String? id}) => _add(TraceStep._(this, kind: TraceStepKind.reasoning, id: id));

  TraceStep tool(String name, {String? id, Object? args}) {
    final step = _add(TraceStep._(this, kind: TraceStepKind.tool, name: name, id: id));
    if (args != null) step.setArgs(args);
    return step;
  }

  TraceStep parallel([String name = defaultGroupName]) => _add(TraceStep._(this, kind: TraceStepKind.parallel, name: name));

  TraceStep message(String text) => _add(TraceStep._(this, kind: TraceStepKind.message, name: text))..done();

  TraceStep finish([String text = 'Done']) {
    final step = _add(TraceStep._(this, kind: TraceStepKind.finish, name: text))..done();
    _announce(text);
    return step;
  }

  TraceStep error(String message) => _add(TraceStep._(this, kind: TraceStepKind.finish, name: message))..fail(message);

  void clear() {
    _steps.clear();
    _byId.clear();
    _changed();
  }

  /// Renders a provider stream of decoded JSON events. `runTool` executes
  /// tools for OpenAI and Anthropic streams; AI SDK streams carry results.
  Future<void> fromEvents(
    Stream<Map<String, dynamic>> events, {
    required TraceFormat format,
    Future<Object?> Function(String name, Object? args)? runTool,
  }) async {
    final map = createMapper(format);
    final pending = <Future<void>>[];
    TraceOp? ending;
    await for (final event in events) {
      for (final op in map(event)) {
        if (op['op'] == 'finish' || op['op'] == 'error') {
          ending = op;
        } else {
          _apply(op, runTool, pending);
        }
      }
    }
    await Future.wait(pending);
    if (ending?['op'] == 'error') {
      error('${ending!['message']}');
    } else if (ending != null) {
      finish();
    }
  }

  void _apply(TraceOp op, Future<Object?> Function(String, Object?)? runTool, List<Future<void>> pending) {
    final id = op['id'] == null ? null : '${op['id']}';
    switch (op['op']) {
      case 'reasoning.start':
        reasoning(id: id);
      case 'reasoning.append':
        get(id!)?.append('${op['text'] ?? ''}');
      case 'reasoning.done':
        final step = get(id!);
        if (step?.state == StepState.running) step!.done();
      case 'tool.start':
        final previous = last;
        final decision = groupDecision(kind: previous?.kind, state: previous?.state, nested: previous?.parent != null);
        final name = '${op['name']}';
        switch (decision) {
          case GroupDecision.join:
            previous!.tool(name, id: id);
          case GroupDecision.wrap:
            _wrap(previous!).tool(name, id: id);
          case GroupDecision.create:
            tool(name, id: id);
        }
      case 'tool.args':
        final step = get(id!);
        if (step == null) return;
        step.setArgs(op['args']);
        if (runTool != null) pending.add(_run(step, runTool));
      case 'tool.done':
        get(id!)?.done(result: op['result']);
      case 'tool.fail':
        get(id!)?.fail('${op['message']}');
    }
  }

  Future<void> _run(TraceStep step, Future<Object?> Function(String, Object?) runTool) async {
    // Look the step up again when the tool returns: it may have moved into a parallel group.
    TraceStep current() => get(step.id) ?? step;
    try {
      final result = await runTool(step.name, step.args);
      current().done(result: result);
    } catch (e) {
      current().fail('$e');
    }
  }

  /// Replaces a lone running tool with a parallel group that contains it.
  TraceStep _wrap(TraceStep toolStep) {
    final group = TraceStep._(this, kind: TraceStepKind.parallel, name: defaultGroupName);
    group._startedAt = toolStep.startedAt;
    _steps[_steps.indexOf(toolStep)] = group;
    _byId.remove(toolStep.id);
    _register(group);
    final lane = group.tool(toolStep.name, id: toolStep.id, args: toolStep.args);
    lane._startedAt = toolStep.startedAt;
    return group;
  }

  TraceStep _add(TraceStep step) {
    _register(step);
    _steps.add(step);
    _changed();
    return step;
  }

  void _register(TraceStep step) => _byId[step.id] = step;

  void _announce(String text) {
    if (!_announcements.isClosed) _announcements.add(text);
  }

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _announcements.close();
    super.dispose();
  }
}

/// Colours and text styles for [Trace]. Anything left null follows the app theme.
@immutable
class TraceThemeData {
  const TraceThemeData({this.accent, this.done, this.fail, this.textStyle, this.monoStyle});

  final Color? accent;
  final Color? done;
  final Color? fail;
  final TextStyle? textStyle;
  final TextStyle? monoStyle;
}

@immutable
class _Palette {
  const _Palette({
    required this.accent,
    required this.done,
    required this.fail,
    required this.text,
    required this.muted,
    required this.line,
    required this.surface,
    required this.style,
    required this.mono,
  });

  final Color accent;
  final Color done;
  final Color fail;
  final Color text;
  final Color muted;
  final Color line;
  final Color surface;
  final TextStyle style;
  final TextStyle mono;
}

/// An agent run timeline driven by a [TraceController].
///
/// ```dart
/// SizedBox(height: 360, child: Trace(controller: trace, onRetry: (step) => rerun(step)))
/// ```
class Trace extends StatefulWidget {
  const Trace({
    super.key,
    required this.controller,
    this.onRetry,
    this.padding = const EdgeInsets.all(16),
    this.theme = const TraceThemeData(),
  });

  final TraceController controller;

  /// Called with a failed step when its Retry button is pressed. Call `step.retry()`, then run it again.
  final void Function(TraceStep step)? onRetry;

  final EdgeInsetsGeometry padding;
  final TraceThemeData theme;

  @override
  State<Trace> createState() => _TraceState();
}

class _TraceState extends State<Trace> with TickerProviderStateMixin {
  final _scroll = ScrollController();
  late final _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200));
  late final _clock = createTicker(_tick);
  Duration _lastTick = Duration.zero;
  StreamSubscription<String>? _announcements;
  bool _stick = true;
  bool _reduced = false;

  @override
  void initState() {
    super.initState();
    _attach(widget.controller);
  }

  @override
  void didUpdateWidget(Trace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller.removeListener(_changed);
      _announcements?.cancel();
      _attach(widget.controller);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    _sync();
  }

  void _attach(TraceController controller) {
    controller.addListener(_changed);
    _announcements = controller.announcements.listen(_announce);
  }

  void _announce(String message) {
    if (!mounted) return;
    SemanticsService.sendAnnouncement(View.of(context), message, Directionality.of(context));
  }

  void _changed() {
    if (!mounted) return;
    setState(() {});
    _sync();
    if (_stick) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _stick && _scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
      });
    }
  }

  /// The clock and pulse run only while something is running.
  void _sync() {
    final running = widget.controller.isRunning;
    if (running && !_clock.isActive) {
      _lastTick = Duration.zero;
      _clock.start();
    } else if (!running && _clock.isActive) {
      _clock.stop();
    }
    if (running && !_reduced) {
      if (!_pulse.isAnimating) _pulse.repeat();
    } else {
      _pulse.stop();
    }
  }

  void _tick(Duration elapsed) {
    if (elapsed - _lastTick >= const Duration(milliseconds: 100)) {
      _lastTick = elapsed;
      setState(() {});
    }
  }

  bool _onScroll(ScrollNotification notification) {
    final stick = notification.metrics.extentAfter < 24;
    if (stick != _stick) setState(() => _stick = stick);
    return false;
  }

  void _jump() {
    if (!_scroll.hasClients) return;
    final end = _scroll.position.maxScrollExtent;
    if (_reduced) {
      _scroll.jumpTo(end);
    } else {
      _scroll.animateTo(end, duration: const Duration(milliseconds: 400), curve: Curves.easeOutCubic);
    }
    setState(() => _stick = true);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_changed);
    _announcements?.cancel();
    _clock.dispose();
    _pulse.dispose();
    _scroll.dispose();
    super.dispose();
  }

  _Palette _palette(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final base = widget.theme.textStyle ?? DefaultTextStyle.of(context).style.copyWith(fontSize: 14, height: 1.5);
    final text = base.color ?? scheme.onSurface;
    return _Palette(
      accent: widget.theme.accent ?? scheme.primary,
      done: widget.theme.done ?? const Color(0xFF2FD3A7),
      fail: widget.theme.fail ?? scheme.error,
      text: text,
      muted: text.withValues(alpha: 0.58),
      line: text.withValues(alpha: 0.16),
      surface: text.withValues(alpha: 0.05),
      style: base.copyWith(color: text),
      mono: widget.theme.monoStyle ?? base.copyWith(color: text, fontFamily: 'monospace', fontSize: 12.5),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = _palette(context);
    final steps = widget.controller.steps;
    return Stack(
      children: [
        NotificationListener<ScrollNotification>(
          onNotification: _onScroll,
          child: ListView.builder(
            controller: _scroll,
            padding: widget.padding,
            itemCount: steps.length,
            itemBuilder: (context, i) => _StepRow(
              key: ValueKey(steps[i].id),
              step: steps[i],
              isLast: i == steps.length - 1,
              palette: palette,
              pulse: _pulse,
              reduced: _reduced,
              onRetry: widget.onRetry,
              onToggle: () => setState(() => steps[i].open = !steps[i].open),
            ),
          ),
        ),
        if (!_stick)
          Positioned(
            left: 0,
            right: 0,
            bottom: 8,
            child: Center(
              child: Semantics(
                button: true,
                child: GestureDetector(
                  onTap: _jump,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                    decoration: BoxDecoration(color: palette.accent, borderRadius: BorderRadius.circular(99)),
                    child: Text('Jump to latest', style: palette.style.copyWith(color: const Color(0xFFFFFFFF), fontSize: 12)),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _StepRow extends StatefulWidget {
  const _StepRow({
    super.key,
    required this.step,
    required this.isLast,
    required this.palette,
    required this.pulse,
    required this.reduced,
    required this.onRetry,
    required this.onToggle,
  });

  final TraceStep step;
  final bool isLast;
  final _Palette palette;
  final Animation<double> pulse;
  final bool reduced;
  final void Function(TraceStep step)? onRetry;
  final VoidCallback onToggle;

  @override
  State<_StepRow> createState() => _StepRowState();
}

class _StepRowState extends State<_StepRow> with SingleTickerProviderStateMixin {
  late final _enter = AnimationController(vsync: this, duration: const Duration(milliseconds: 350));

  @override
  void initState() {
    super.initState();
    if (widget.reduced) {
      _enter.value = 1;
    } else {
      _enter.forward();
    }
  }

  @override
  void dispose() {
    _enter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final step = widget.step;
    final p = widget.palette;
    final running = step.state == StepState.running;
    final sections = <(String, String)>[
      if (step.kind == TraceStepKind.reasoning && step.text.isNotEmpty) ('', step.text),
      if (step.args != null) ('INPUT', summarizeJson(step.args)),
      if (step.result != null) ('OUTPUT', summarizeJson(step.result)),
    ];
    final showError = step.error != null && step.kind != TraceStepKind.parallel && step.kind != TraceStepKind.finish;
    final expanded = (step.open && sections.isNotEmpty) || showError;
    final canToggle = sections.isNotEmpty;

    final titleColor = switch ((step.kind, step.state)) {
      (TraceStepKind.finish, StepState.done) => p.done,
      (TraceStepKind.finish, StepState.failed) => p.fail,
      _ => p.text,
    };
    Widget title = Text(step.title, style: (step.kind == TraceStepKind.tool ? p.mono : p.style).copyWith(color: titleColor));
    if (step.kind == TraceStepKind.reasoning && running && !widget.reduced) {
      title = AnimatedBuilder(
        animation: widget.pulse,
        builder: (context, child) => ShaderMask(
          blendMode: BlendMode.srcIn,
          shaderCallback: (rect) {
            final t = widget.pulse.value * 2.5 - 1.2;
            return LinearGradient(
              colors: [p.muted, p.text, p.muted],
              stops: [(t - 0.3).clamp(0.0, 1.0), t.clamp(0.0, 1.0), (t + 0.3).clamp(0.0, 1.0)],
            ).createShader(rect);
          },
          child: child,
        ),
        child: title,
      );
    }

    final showTime = step.kind != TraceStepKind.message && step.kind != TraceStepKind.finish;
    final header = Semantics(
      button: canToggle,
      expanded: canToggle ? expanded : null,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: canToggle ? widget.onToggle : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(child: title),
              if (showTime)
                Text(
                  formatDuration(step.elapsed),
                  style: p.style.copyWith(color: p.muted, fontSize: 12, fontFeatures: const [FontFeature.tabularFigures()]),
                ),
            ],
          ),
        ),
      ),
    );

    final body = <Widget>[
      for (final (label, content) in sections)
        if (label.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(content, style: p.style.copyWith(color: p.muted, fontSize: 13)),
          )
        else
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: p.style.copyWith(color: p.muted, fontSize: 11, letterSpacing: 0.6)),
                const SizedBox(height: 4),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  decoration: BoxDecoration(
                    color: p.surface,
                    border: Border.all(color: p.line),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(content, style: p.mono),
                ),
              ],
            ),
          ),
      if (showError)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 8,
            children: [
              Text(step.error!, style: p.style.copyWith(color: p.fail, fontSize: 13)),
              _RetryButton(color: p.fail, style: p.style, onTap: () => widget.onRetry?.call(step)),
            ],
          ),
        ),
    ];

    // The connector is a layer behind the row, so the row never needs intrinsic sizing
    // (the lanes use a LayoutBuilder, which can't report intrinsic dimensions).
    final row = Stack(
      children: [
        if (!widget.isLast)
          Positioned(
            left: 9.5,
            top: 19,
            bottom: 0,
            width: 1,
            child: _Connector(drawn: !running, palette: p, reduced: widget.reduced),
          ),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 20,
              child: Padding(
                padding: const EdgeInsets.only(top: 6, left: 4),
                child: Align(
                  alignment: Alignment.topLeft,
                  child: _Dot(state: step.state, palette: p, pulse: widget.pulse, reduced: widget.reduced),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    header,
                    if (expanded) ...body,
                    if (step.kind == TraceStepKind.parallel)
                      _Lanes(step: step, palette: p, pulse: widget.pulse, reduced: widget.reduced, onRetry: widget.onRetry),
                  ],
                ),
              ),
            ),
          ],
        ),
      ],
    );

    return FadeTransition(
      opacity: _enter,
      child: SlideTransition(
        position: Tween(begin: const Offset(0, 0.15), end: Offset.zero).animate(CurvedAnimation(parent: _enter, curve: Curves.easeOut)),
        child: row,
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot({required this.state, required this.palette, required this.pulse, required this.reduced});

  final StepState state;
  final _Palette palette;
  final Animation<double> pulse;
  final bool reduced;

  @override
  Widget build(BuildContext context) {
    final (border, fill) = switch (state) {
      StepState.running => (palette.accent, palette.surface),
      StepState.done => (palette.done, palette.done),
      StepState.failed => (palette.fail, palette.fail),
      StepState.cancelled => (palette.muted, palette.surface),
    };
    Widget dot(double halo) => Container(
      width: 11,
      height: 11,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: fill,
        border: Border.all(color: border, width: 2),
        boxShadow: halo > 0 ? [BoxShadow(color: palette.accent.withValues(alpha: 0.18), spreadRadius: halo)] : null,
      ),
    );
    if (state != StepState.running || reduced) return dot(0);
    return AnimatedBuilder(
      animation: pulse,
      builder: (context, _) => dot(6 * (0.5 - (pulse.value - 0.5).abs()) * 2),
    );
  }
}

class _Connector extends StatelessWidget {
  const _Connector({required this.drawn, required this.palette, required this.reduced});

  final bool drawn;
  final _Palette palette;
  final bool reduced;

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      tween: Tween(end: drawn ? 1 : 0),
      duration: reduced ? Duration.zero : const Duration(milliseconds: 500),
      curve: Curves.easeOut,
      builder: (context, t, _) => Align(
        alignment: Alignment.topCenter,
        child: FractionallySizedBox(
          heightFactor: t,
          child: Container(
            width: 1,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [palette.accent, palette.line],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Lanes extends StatelessWidget {
  const _Lanes({required this.step, required this.palette, required this.pulse, required this.reduced, required this.onRetry});

  final TraceStep step;
  final _Palette palette;
  final Animation<double> pulse;
  final bool reduced;
  final void Function(TraceStep step)? onRetry;

  @override
  Widget build(BuildContext context) {
    final p = palette;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: LayoutBuilder(
        builder: (context, constraints) {
          const gap = 8.0;
          const minWidth = 140.0;
          final count = step.children.isEmpty ? 1 : step.children.length;
          final perRow = ((constraints.maxWidth + gap) / (minWidth + gap)).floor().clamp(1, count);
          final width = (constraints.maxWidth - gap * (perRow - 1)) / perRow;
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            children: [
              for (final lane in step.children)
                SizedBox(
                  width: width,
                  child: Container(
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      color: p.surface,
                      border: Border.all(color: lane.state == StepState.failed ? p.fail : p.line),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Column(
                      children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
                          child: Row(
                            children: [
                              Expanded(child: Text(lane.name, style: p.mono, overflow: TextOverflow.ellipsis)),
                              const SizedBox(width: 8),
                              if (lane.state == StepState.failed)
                                _RetryButton(color: p.text, style: p.style, onTap: () => onRetry?.call(lane))
                              else
                                Text(formatDuration(lane.elapsed), style: p.mono.copyWith(color: p.muted, fontSize: 11.5)),
                            ],
                          ),
                        ),
                        _Bar(lane: lane, palette: p, pulse: pulse, reduced: reduced),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _Bar extends StatelessWidget {
  const _Bar({required this.lane, required this.palette, required this.pulse, required this.reduced});

  final TraceStep lane;
  final _Palette palette;
  final Animation<double> pulse;
  final bool reduced;

  @override
  Widget build(BuildContext context) {
    final color = switch (lane.state) {
      StepState.done => palette.done,
      StepState.failed => palette.fail,
      _ => palette.accent,
    };
    Widget bar(double start, double width) => SizedBox(
      height: 2,
      child: Align(
        alignment: Alignment(start * 2 - 1, 0),
        child: FractionallySizedBox(widthFactor: width, child: ColoredBox(color: color)),
      ),
    );
    if (lane.state != StepState.running) return bar(0, 1);
    if (lane.fraction != null) return bar(0, lane.fraction!);
    if (reduced) return bar(0, 0.35);
    return AnimatedBuilder(animation: pulse, builder: (context, _) => bar(pulse.value, 0.35));
  }
}

class _RetryButton extends StatelessWidget {
  const _RetryButton({required this.color, required this.style, required this.onTap});

  final Color color;
  final TextStyle style;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
          decoration: BoxDecoration(border: Border.all(color: color), borderRadius: BorderRadius.circular(6)),
          child: Text('Retry', style: style.copyWith(color: color, fontSize: 12)),
        ),
      ),
    );
  }
}
