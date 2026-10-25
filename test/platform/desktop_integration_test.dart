// ignore_for_file: deprecated_member_use
import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:portlink/core/tunnel_status.dart';
import 'package:portlink/platform/desktop_integration.dart';
import 'package:tray_manager/legacy.dart' as tray;
import 'package:window_manager/window_manager.dart';

import '../ui/fake_app_controller.dart';

class FakeTray implements tray.TrayManager {
  tray.Menu? menu;
  bool failIcon = false;
  int destroys = 0;
  Completer<void>? menuGate;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    switch (invocation.memberName) {
      case #addListener:
      case #removeListener:
        return null;
      case #setIcon:
        return failIcon
            ? Future<void>.error(StateError('icon'))
            : Future<void>.value();
      case #setToolTip:
      case #popUpContextMenu:
        return Future<void>.value();
      case #setContextMenu:
        menu = invocation.positionalArguments.single as tray.Menu;
        return menuGate?.future ?? Future<void>.value();
      case #destroy:
        destroys++;
        return Future<void>.value();
      default:
        return super.noSuchMethod(invocation);
    }
  }
}

class FakeWindows implements WindowManager {
  int shows = 0, hides = 0, destroys = 0;
  bool preventClose = false;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    switch (invocation.memberName) {
      case #addListener:
      case #removeListener:
        return null;
      case #show:
        shows++;
        return Future<void>.value();
      case #hide:
        hides++;
        return Future<void>.value();
      case #destroy:
        destroys++;
        return Future<void>.value();
      case #setPreventClose:
        preventClose = invocation.positionalArguments.single as bool;
        return Future<void>.value();
      case #ensureInitialized:
      case #setTitle:
      case #setMinimumSize:
      case #setSize:
      case #center:
      case #focus:
        return Future<void>.value();
      default:
        return super.noSuchMethod(invocation);
    }
  }
}

Future<void> settleAsync() async {
  for (var i = 0; i < 12; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeAppController controller;
  late FakeTray trayManager;
  late FakeWindows windows;
  late DesktopIntegration desktop;
  setUp(() {
    controller = FakeAppController();
    trayManager = FakeTray();
    windows = FakeWindows();
    desktop = DesktopIntegration(
      controller,
      trayManager: trayManager,
      windows: windows,
    );
  });
  tearDown(() async {
    await desktop.prepareForExit();
    controller.dispose();
  });

  test(
    'healthy tray close hides, fatal or failed tray close exits safely',
    () async {
      await desktop.initialize();
      desktop.onWindowClose();
      await settleAsync();
      expect(windows.hides, 1);
      expect(windows.preventClose, isTrue);
      expect(windows.destroys, 0);
      await Future.wait([desktop.quit(), desktop.quit()]);
      expect(windows.preventClose, isFalse);
      expect(windows.destroys, 1);
      expect(trayManager.destroys, 1);
    },
  );
  test('tray failure keeps close intercept until cleanup completes', () async {
    trayManager.failIcon = true;
    final gate = Completer<void>();
    var cleaned = false;
    desktop = DesktopIntegration(
      controller,
      trayManager: trayManager,
      windows: windows,
      onShutdown: () async {
        await gate.future;
        cleaned = true;
      },
    );
    await desktop.initialize();
    expect(desktop.warning, isNotNull);
    expect(windows.preventClose, isTrue);
    desktop.onWindowClose();
    await settleAsync();
    expect(windows.destroys, 0);
    gate.complete();
    await settleAsync();
    expect(cleaned, isTrue);
    expect(windows.destroys, 1);
  });
  test(
    'native exit request waits for cleanup and shares concurrent exit work',
    () async {
      final gate = Completer<void>();
      var calls = 0;
      desktop = DesktopIntegration(
        controller,
        trayManager: trayManager,
        windows: windows,
        onShutdown: () async {
          calls++;
          await gate.future;
        },
      );
      await desktop.initialize();
      var responded = false;
      final request = WidgetsBinding.instance.handleRequestAppExit().then((r) {
        responded = true;
        return r;
      });
      final second = desktop.prepareForExit();
      await settleAsync();
      expect(responded, isFalse);
      expect(calls, 1);
      expect(trayManager.destroys, 0);
      gate.complete();
      expect(await request, AppExitResponse.exit);
      await second;
      expect(trayManager.destroys, 1);
      expect(windows.destroys, 0);
    },
  );
  test(
    'shutdown waits for in-flight menu update before destroying tray',
    () async {
      await desktop.initialize();
      final gate = Completer<void>();
      trayManager.menuGate = gate;
      controller.tunnelStatus = const TunnelStatus(phase: TunnelPhase.ready);
      controller.update();
      await settleAsync();
      final quit = desktop.quit();
      await settleAsync();
      expect(trayManager.destroys, 0);
      gate.complete();
      await quit;
      expect(trayManager.destroys, 1);
    },
  );
  test('persistent error does not steal focus on every health event', () async {
    await desktop.initialize();
    final initial = windows.shows;
    controller.errorMessage = 'save failed';
    controller.update();
    await settleAsync();
    expect(windows.shows, initial + 1);
    controller.update();
    controller.update();
    await settleAsync();
    expect(windows.shows, initial + 1);
    controller.errorMessage = 'new failure';
    controller.update();
    await settleAsync();
    expect(windows.shows, initial + 2);
  });
  test(
    'target unavailable and stale HTTP menu callbacks cannot launch browser',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var launches = 0;
      messenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/url_launcher'),
        (call) async {
          launches++;
          return true;
        },
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/url_launcher'),
          null,
        ),
      );
      await desktop.initialize();
      controller.tunnelStatus = const TunnelStatus(
        phase: TunnelPhase.targetUnavailable,
      );
      controller.update();
      await settleAsync();
      expect(
        trayManager.menu!.items!.firstWhere((i) => i.key == 'http').disabled,
        isTrue,
      );
      desktop.onTrayMenuItemClick(
        tray.MenuItem(key: 'http', label: 'old HTTP'),
      );
      await settleAsync();
      expect(launches, 0);
    },
  );
}
