import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:portlink/core/server_profile.dart';
import 'package:portlink/core/tunnel_status.dart';
import 'package:portlink/ui/connection_panel.dart';
import 'package:portlink/ui/portlink_theme.dart';

const profile = ServerProfile(
  id: 'one',
  name: '工作服务器',
  host: 'server.example',
  username: 'alice',
);

Widget panel({
  TunnelPhase phase = TunnelPhase.idle,
  bool busy = false,
  VoidCallback? onDisconnect,
  VoidCallback? onOpenHttp,
}) => MaterialApp(
  theme: buildPortLinkTheme(Brightness.light),
  home: Scaffold(
    body: SingleChildScrollView(
      child: ConnectionPanel(
        status: TunnelStatus(phase: phase, profileId: 'one'),
        profile: profile,
        busy: busy,
        initialized: true,
        canConnect: true,
        onConnect: () {},
        onDisconnect: onDisconnect ?? () {},
        onCopy: () {},
        onOpenHttp: onOpenHttp ?? () {},
        copied: false,
      ),
    ),
  ),
);

void main() {
  testWidgets('busy connecting remains cancellable', (tester) async {
    var stopped = 0;
    await tester.pumpWidget(
      panel(
        phase: TunnelPhase.connecting,
        busy: true,
        onDisconnect: () => stopped++,
      ),
    );
    await tester.tap(find.text('取消连接'));
    expect(stopped, 1);
    expect(find.text('127.0.0.1:3080'), findsOneWidget);
  });

  testWidgets('HTTP action is explicit and unavailable before ready', (
    tester,
  ) async {
    var opened = 0;
    await tester.pumpWidget(panel(onOpenHttp: () => opened++));
    final idle = tester.widget<TextButton>(
      find.ancestor(
        of: find.text('打开 HTTP 页面'),
        matching: find.byWidgetPredicate((widget) => widget is TextButton),
      ),
    );
    expect(idle.onPressed, isNull);
    expect(opened, 0);

    await tester.pumpWidget(
      panel(phase: TunnelPhase.ready, onOpenHttp: () => opened++),
    );
    expect(opened, 0);
    await tester.tap(find.text('打开 HTTP 页面'));
    expect(opened, 1);
    expect(find.textContaining('其他 TCP 服务'), findsOneWidget);
  });

  testWidgets('target unavailable keeps stop but not HTTP action', (
    tester,
  ) async {
    await tester.pumpWidget(panel(phase: TunnelPhase.targetUnavailable));
    expect(find.text('通道已连接，服务暂不可用'), findsOneWidget);
    expect(
      tester
          .widget<OutlinedButton>(
            find.ancestor(
              of: find.text('停止连接'),
              matching: find.byWidgetPredicate(
                (widget) => widget is OutlinedButton,
              ),
            ),
          )
          .onPressed,
      isNotNull,
    );
    expect(
      tester
          .widget<TextButton>(
            find.ancestor(
              of: find.text('打开 HTTP 页面'),
              matching: find.byWidgetPredicate(
                (widget) => widget is TextButton,
              ),
            ),
          )
          .onPressed,
      isNull,
    );
  });

  for (final width in [320.0, 390.0, 760.0]) {
    testWidgets('connection panel fits width $width', (tester) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(panel());
      expect(tester.takeException(), isNull);
    });
  }
}
