import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:trace_agent_timeline/trace_agent_timeline.dart';

class _Opaque {}

void main() {
  test('running steps can finish, fail or be cancelled', () {
    expect(transition(StepState.running, StepEvent.done), StepState.done);
    expect(transition(StepState.running, StepEvent.fail), StepState.failed);
    expect(transition(StepState.running, StepEvent.cancel), StepState.cancelled);
  });

  test('only failed steps can be retried and finished steps stay finished', () {
    expect(transition(StepState.failed, StepEvent.retry), StepState.running);
    expect(
      () => transition(StepState.done, StepEvent.fail),
      throwsA(isA<StateError>().having((e) => e.message, 'message', 'Trace: cannot fail a done step')),
    );
    expect(() => transition(StepState.running, StepEvent.retry), throwsStateError);
    expect(() => transition(StepState.cancelled, StepEvent.done), throwsStateError);
  });

  test('durations read naturally at every scale', () {
    Duration ms(int v) => Duration(milliseconds: v);
    expect(formatDuration(Duration.zero), '0.0s');
    expect(formatDuration(ms(1340)), '1.3s');
    expect(formatDuration(ms(9949)), '9.9s');
    expect(formatDuration(ms(12400)), '12s');
    expect(formatDuration(ms(59600)), '1m 00s');
    expect(formatDuration(ms(65000)), '1m 05s');
    expect(formatDuration(ms(119600)), '2m 00s');
    expect(formatDuration(ms(-5)), '0.0s');
  });

  test('summarizeJson pretty-prints and truncates long strings', () {
    expect(summarizeJson(null), '');
    expect(summarizeJson({'days': 30}), '{\n  "days": 30\n}');
    expect(summarizeJson('x' * 10, maxLen: 5), 'xxxx…');
    expect(summarizeJson({'note': 'abcdefghij'}, maxLen: 5), '{\n  "note": "abcd…"\n}');
    expect(summarizeJson([1, 'two']), '[\n  1,\n  "two"\n]');
    expect(summarizeJson(_Opaque()), startsWith("Instance of '_Opaque'"));
  });

  test('a tool that starts while another is running groups them', () {
    expect(groupDecision(), GroupDecision.create);
    expect(groupDecision(kind: TraceStepKind.tool, state: StepState.running), GroupDecision.wrap);
    expect(groupDecision(kind: TraceStepKind.tool, state: StepState.done), GroupDecision.create);
    expect(groupDecision(kind: TraceStepKind.parallel, state: StepState.running), GroupDecision.join);
    expect(groupDecision(kind: TraceStepKind.parallel, state: StepState.done), GroupDecision.create);
    expect(groupDecision(kind: TraceStepKind.reasoning, state: StepState.running), GroupDecision.create);
    expect(groupDecision(kind: TraceStepKind.tool, state: StepState.running, nested: true), GroupDecision.create);
  });

  List<TraceOp> run(TraceFormat format, String file) {
    final map = createMapper(format);
    final events = (jsonDecode(File('test/fixtures/$file.json').readAsStringSync()) as List).cast<Map<String, dynamic>>();
    return [for (final e in events) ...map(e)];
  }

  test('OpenAI Responses stream maps to reasoning, tools and finish', () {
    expect(run(TraceFormat.openai, 'openai'), [
      {'op': 'reasoning.start', 'id': 'rs_1'},
      {'op': 'reasoning.append', 'id': 'rs_1', 'text': 'The owner wants '},
      {'op': 'reasoning.append', 'id': 'rs_1', 'text': 'a weekend offer.'},
      {'op': 'reasoning.done', 'id': 'rs_1'},
      {'op': 'tool.start', 'id': 'fc_1', 'name': 'analytics_summary'},
      {'op': 'tool.args', 'id': 'fc_1', 'args': {'days': 30}},
      {'op': 'tool.start', 'id': 'fc_2', 'name': 'best_time'},
      {'op': 'tool.args', 'id': 'fc_2', 'args': 'not json'},
      {'op': 'finish'},
    ]);
  });

  test('Anthropic stream keeps thinking blocks apart and finishes only at end_turn', () {
    expect(run(TraceFormat.anthropic, 'anthropic'), [
      {'op': 'reasoning.start', 'id': 'thinking-1-0'},
      {'op': 'reasoning.append', 'id': 'thinking-1-0', 'text': 'Check last month first.'},
      {'op': 'reasoning.done', 'id': 'thinking-1-0'},
      {'op': 'tool.start', 'id': 'toolu_1', 'name': 'analytics_summary'},
      {'op': 'tool.args', 'id': 'toolu_1', 'args': {'days': 30}},
      {'op': 'reasoning.start', 'id': 'thinking-2-0'},
      {'op': 'reasoning.append', 'id': 'thinking-2-0', 'text': 'Reach is up.'},
      {'op': 'reasoning.done', 'id': 'thinking-2-0'},
      {'op': 'finish'},
    ]);
  });

  test('AI SDK fullStream maps tool calls, results and errors', () {
    expect(run(TraceFormat.aiSdk, 'ai-sdk'), [
      {'op': 'reasoning.start', 'id': 'r1'},
      {'op': 'reasoning.append', 'id': 'r1', 'text': 'Pull the numbers.'},
      {'op': 'reasoning.done', 'id': 'r1'},
      {'op': 'tool.start', 'id': 't1', 'name': 'analytics_summary'},
      {'op': 'tool.args', 'id': 't1', 'args': {'days': 30}},
      {'op': 'tool.start', 'id': 't2', 'name': 'best_time'},
      {'op': 'tool.args', 'id': 't2', 'args': <String, dynamic>{}},
      {'op': 'tool.done', 'id': 't1', 'result': {'reach': 7200}},
      {'op': 'tool.fail', 'id': 't2', 'message': 'Timed out'},
      {'op': 'finish'},
    ]);
  });

  test('AI SDK reasoning without a start event opens a step once', () {
    final map = createMapper(TraceFormat.aiSdk);
    expect(map({'type': 'reasoning-delta', 'id': 'x', 'text': 'a'}), [
      {'op': 'reasoning.start', 'id': 'x'},
      {'op': 'reasoning.append', 'id': 'x', 'text': 'a'},
    ]);
    expect(map({'type': 'reasoning-delta', 'id': 'x', 'text': 'b'}), [
      {'op': 'reasoning.append', 'id': 'x', 'text': 'b'},
    ]);
  });

  test('errors map to an error op', () {
    expect(createMapper(TraceFormat.openai)({'type': 'error', 'message': 'Rate limited'}), [
      {'op': 'error', 'message': 'Rate limited'},
    ]);
    expect(createMapper(TraceFormat.anthropic)({
      'type': 'error',
      'error': {'message': 'Overloaded'},
    }), [
      {'op': 'error', 'message': 'Overloaded'},
    ]);
    expect(createMapper(TraceFormat.aiSdk)({'type': 'error', 'error': 'boom'}), [
      {'op': 'error', 'message': 'boom'},
    ]);
  });
}
