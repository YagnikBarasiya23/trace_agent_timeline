import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trace_agent_timeline/trace_agent_timeline.dart';

Widget app(TraceController trace, {void Function(TraceStep)? onRetry, bool reduceMotion = false}) => MaterialApp(
  home: MediaQuery(
    data: MediaQueryData(disableAnimations: reduceMotion),
    child: Scaffold(
      body: SizedBox(height: 400, child: Trace(controller: trace, onRetry: onRetry)),
    ),
  ),
);

void main() {
  testWidgets('reasoning streams open, then collapses and reopens on tap', (tester) async {
    final trace = TraceController();
    await tester.pumpWidget(app(trace));
    final think = trace.reasoning()..append('Check last month first.');
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Thinking'), findsOneWidget);
    expect(find.text('Check last month first.'), findsOneWidget);

    think.done();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('Reasoned for'), findsOneWidget);
    expect(find.text('Check last month first.'), findsNothing);

    await tester.tap(find.textContaining('Reasoned for'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Check last month first.'), findsOneWidget);
  });

  testWidgets('tool input and output fold open', (tester) async {
    final trace = TraceController();
    await tester.pumpWidget(app(trace));
    trace.tool('analytics.summary', args: {'days': 30}).done(result: {'reach': 7200});
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('"reach": 7200'), findsNothing);
    await tester.tap(find.text('analytics.summary'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('"days": 30'), findsOneWidget);
    expect(find.textContaining('"reach": 7200'), findsOneWidget);
  });

  testWidgets('parallel lanes render, report a failure and retry', (tester) async {
    final trace = TraceController();
    TraceStep? retried;
    await tester.pumpWidget(app(trace, onRetry: (step) => retried = step));
    final group = trace.parallel();
    final a = group.tool('draft_caption');
    final b = group.tool('generate_image');
    final c = group.tool('best_time');
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Running in parallel'), findsOneWidget);
    expect(find.text('generate_image'), findsOneWidget);

    a.done();
    b.fail('Timed out');
    c.done();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Ran 3 in parallel · 1 of 3 failed'), findsOneWidget);

    await tester.tap(find.text('Retry'));
    expect(retried, b);
  });

  testWidgets('a finished run shows its final message', (tester) async {
    final trace = TraceController();
    await tester.pumpWidget(app(trace));
    trace.tool('posts.schedule').done();
    trace.finish('Post scheduled with photo');
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Post scheduled with photo'), findsOneWidget);
  });

  testWidgets('scrolling up stops the follow and offers a jump back', (tester) async {
    final trace = TraceController();
    await tester.pumpWidget(app(trace));
    for (var i = 0; i < 30; i++) {
      trace.tool('step_$i').done();
    }
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Jump to latest'), findsNothing);

    await tester.drag(find.byType(ListView), const Offset(0, 300));
    await tester.pump(const Duration(milliseconds: 400));
    trace.tool('step_new');
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('Jump to latest'), findsOneWidget);

    await tester.tap(find.text('Jump to latest'));
    // The first frame starts the scroll animation; the second lets it finish.
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('step_new'), findsOneWidget);
  });

  testWidgets('reduced motion renders a running timeline without animating', (tester) async {
    final trace = TraceController();
    await tester.pumpWidget(app(trace, reduceMotion: true));
    trace.reasoning().append('Thinking about it');
    trace.parallel().tool('slow');
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('Thinking'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
