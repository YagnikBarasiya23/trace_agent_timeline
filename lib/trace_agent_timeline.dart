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
