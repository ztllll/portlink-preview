import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:portlink/core/forward_rule.dart';
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

const web = ForwardRule(
  id: 'web',
  label: '网页',
  localPort: 8080,
  remotePort: 80,
);
const db = ForwardRule(
  id: 'db',
  label: '数据库',
  localPort: 15432,
  remotePort: 5432,
  targetHost: '10.0.0.5',
);

Widget panel({
  TunnelPhase phase = TunnelPhase.idle,
  ServerProfile server = profile,
  List<RuleStatus> rules = const [],
  bool busy = false,
  VoidCallback? onDisconnect,
  ValueChanged<ForwardRule>? onOpenHttp,
  ValueChanged<ForwardRule>? onCopy,
  String? copiedRuleId,
}) => MaterialApp(
  theme: buildPortLinkTheme(Brightness.light),
  home: Scaffold(
    body: SingleChildScrollView(
      child: ConnectionPanel(
        status: TunnelStatus(phase: phase, profileId: 'one', rules: rules),
        profile: server,
        busy: busy,
        initialized: true,
        canConnect: true,
        onConnect: () {},
        onDisconnect: onDisconnect ?? () {},
        onCopy: onCopy ?? (_) {},
        onOpenHttp: onOpenHttp ?? (_) {},
        copiedRuleId: copiedRuleId,
      ),
    ),
  ),
);

ServerProfile twoRules() => profile.copyWith(rules: [web, db]);

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
    // The legacy profile still shows its single 3080 rule.
    expect(find.text('127.0.0.1:3080'), findsOneWidget);
  });

  testWidgets(
    'every enabled rule is listed with its own local and remote address',
    (tester) async {
      await tester.pumpWidget(panel(server: twoRules()));
      expect(find.text('127.0.0.1:8080'), findsOneWidget);
      expect(find.text('→ 127.0.0.1:80'), findsOneWidget);
      expect(find.text('127.0.0.1:15432'), findsOneWidget);
      expect(find.text('→ 10.0.0.5:5432'), findsOneWidget);
      // Two rule tiles, plus the panel's own status pill.
      expect(find.text('未连接'), findsNWidgets(3));
      expect(find.byKey(const ValueKey('rule-tile-web')), findsOneWidget);
      expect(find.byKey(const ValueKey('rule-tile-db')), findsOneWidget);
    },
  );

  testWidgets('disabled rules are not listed', (tester) async {
    final server = profile.copyWith(rules: [web, db.copyWith(enabled: false)]);
    await tester.pumpWidget(panel(server: server));
    expect(find.text('127.0.0.1:8080'), findsOneWidget);
    expect(find.text('127.0.0.1:15432'), findsNothing);
  });

  testWidgets('copy and open act on the chosen rule only', (tester) async {
    final copied = <String>[];
    final opened = <String>[];
    await tester.pumpWidget(
      panel(
        phase: TunnelPhase.ready,
        server: twoRules(),
        rules: const [
          RuleStatus(rule: web, state: RuleState.ready),
          RuleStatus(rule: db, state: RuleState.ready),
        ],
        onCopy: (r) => copied.add(r.id),
        onOpenHttp: (r) => opened.add(r.id),
      ),
    );
    await tester.tap(find.byTooltip('复制 127.0.0.1:15432'));
    expect(copied, ['db']);
    await tester.tap(
      find.byTooltip('用浏览器打开 http://127.0.0.1:8080（仅限 HTTP 服务）'),
    );
    expect(opened, ['web']);
    expect(find.textContaining('其他 TCP 服务'), findsOneWidget);
  });

  testWidgets('HTTP action is unavailable until that rule is ready', (
    tester,
  ) async {
    await tester.pumpWidget(
      panel(
        phase: TunnelPhase.ready,
        server: twoRules(),
        rules: const [
          RuleStatus(rule: web, state: RuleState.ready),
          RuleStatus(
            rule: db,
            state: RuleState.targetUnavailable,
            message: '远端 10.0.0.5:5432 暂不可用',
          ),
        ],
      ),
    );
    IconButton open(String address) => tester.widget<IconButton>(
      find.ancestor(
        of: find.byTooltip('用浏览器打开 http://$address（仅限 HTTP 服务）'),
        matching: find.byType(IconButton),
      ),
    );
    expect(open('127.0.0.1:8080').onPressed, isNotNull);
    expect(open('127.0.0.1:15432').onPressed, isNull);
    expect(find.text('远端暂不可用'), findsOneWidget);
  });

  testWidgets('a bind failure is shown on its rule while others stay usable', (
    tester,
  ) async {
    await tester.pumpWidget(
      panel(
        phase: TunnelPhase.ready,
        server: twoRules(),
        rules: const [
          RuleStatus(rule: web, state: RuleState.ready),
          RuleStatus(
            rule: db,
            state: RuleState.bindFailed,
            message: '本机 127.0.0.1:15432 已被占用或无法监听',
          ),
        ],
      ),
    );
    expect(find.text('可用'), findsOneWidget);
    expect(find.text('本地端口无法监听'), findsOneWidget);
    expect(find.textContaining('已被占用'), findsOneWidget);
  });

  testWidgets('a rule listening beyond loopback carries an exposure warning', (
    tester,
  ) async {
    final server = profile.copyWith(rules: [web.copyWith(bindHost: '0.0.0.0')]);
    await tester.pumpWidget(panel(server: server));
    expect(find.text('0.0.0.0:8080'), findsOneWidget);
    expect(find.text('同网络的其他设备也可访问'), findsOneWidget);
  });

  testWidgets('loopback rules show no exposure warning', (tester) async {
    await tester.pumpWidget(panel(server: twoRules()));
    expect(find.text('同网络的其他设备也可访问'), findsNothing);
  });

  testWidgets('target unavailable keeps stop', (tester) async {
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
  });

  for (final width in [320.0, 390.0, 760.0]) {
    testWidgets('connection panel fits width $width', (tester) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(panel(server: twoRules()));
      expect(tester.takeException(), isNull);
    });
  }
}
