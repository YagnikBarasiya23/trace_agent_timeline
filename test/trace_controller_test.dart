import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:trace_agent_timeline/trace_agent_timeline.dart';

Stream<Map<String, dynamic>> fixture(String name) =>
    Stream.fromIterable((jsonDecode(File('test/fixtures/$name.json').readAsStringSync()) as List).cast<Map<String, dynamic>>());

void main() {
  test('reasoning streams, then titles itself with its duration and collapses', () {
    final trace = TraceController();
    final think = trace.reasoning()
      ..append('Check ')
      ..append('last month.');
    expect(think.title, 'Thinking');
    expect(think.open, isTrue);
    think.done();
    expect(think.text, 'Check last month.');
    expect(think.title, startsWith('Reasoned for '));
    expect(think.open, isFalse);
  });

  test('tools record args, results and errors, and follow the transition rules', () {
    final trace = TraceController();
    final call = trace.tool('search', args: {'q': 'brunch'});
    expect(call.args, {'q': 'brunch'});
    call.done(result: 42);
    expect(call.state, StepState.done);
    expect(call.result, 42);
    expect(() => call.fail('late'), throwsStateError);

    final bad = trace.tool('image')..fail('Timed out');
    expect(bad.error, 'Timed out');
    bad.retry();
    expect(bad.state, StepState.running);
    expect(bad.error, isNull);
  });

  test('a parallel group settles when its lanes finish', () {
    final trace = TraceController();
    final group = trace.parallel();
    final a = group.tool('a');
    final b = group.tool('b');
    final c = group.tool('c');
    expect(group.children, [a, b, c]);
    expect(group.state, StepState.running);
    a.done();
    b.fail('boom');
    expect(group.state, StepState.running);
    c.done();
    expect(group.state, StepState.failed);
    expect(group.title, 'Ran 3 in parallel · 1 of 3 failed');
    b.retry();
    expect(group.state, StepState.running);
    b.done();
    expect(group.state, StepState.done);
    expect(group.title, 'Ran 3 in parallel');
  });

  test('finish and error end the run and are announced', () async {
    final trace = TraceController();
    final heard = <String>[];
    trace.announcements.listen(heard.add);
    trace.tool('search').done();
    trace.finish('Post scheduled');
    await Future<void>.delayed(Duration.zero);
    expect(trace.last!.kind, TraceStepKind.finish);
    expect(trace.last!.state, StepState.done);
    expect(heard, contains('Post scheduled'));
    expect(heard.first, startsWith('search finished in '));
    expect(trace.isRunning, isFalse);
  });

  test('fromEvents groups tools that start together and waits for runTool', () async {
    final trace = TraceController();
    await trace.fromEvents(
      fixture('openai'),
      format: TraceFormat.openai,
      // Real tools take time; an instant one would finish before the next tool starts.
      runTool: (name, args) async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return name == 'best_time' ? 'Sat 11:00' : {'reach': 7200};
      },
    );
    final kinds = trace.steps.map((s) => s.kind).toList();
    expect(kinds, [TraceStepKind.reasoning, TraceStepKind.parallel, TraceStepKind.finish]);
    final group = trace.steps[1];
    expect(group.children.map((c) => c.name), ['analytics_summary', 'best_time']);
    expect(group.children.every((c) => c.state == StepState.done), isTrue);
    expect(trace.get('fc_1')!.result, {'reach': 7200});
    expect(trace.last!.name, 'Done');
  });

  test('fromEvents applies AI SDK tool results and errors from the stream', () async {
    final trace = TraceController();
    await trace.fromEvents(fixture('ai-sdk'), format: TraceFormat.aiSdk);
    final group = trace.steps[1];
    expect(group.kind, TraceStepKind.parallel);
    expect(trace.get('t1')!.state, StepState.done);
    expect(trace.get('t2')!.error, 'Timed out');
    expect(group.state, StepState.failed);
  });

  test('fromEvents ends with an error step when the stream reports one', () async {
    final trace = TraceController();
    await trace.fromEvents(
      Stream.fromIterable([
        {'type': 'error', 'message': 'Rate limited'},
      ]),
      format: TraceFormat.openai,
    );
    expect(trace.last!.state, StepState.failed);
    expect(trace.last!.name, 'Rate limited');
  });

  test('clear empties the timeline and notifies listeners', () {
    final trace = TraceController();
    var notified = 0;
    trace.addListener(() => notified++);
    trace.tool('a');
    trace.clear();
    expect(trace.steps, isEmpty);
    expect(trace.get('a'), isNull);
    expect(notified, greaterThanOrEqualTo(2));
  });
}
