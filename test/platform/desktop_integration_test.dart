// ignore_for_file: deprecated_member_use
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'dart:ui' show AppExitResponse;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:portlink/core/host_trust.dart';
import 'package:portlink/core/tunnel_status.dart';
import 'package:portlink/platform/desktop_integration.dart';
import 'package:tray_manager/legacy.dart' as tray;
import 'package:window_manager/window_manager.dart';

import '../ui/fake_app_controller.dart';

class FakeTray implements tray.TrayManager {
  tray.Menu? menu;
  final iconCalls = <({String path, bool? isTemplate, int? size})>[];
  bool failIcon = false;
  int destroys = 0, popUps = 0, nativeMenuConfigurations = 0;
  Completer<void>? menuGate;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    switch (invocation.memberName) {
      case #addListener:
      case #removeListener:
        return null;
      case #setIcon:
        iconCalls.add((
          path: invocation.positionalArguments.single as String,
          isTemplate: invocation.namedArguments[#isTemplate] as bool?,
          size: invocation.namedArguments[#iconSize] as int?,
        ));
        return failIcon
            ? Future<void>.error(StateError('icon'))
            : Future<void>.value();
      case #setToolTip:
        return Future<void>.value();
      case #popUpContextMenu:
        popUps++;
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
  int shows = 0, hides = 0, destroys = 0, focuses = 0;
  bool preventClose = false, visible = false;
  @override
  dynamic noSuchMethod(Invocation invocation) {
    switch (invocation.memberName) {
      case #addListener:
      case #removeListener:
        return null;
      case #show:
        shows++;
        visible = true;
        return Future<void>.value();
      case #hide:
        hides++;
        visible = false;
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
        return Future<void>.value();
      case #focus:
        focuses++;
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
      configureNativeMenuTrigger: () async {
        trayManager.nativeMenuConfigurations++;
      },
    );
  });
  tearDown(() async {
    await desktop.prepareForExit();
    controller.dispose();
  });

  test(
    'Mac healthy launch remains hidden with no default configuration',
    () async {
      await desktop.initialize();
      expect(windows.shows, Platform.isMacOS ? 0 : 1);
      expect(windows.focuses, Platform.isMacOS ? 0 : 1);
      expect(windows.visible, !Platform.isMacOS);
      await desktop.finishStartup();
      expect(windows.visible, !Platform.isMacOS);
    },
  );

  test('Mac ready default starts hidden rather than briefly showing', () async {
    controller.defaultProfileId = 'default';
    controller.tunnelStatus = const TunnelStatus(phase: TunnelPhase.ready);
    await desktop.initialize();
    expect(windows.shows, Platform.isMacOS ? 0 : 1);
    await desktop.finishStartup();
    expect(windows.visible, isFalse);
    expect(windows.focuses, Platform.isMacOS ? 0 : 1);
  });

  test('explicit show survives late and repeated finishStartup', () async {
    controller.defaultProfileId = 'default';
    await desktop.initialize();
    await desktop.showWindow();
    final hidesBeforeReady = windows.hides;
    controller.tunnelStatus = const TunnelStatus(phase: TunnelPhase.ready);
    controller.update();
    await settleAsync();
    await desktop.finishStartup();
    await desktop.finishStartup();
    expect(windows.visible, isTrue);
    expect(windows.hides, hidesBeforeReady);
  });

  test('menu manage action shows and focuses then close only hides', () async {
    await desktop.initialize();
    final shows = windows.shows;
    final focuses = windows.focuses;
    final showItem = trayManager.menu!.items!.firstWhere(
      (item) => item.key == 'show',
    );
    desktop.onTrayMenuItemClick(showItem);
    await settleAsync();
    expect(windows.shows, shows + 1);
    expect(windows.focuses, focuses + 1);
    expect(windows.visible, isTrue);
    desktop.onWindowClose();
    await settleAsync();
    expect(windows.visible, isFalse);
    expect(windows.destroys, 0);
    expect(controller.disconnectCalls, 0);
  });

  test('Mac right click remains native and left click calls up GUI', () async {
    await desktop.initialize();
    expect(trayManager.nativeMenuConfigurations, Platform.isMacOS ? 1 : 0);
    desktop.onTrayIconRightMouseDown();
    desktop.onTrayIconRightMouseUp();
    await settleAsync();
    expect(trayManager.popUps, Platform.isMacOS ? 0 : 1);
    final shows = windows.shows;
    desktop.onTrayIconMouseDown();
    desktop.onTrayIconMouseUp();
    await settleAsync();
    expect(trayManager.popUps, Platform.isMacOS ? 0 : 2);
    expect(windows.shows, shows + (Platform.isMacOS ? 1 : 0));
    if (Platform.isMacOS) expect(windows.visible, isTrue);
  });

  test('native trigger is reconfigured after updated menu creation', () async {
    await desktop.initialize();
    controller.tunnelStatus = const TunnelStatus(phase: TunnelPhase.connecting);
    controller.update();
    await settleAsync();
    expect(trayManager.nativeMenuConfigurations, Platform.isMacOS ? 2 : 0);
  });

  test(
    'native menu trigger failure falls back to visible manageable window',
    () async {
      desktop = DesktopIntegration(
        controller,
        trayManager: trayManager,
        windows: windows,
        configureNativeMenuTrigger: () async =>
            throw StateError('trigger failure'),
      );
      await desktop.initialize();
      if (Platform.isMacOS) {
        expect(desktop.warning, isNotNull);
        expect(windows.visible, isTrue);
        expect(windows.focuses, greaterThan(0));
      }
    },
  );

  test(
    'trust prompt during initial connection is visible and never auto accepted',
    () async {
      await desktop.initialize();
      controller.pendingTrust = const HostTrustRequest(
        host: 'fixture.example',
        port: 22,
        keyType: 'ssh-ed25519',
        fingerprint: 'SHA256:fixture',
      );
      controller.update();
      await settleAsync();
      expect(windows.visible, isTrue);
      expect(controller.trustAnswers, isEmpty);
      controller.pendingTrust = null;
      controller.defaultProfileId = 'default';
      controller.tunnelStatus = const TunnelStatus(phase: TunnelPhase.ready);
      controller.update();
      await settleAsync();
      final hides = windows.hides;
      await desktop.finishStartup();
      expect(windows.visible, isTrue);
      expect(windows.hides, hides);
    },
  );

  test('preexisting failure shows despite hidden startup policy', () async {
    controller.errorMessage = '配置无法读取';
    await desktop.initialize();
    expect(windows.visible, isTrue);
    expect(windows.focuses, greaterThan(0));
    await desktop.finishStartup();
    expect(windows.visible, isTrue);
  });

  test(
    'target unavailable and platform warning each present the hidden window',
    () async {
      await desktop.initialize();
      controller.tunnelStatus = const TunnelStatus(
        phase: TunnelPhase.targetUnavailable,
      );
      controller.update();
      await settleAsync();
      expect(windows.visible, isTrue);
      desktop.onWindowClose();
      await settleAsync();
      expect(windows.visible, isFalse);
      controller.reportPlatformWarning('系统会话不可用');
      await settleAsync();
      expect(windows.visible, isTrue);
    },
  );

  test(
    'all tray writes preserve colour and use visible 22pt Retina artwork',
    () async {
      await desktop.initialize();
      expect(trayManager.iconCalls, hasLength(1));
      for (final phase in TunnelPhase.values) {
        controller.tunnelStatus = TunnelStatus(phase: phase);
        controller.update();
        await settleAsync();
        final state = switch (phase) {
          TunnelPhase.ready => 'ready',
          TunnelPhase.failed => 'failed',
          TunnelPhase.idle => 'idle',
          _ => 'pending',
        };
        final expected = Platform.isWindows
            ? 'assets/tray/windows_$state.ico'
            : Platform.isMacOS
            ? 'assets/tray/$state@2x.png'
            : 'assets/tray/$state.png';
        expect(trayManager.iconCalls.last.path, expected, reason: phase.name);
      }
      for (final call in trayManager.iconCalls) {
        expect(call.isTemplate, isFalse, reason: call.path);
        expect(call.size, 22, reason: call.path);
      }
    },
  );

  test(
    'ready becomes red immediately when its target probe becomes unavailable',
    () async {
      controller.tunnelStatus = const TunnelStatus(phase: TunnelPhase.ready);
      await desktop.initialize();
      expect(trayManager.iconCalls.last.path, contains('ready'));
      controller.tunnelStatus = const TunnelStatus(
        phase: TunnelPhase.targetUnavailable,
      );
      controller.update();
      await settleAsync();
      expect(trayManager.iconCalls.last.path, contains('pending'));
      expect(trayManager.iconCalls.last.path, isNot(contains('ready')));
      controller.tunnelStatus = const TunnelStatus(phase: TunnelPhase.idle);
      controller.update();
      await settleAsync();
      expect(trayManager.iconCalls.last.path, contains('idle'));
    },
  );

  for (final state in ['idle', 'ready', 'pending', 'failed']) {
    for (final scale in [1, 2]) {
      test(
        'tray $state @${scale}x PNG uses solid correct status colour',
        () async {
          final suffix = scale == 1 ? '' : '@2x';
          final bytes = await File('assets/tray/$state$suffix.png')
              .readAsBytes();
          final codec = await ui.instantiateImageCodec(bytes);
          final frame = await codec.getNextFrame();
          final image = frame.image;
          try {
            expect(image.width, 22 * scale);
            expect(image.height, 22 * scale);
            final rgba = await image.toByteData(
              format: ui.ImageByteFormat.rawRgba,
            );
            expect(rgba, isNotNull);
            var red = 0;
            var green = 0;
            var white = 0;
            var transparent = 0;
            for (var offset = 0; offset < rgba!.lengthInBytes; offset += 4) {
              final r = rgba.getUint8(offset);
              final g = rgba.getUint8(offset + 1);
              final b = rgba.getUint8(offset + 2);
              final a = rgba.getUint8(offset + 3);
              if (a == 0) transparent++;
              if (a < 220) continue;
              if (r > 160 && r > g * 1.5 && r > b * 1.5) red++;
              if (g > 100 && g > r * 1.5 && g > b * 1.5) green++;
              if (r > 240 && g > 240 && b > 240) white++;
            }
            final pixels = image.width * image.height;
            expect(state == 'ready' ? green : red, greaterThan(pixels * .3));
            expect(state == 'ready' ? red : green, 0);
            expect(white, greaterThan(0), reason: 'non-colour state symbol');
            expect(
              transparent,
              greaterThan(0),
              reason: 'transparent outer corners',
            );
          } finally {
            image.dispose();
            codec.dispose();
          }
        },
      );
    }
  }

  test(
    'healthy tray close hides, fatal or failed tray close exits safely',
    () async {
      await desktop.initialize();
      final startupHides = windows.hides;
      desktop.onWindowClose();
      await settleAsync();
      expect(windows.hides, startupHides + 1);
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
      configureNativeMenuTrigger: () async {
        trayManager.nativeMenuConfigurations++;
      },
      onShutdown: () async {
        await gate.future;
        cleaned = true;
      },
    );
    await desktop.initialize();
    expect(desktop.warning, isNotNull);
    expect(windows.visible, isTrue);
    expect(windows.focuses, greaterThan(0));
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
        configureNativeMenuTrigger: () async {
          trayManager.nativeMenuConfigurations++;
        },
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
