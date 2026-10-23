import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:portlink/core/server_profile.dart';
import 'package:portlink/ui/portlink_app.dart';
import 'package:portlink/ui/server_profile_dialog.dart';
import 'fake_app_controller.dart';

const profile = ServerProfile(
  id: 'one',
  name: '工作服务器',
  host: 'first.example',
  username: 'alice',
);

Finder field(String label) => find.byKey(
  ValueKey(switch (label) {
    '显示名称' => 'profile-name',
    '主机地址' => 'profile-host',
    'SSH 端口' => 'profile-port',
    'SSH 用户名' => 'profile-username',
    _ => 'profile-password',
  }),
);

Future<void> desktop(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1280, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> addDialog(
  WidgetTester tester,
  FakeAppController controller,
) async {
  await tester.pumpWidget(PortLinkApp(controller: controller));
  await tester.ensureVisible(find.text('添加服务器'));
  await tester.tap(find.text('添加服务器'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('new profile requires fields and password', (tester) async {
    await desktop(tester);
    final controller = FakeAppController();
    await addDialog(tester, controller);
    await tester.tap(find.text('保存服务器'));
    await tester.pumpAndSettle();
    expect(controller.savedProfiles, isEmpty);
    expect(find.text('请输入 SSH 密码'), findsOneWidget);
    expect(find.text('请输入服务器名称'), findsOneWidget);

    await tester.enterText(field('显示名称'), '  新服务器  ');
    await tester.enterText(field('主机地址'), 'example.com');
    await tester.enterText(field('SSH 用户名'), 'alice');
    await tester.enterText(field('SSH 密码'), ' password with spaces ');
    await tester.tap(find.text('保存服务器'));
    await tester.pumpAndSettle();
    expect(controller.savedProfiles, hasLength(1));
    expect(controller.savedProfiles.single['name'], '新服务器');
    expect(controller.savedProfiles.single['sshPort'], 22);
    expect(
      controller.savedProfiles.single['password'],
      ' password with spaces ',
    );
    expect(controller.savedProfiles.single['makeDefault'], isTrue);
  });

  testWidgets('edit never shows saved password and blank retains it', (
    tester,
  ) async {
    await desktop(tester);
    final controller = FakeAppController()
      ..profiles = [profile]
      ..defaultProfileId = 'one';
    await tester.pumpWidget(PortLinkApp(controller: controller));
    await tester.tap(find.byTooltip('工作服务器的更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑服务器'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextFormField>(field('新密码（留空保留原密码）')).controller?.text,
      isEmpty,
    );
    await tester.tap(find.text('保存服务器'));
    await tester.pumpAndSettle();
    expect(controller.savedProfiles.single['id'], 'one');
    expect(controller.savedProfiles.single['password'], isNull);
  });

  testWidgets('save failure stays in dialog with safe inline feedback', (
    tester,
  ) async {
    await desktop(tester);
    final controller = FakeAppController()..saveError = '系统安全凭据库不可用，密码未保存。';
    await addDialog(tester, controller);
    await tester.enterText(field('显示名称'), '新服务器');
    await tester.enterText(field('主机地址'), 'example.com');
    await tester.enterText(field('SSH 用户名'), 'alice');
    await tester.enterText(field('SSH 密码'), 'password');
    await tester.tap(find.text('保存服务器'));
    await tester.pumpAndSettle();
    expect(find.text('保存服务器'), findsOneWidget);
    expect(find.text('系统安全凭据库不可用，密码未保存。'), findsWidgets);
    expect(controller.savedProfiles, isEmpty);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets(
    'add form fits a narrow viewport without intrinsic layout errors',
    (tester) async {
      tester.view.physicalSize = const Size(320, 720);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await addDialog(tester, FakeAppController());
      expect(tester.takeException(), isNull);
      expect(find.text('保存服务器'), findsOneWidget);
    },
  );

  testWidgets('direct dialog cannot save before initialization', (
    tester,
  ) async {
    await desktop(tester);
    final controller = FakeAppController()..initialized = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ServerProfileDialog(controller: controller)),
      ),
    );
    final button = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('保存服务器'),
        matching: find.byWidgetPredicate((widget) => widget is FilledButton),
      ),
    );
    expect(button.onPressed, isNull);
    expect(tester.widget<TextFormField>(field('显示名称')).enabled, isFalse);
    expect(controller.savedProfiles, isEmpty);
  });

  testWidgets('save callback rechecks controller busy state', (tester) async {
    await desktop(tester);
    final controller = FakeAppController();
    await addDialog(tester, controller);
    await tester.enterText(field('显示名称'), '新服务器');
    await tester.enterText(field('主机地址'), 'example.com');
    await tester.enterText(field('SSH 用户名'), 'alice');
    await tester.enterText(field('SSH 密码'), 'password');
    final button = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text('保存服务器'),
        matching: find.byWidgetPredicate((widget) => widget is FilledButton),
      ),
    );
    controller.busy = true;
    button.onPressed!();
    await tester.pump();
    expect(controller.savedProfiles, isEmpty);
  });

  testWidgets('invalid endpoint does not invoke controller', (tester) async {
    await desktop(tester);
    final controller = FakeAppController();
    await addDialog(tester, controller);
    await tester.enterText(field('显示名称'), '新服务器');
    await tester.enterText(field('主机地址'), 'https://example.com/path');
    await tester.enterText(field('SSH 用户名'), 'alice');
    await tester.enterText(field('SSH 密码'), 'password');
    await tester.tap(find.text('保存服务器'));
    await tester.pumpAndSettle();
    expect(controller.savedProfiles, isEmpty);
    expect(find.textContaining('不含协议和路径'), findsOneWidget);
  });
}
