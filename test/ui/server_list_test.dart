import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:portlink/core/server_profile.dart';
import 'package:portlink/core/tunnel_status.dart';
import 'package:portlink/ui/portlink_theme.dart';
import 'package:portlink/ui/server_list.dart';

const profiles = [
  ServerProfile(
    id: 'one',
    name: '工作服务器',
    host: 'first.example',
    username: 'alice',
  ),
  ServerProfile(
    id: 'two',
    name: '备用服务器',
    host: 'second.example',
    username: 'bob',
  ),
];

Widget servers({
  bool busy = false,
  TunnelStatus status = const TunnelStatus(phase: TunnelPhase.idle),
  VoidCallback? onDisconnect,
  void Function(ServerProfile, ServerAction)? onAction,
}) => MaterialApp(
  theme: buildPortLinkTheme(Brightness.light),
  home: Scaffold(
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: ServerList(
        profiles: profiles,
        defaultProfileId: 'one',
        status: status,
        busy: busy,
        initialized: true,
        onAdd: () {},
        onConnect: (_) {},
        onDisconnect: onDisconnect ?? () {},
        onAction: onAction ?? (_, _) {},
      ),
    ),
  ),
);

void main() {
  testWidgets('default action identifies profile without connecting', (
    tester,
  ) async {
    ServerProfile? chosen;
    ServerAction? selected;
    await tester.pumpWidget(
      servers(
        onAction: (profile, action) {
          chosen = profile;
          selected = action;
        },
      ),
    );
    expect(find.text('默认'), findsOneWidget);
    await tester.tap(find.byTooltip('备用服务器的更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('设为默认'));
    await tester.pumpAndSettle();
    expect(chosen?.id, 'two');
    expect(selected, ServerAction.makeDefault);
  });

  testWidgets('busy disables mutations but keeps active cancellation', (
    tester,
  ) async {
    var stopped = false;
    await tester.pumpWidget(
      servers(
        busy: true,
        status: const TunnelStatus(
          phase: TunnelPhase.connecting,
          profileId: 'one',
        ),
        onDisconnect: () => stopped = true,
      ),
    );
    expect(
      tester
          .widget<FilledButton>(
            find.ancestor(
              of: find.text('添加服务器'),
              matching: find.byWidgetPredicate(
                (widget) => widget is FilledButton,
              ),
            ),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<PopupMenuButton<ServerAction>>(
            find.ancestor(
              of: find.byTooltip('工作服务器的更多操作'),
              matching: find.byWidgetPredicate(
                (widget) => widget is PopupMenuButton<ServerAction>,
              ),
            ),
          )
          .enabled,
      isFalse,
    );
    expect(
      tester
          .widget<OutlinedButton>(
            find.ancestor(
              of: find.text('连接'),
              matching: find.byWidgetPredicate(
                (widget) => widget is OutlinedButton,
              ),
            ),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('取消'));
    expect(stopped, isTrue);
  });

  testWidgets('server cards fit narrow mobile width', (tester) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(servers());
    expect(tester.takeException(), isNull);
  });
}
