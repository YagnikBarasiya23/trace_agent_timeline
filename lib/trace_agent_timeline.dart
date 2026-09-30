/// Trace — an agent run timeline. MIT © 2026 Yagnik Barasiya.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
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
    String s => cut(s),
    Map<dynamic, dynamic> m => m.map((key, x) => MapEntry('$key', trim(x))),
    List<dynamic> l => l.map(trim).toList(),
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
  Map<dynamic, dynamic> m => '${m['message'] ?? 'Run failed'}',
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
