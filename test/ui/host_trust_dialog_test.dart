import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:portlink/core/host_trust.dart';
import 'package:portlink/ui/host_trust_dialog.dart';
import 'package:portlink/ui/portlink_theme.dart';

const request = HostTrustRequest(
  host: 'server.example',
  port: 22,
  keyType: 'ssh-ed25519',
  fingerprint: 'SHA256:abcdefghijklmnopqrstuv1234567890abcdefghijkl',
);

Widget trustDialog(ValueChanged<bool> onAnswer) => MaterialApp(
  theme: buildPortLinkTheme(Brightness.light),
  home: Scaffold(
    body: HostTrustDialog(request: request, onAnswer: onAnswer),
  ),
);

void main() {
  testWidgets('trust requires explicit verification and affirmative click', (
    tester,
  ) async {
    final answers = <bool>[];
    await tester.pumpWidget(trustDialog(answers.add));
    await tester.pump();
    expect(answers, isEmpty);
    expect(find.text('server.example:22'), findsOneWidget);
    expect(find.text('主机密钥类型：ssh-ed25519'), findsOneWidget);
    expect(find.text(request.fingerprint), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.ancestor(
              of: find.text('信任并继续'),
              matching: find.byWidgetPredicate(
                (widget) => widget is FilledButton,
              ),
            ),
          )
          .onPressed,
      isNull,
    );

    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    expect(answers, isEmpty);
    await tester.tap(find.text('信任并继续'));
    await tester.pump();
    expect(answers, [true]);
    expect(
      tester
          .widget<FilledButton>(
            find.ancestor(
              of: find.text('信任并继续'),
              matching: find.byWidgetPredicate(
                (widget) => widget is FilledButton,
              ),
            ),
          )
          .onPressed,
      isNull,
    );
  });

  testWidgets('reject is available without accepting fingerprint', (
    tester,
  ) async {
    final answers = <bool>[];
    await tester.pumpWidget(trustDialog(answers.add));
    await tester.tap(find.text('拒绝连接'));
    await tester.pump();
    expect(answers, [false]);
  });

  testWidgets('long fingerprint fits mobile viewport', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(trustDialog((_) {}));
    expect(tester.takeException(), isNull);
  });
}
