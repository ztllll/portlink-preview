import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:portlink/core/forward_rule.dart';
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

  Future<void> fillBasics(WidgetTester tester) async {
    await tester.enterText(field('显示名称'), '多端口服务器');
    await tester.enterText(field('主机地址'), 'example.com');
    await tester.enterText(field('SSH 用户名'), 'alice');
    await tester.enterText(field('SSH 密码'), 'password');
  }

  Future<void> save(WidgetTester tester) async {
    await tester.ensureVisible(find.text('保存服务器'));
    await tester.tap(find.text('保存服务器'));
    await tester.pumpAndSettle();
  }

  testWidgets('a new server starts with one editable default rule', (
    tester,
  ) async {
    await desktop(tester);
    final controller = FakeAppController();
    await addDialog(tester, controller);
    expect(find.byKey(const ValueKey('rule-local-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('rule-local-1')), findsNothing);
    // The last remaining rule cannot be removed.
    final remove = tester.widget<IconButton>(
      find.byKey(const ValueKey('rule-remove-0')),
    );
    expect(remove.onPressed, isNull);
  });

  testWidgets('several forwards, custom ports and custom hosts are saved', (
    tester,
  ) async {
    await desktop(tester);
    final controller = FakeAppController();
    await addDialog(tester, controller);
    await fillBasics(tester);
    await tester.enterText(find.byKey(const ValueKey('rule-local-0')), '8080');
    await tester.enterText(find.byKey(const ValueKey('rule-remote-0')), '80');
    await tester.ensureVisible(find.byKey(const ValueKey('rule-add')));
    await tester.tap(find.byKey(const ValueKey('rule-add')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('rule-local-1')), '15432');
    await tester.enterText(
      find.byKey(const ValueKey('rule-target-1')),
      '10.0.0.5',
    );
    await tester.enterText(find.byKey(const ValueKey('rule-remote-1')), '5432');
    await save(tester);
    final rules =
        controller.savedProfiles.single['rules']! as List<ForwardRule>;
    expect(rules.length, 2);
    expect([rules[0].localPort, rules[0].remotePort], [8080, 80]);
    expect(rules[0].bindHost, '127.0.0.1');
    expect([rules[1].localPort, rules[1].remotePort], [15432, 5432]);
    expect(rules[1].targetHost, '10.0.0.5');
    expect(ForwardRule.validateAll(rules), isNull);
  });

  testWidgets(
    'a clashing local port is rejected before the controller is called',
    (tester) async {
      await desktop(tester);
      final controller = FakeAppController();
      await addDialog(tester, controller);
      await fillBasics(tester);
      await tester.ensureVisible(find.byKey(const ValueKey('rule-add')));
      await tester.tap(find.byKey(const ValueKey('rule-add')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('rule-local-0')),
        '9000',
      );
      await tester.enterText(
        find.byKey(const ValueKey('rule-local-1')),
        '9000',
      );
      await save(tester);
      expect(controller.savedProfiles, isEmpty);
      expect(find.textContaining('重复使用'), findsOneWidget);
    },
  );

  testWidgets('a privileged local port is rejected', (tester) async {
    await desktop(tester);
    final controller = FakeAppController();
    await addDialog(tester, controller);
    await fillBasics(tester);
    await tester.enterText(find.byKey(const ValueKey('rule-local-0')), '80');
    await save(tester);
    expect(controller.savedProfiles, isEmpty);
  });

  testWidgets('listening on 0.0.0.0 shows a network-exposure warning', (
    tester,
  ) async {
    await desktop(tester);
    final controller = FakeAppController();
    await addDialog(tester, controller);
    expect(find.textContaining('同一网络中的其他设备'), findsNothing);
    await tester.enterText(
      find.byKey(const ValueKey('rule-bind-0')),
      '0.0.0.0',
    );
    await tester.pump();
    expect(find.textContaining('同一网络中的其他设备'), findsOneWidget);
  });

  testWidgets('disabling every rule is rejected; removing a rule works', (
    tester,
  ) async {
    await desktop(tester);
    final controller = FakeAppController();
    await addDialog(tester, controller);
    await fillBasics(tester);
    await tester.ensureVisible(find.byKey(const ValueKey('rule-add')));
    await tester.tap(find.byKey(const ValueKey('rule-add')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rule-local-1')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('rule-remove-1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rule-local-1')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('rule-enabled-0')));
    await tester.pump();
    await save(tester);
    expect(controller.savedProfiles, isEmpty);
    expect(find.textContaining('至少需要启用一条'), findsOneWidget);
  });

  testWidgets('editing keeps the rules the server already has', (tester) async {
    await desktop(tester);
    final existing = profile.copyWith(
      rules: const [
        ForwardRule(id: 'a', label: 'Web', localPort: 8080, remotePort: 80),
        ForwardRule(id: 'b', label: 'DB', localPort: 9000, remotePort: 5432),
      ],
    );
    final controller = FakeAppController()
      ..profiles = [existing]
      ..defaultProfileId = 'one';
    await tester.pumpWidget(PortLinkApp(controller: controller));
    await tester.tap(find.byTooltip('工作服务器的更多操作'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑服务器'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('rule-local-0')), findsOneWidget);
    expect(find.byKey(const ValueKey('rule-local-1')), findsOneWidget);
    await save(tester);
    final rules =
        controller.savedProfiles.single['rules']! as List<ForwardRule>;
    expect(rules.map((r) => r.id), ['a', 'b']);
  });
}
