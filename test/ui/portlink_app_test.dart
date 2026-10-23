import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:portlink/core/host_trust.dart';
import 'package:portlink/core/server_profile.dart';
import 'package:portlink/core/tunnel_status.dart';
import 'package:portlink/ui/connection_panel.dart';
import 'package:portlink/ui/portlink_app.dart';
import 'package:portlink/ui/server_list.dart';

import 'fake_app_controller.dart';

const primary = ServerProfile(
  id: 'one',
  name: '工作服务器',
  host: 'first.example',
  username: 'alice',
);
const secondary = ServerProfile(
  id: 'two',
  name: '备用服务器',
  host: 'second.example',
  username: 'bob',
);

FakeAppController configuredController() => FakeAppController()
  ..profiles = [primary, secondary]
  ..defaultProfileId = 'one';

Future<void> useDesktop(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1280, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> openMenu(WidgetTester tester, String name) async {
  await tester.tap(find.byTooltip('$name的更多操作'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('platform warning stays visible independently from SSH errors', (
    tester,
  ) async {
    final controller = FakeAppController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(PortLinkApp(controller: controller));
    controller.reportPlatformWarning('托盘不可用，关闭窗口会停止转发');
    controller.errorMessage = 'SSH failure';
    controller.update();
    await tester.pump();
    expect(find.text('托盘不可用，关闭窗口会停止转发'), findsOneWidget);
    controller.clearError();
    await tester.pump();
    expect(find.text('托盘不可用，关闭窗口会停止转发'), findsOneWidget);
    expect(find.text('SSH failure'), findsNothing);
  });

  testWidgets('UI does not initialize or automatically connect', (
    tester,
  ) async {
    final controller = configuredController()..initialized = false;
    await tester.pumpWidget(PortLinkApp(controller: controller));
    await tester.pump();
    expect(controller.initializeCalls, 0);
    expect(controller.connectedIds, isEmpty);
    expect(find.text('正在读取本机配置…'), findsOneWidget);
  });

  testWidgets(
    'failed initialization is persistent and every mutation stays disabled',
    (tester) async {
      await useDesktop(tester);
      final controller = configuredController()
        ..initialized = false
        ..errorMessage = '配置读取失败，请恢复备份后重启。';
      await tester.pumpWidget(PortLinkApp(controller: controller));
      expect(find.text('配置未加载，连接和修改已禁用'), findsOneWidget);
      expect(find.text('配置读取失败，请恢复备份后重启。'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.byTooltip('关闭提示'), findsNothing);
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
            .widget<OutlinedButton>(
              find.ancestor(
                of: find.text('连接').first,
                matching: find.byWidgetPredicate(
                  (widget) => widget is OutlinedButton,
                ),
              ),
            )
            .onPressed,
        isNull,
      );

      // Invoke callbacks directly as a stale accessibility/menu event might do.
      final list = tester.widget<ServerList>(find.byType(ServerList));
      list.onAdd();
      list.onConnect(primary);
      list.onAction(secondary, ServerAction.makeDefault);
      list.onAction(primary, ServerAction.edit);
      list.onAction(primary, ServerAction.delete);
      tester.widget<ConnectionPanel>(find.byType(ConnectionPanel)).onConnect();
      await tester.pump();
      expect(controller.connectedIds, isEmpty);
      expect(controller.deletedIds, isEmpty);
      expect(controller.defaultProfileId, 'one');
      expect(find.text('保存服务器'), findsNothing);
    },
  );

  testWidgets('stale callbacks cannot bypass busy mutation guard', (
    tester,
  ) async {
    await useDesktop(tester);
    final controller = configuredController();
    await tester.pumpWidget(PortLinkApp(controller: controller));
    final stale = tester.widget<ServerList>(find.byType(ServerList));
    controller.busy = true;
    stale.onAdd();
    stale.onConnect(primary);
    stale.onAction(secondary, ServerAction.makeDefault);
    stale.onAction(primary, ServerAction.edit);
    stale.onAction(primary, ServerAction.delete);
    await tester.pump();
    expect(controller.connectedIds, isEmpty);
    expect(controller.deletedIds, isEmpty);
    expect(controller.defaultProfileId, 'one');
    expect(find.text('保存服务器'), findsNothing);
  });

  testWidgets('delete confirmation rechecks loading and busy before mutation', (
    tester,
  ) async {
    await useDesktop(tester);
    final controller = configuredController();
    await tester.pumpWidget(PortLinkApp(controller: controller));
    await openMenu(tester, primary.name);
    await tester.tap(find.text('删除服务器'));
    await tester.pumpAndSettle();
    controller.initialized = false;
    controller.update();
    await tester.pump();
    await tester.tap(find.text('确认删除'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(controller.deletedIds, isEmpty);
  });

  testWidgets('app unmount does not dispose the caller-owned controller', (
    tester,
  ) async {
    final controller = configuredController();
    await tester.pumpWidget(PortLinkApp(controller: controller));
    await tester.pumpWidget(const SizedBox.shrink());
    expect(controller.disposeCalls, 0);
    controller.dispose();
    expect(controller.disposeCalls, 1);
  });

  testWidgets('busy connecting can always be cancelled', (tester) async {
    await useDesktop(tester);
    final controller = configuredController()
      ..busy = true
      ..activeProfile = primary
      ..tunnelStatus = const TunnelStatus(
        phase: TunnelPhase.connecting,
        profileId: 'one',
      );
    await tester.pumpWidget(PortLinkApp(controller: controller));
    await tester.tap(find.text('取消连接'));
    await tester.pumpAndSettle();
    expect(controller.disconnectCalls, 1);
    expect(controller.tunnelStatus.phase, TunnelPhase.idle);
  });

  testWidgets('changing default does not switch current connection', (
    tester,
  ) async {
    await useDesktop(tester);
    final controller = configuredController()
      ..activeProfile = primary
      ..tunnelStatus = const TunnelStatus(
        phase: TunnelPhase.ready,
        profileId: 'one',
      );
    await tester.pumpWidget(PortLinkApp(controller: controller));
    await openMenu(tester, secondary.name);
    await tester.tap(find.text('设为默认'));
    await tester.pumpAndSettle();
    expect(controller.defaultProfileId, 'two');
    expect(controller.activeProfile?.id, 'one');
    expect(controller.connectedIds, isEmpty);
    expect(controller.disconnectCalls, 0);
  });

  testWidgets('delete requires explicit confirmation', (tester) async {
    await useDesktop(tester);
    final controller = configuredController();
    await tester.pumpWidget(PortLinkApp(controller: controller));
    await openMenu(tester, primary.name);
    await tester.tap(find.text('删除服务器'));
    await tester.pumpAndSettle();
    expect(find.text('删除这台服务器？'), findsOneWidget);
    expect(controller.deletedIds, isEmpty);
    await tester.tap(find.text('保留'));
    await tester.pumpAndSettle();
    expect(controller.deletedIds, isEmpty);
    await openMenu(tester, primary.name);
    await tester.tap(find.text('删除服务器'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认删除'));
    await tester.pumpAndSettle();
    expect(controller.deletedIds, ['one']);
  });

  testWidgets('trust prompt blocks outside dismissal and never auto-accepts', (
    tester,
  ) async {
    await useDesktop(tester);
    final controller = configuredController()
      ..busy = true
      ..pendingTrust = const HostTrustRequest(
        host: 'first.example',
        port: 22,
        keyType: 'ssh-ed25519',
        fingerprint: 'SHA256:abcdefghijk1234567890',
      );
    await tester.pumpWidget(PortLinkApp(controller: controller));
    await tester.pump();
    expect(controller.trustAnswers, isEmpty);
    await tester.tapAt(const Offset(5, 5));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(find.text('核对服务器指纹'), findsOneWidget);
    expect(controller.trustAnswers, isEmpty);
    await tester.tap(find.text('拒绝连接'));
    await tester.pump();
    expect(controller.trustAnswers, [false]);
    expect(find.text('核对服务器指纹'), findsNothing);
  });

  testWidgets('trust modal also covers an already open edit dialog', (
    tester,
  ) async {
    await useDesktop(tester);
    final controller = configuredController();
    await tester.pumpWidget(PortLinkApp(controller: controller));
    await openMenu(tester, primary.name);
    await tester.tap(find.text('编辑服务器'));
    await tester.pumpAndSettle();
    controller.pendingTrust = const HostTrustRequest(
      host: 'first.example',
      port: 22,
      keyType: 'ssh-ed25519',
      fingerprint: 'SHA256:full-fingerprint-must-be-visible',
    );
    controller.update();
    await tester.pump();
    expect(find.text('核对服务器指纹'), findsOneWidget);
    expect(
      find.text('SHA256:full-fingerprint-must-be-visible'),
      findsOneWidget,
    );
    expect(controller.trustAnswers, isEmpty);
    await tester.tap(find.text('拒绝连接'));
    await tester.pumpAndSettle();
    expect(controller.trustAnswers, [false]);
    expect(find.text('保存服务器'), findsOneWidget);
  });

  testWidgets('errors are inline and raw exception secrets are not shown', (
    tester,
  ) async {
    await useDesktop(tester);
    final controller = configuredController()..throwOnConnect = true;
    await tester.pumpWidget(PortLinkApp(controller: controller));
    await tester.tap(find.text('连接服务器'));
    await tester.pumpAndSettle();
    expect(find.text('操作未完成，请检查连接与系统安全存储后重试。'), findsOneWidget);
    expect(find.textContaining('secret-that-must-not-appear'), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('copy local address uses plain loopback endpoint', (
    tester,
  ) async {
    await useDesktop(tester);
    String? clipboard;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard =
              (call.arguments as Map<Object?, Object?>)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(PortLinkApp(controller: configuredController()));
    await tester.tap(find.text('复制地址'));
    await tester.pumpAndSettle();
    expect(clipboard, '127.0.0.1:3080');
    expect(find.text('地址已复制'), findsOneWidget);
  });

  testWidgets('appearance can follow system or change explicitly', (
    tester,
  ) async {
    await useDesktop(tester);
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
    await tester.pumpWidget(PortLinkApp(controller: configuredController()));
    await tester.pumpAndSettle();

    Brightness renderedBrightness() =>
        Theme.of(tester.element(find.byType(Scaffold))).brightness;

    Future<void> selectAppearance(ThemeMode mode) async {
      await tester.tap(find.byTooltip('外观设置').hitTestable());
      await tester.pumpAndSettle();
      final item = find.byWidgetPredicate(
        (widget) =>
            widget is CheckedPopupMenuItem<ThemeMode> && widget.value == mode,
      );
      expect(item, findsOneWidget);
      await tester.ensureVisible(item);
      await tester.pumpAndSettle();
      // Tap the actual menu item's hit target, not its text's layout bounds.
      // An obscured/offscreen item must fail, rather than silence hit warnings.
      expect(item.hitTestable(), findsOneWidget);
      await tester.tap(item.hitTestable());
      await tester.pumpAndSettle();
      expect(find.byType(CheckedPopupMenuItem<ThemeMode>), findsNothing);
      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
        mode,
      );
    }

    expect(
      tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode,
      ThemeMode.system,
    );
    expect(renderedBrightness(), Brightness.light);
    await selectAppearance(ThemeMode.dark);
    expect(renderedBrightness(), Brightness.dark);
    await selectAppearance(ThemeMode.light);
    expect(renderedBrightness(), Brightness.light);
    await selectAppearance(ThemeMode.system);
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    expect(renderedBrightness(), Brightness.dark);
  });

  testWidgets('empty configuration is responsive on mobile', (tester) async {
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(PortLinkApp(controller: FakeAppController()));
    expect(tester.takeException(), isNull);
    expect(find.text('从第一台服务器开始'), findsOneWidget);
  });

  for (final width in [320.0, 390.0, 720.0, 900.0, 1280.0]) {
    testWidgets('root fits width $width', (tester) async {
      tester.view.physicalSize = Size(width, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(PortLinkApp(controller: configuredController()));
      expect(tester.takeException(), isNull);
    });
  }
}
