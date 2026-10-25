// Native-only verification target. Never shipped as the production entrypoint.
// ignore_for_file: deprecated_member_use
// Fixture is started outside this sandboxed app; no real credentials are used.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:ui' show AppExitType;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';
import 'package:tray_manager/legacy.dart' as tray;
import 'package:portlink/app_controller.dart';
import 'package:portlink/core/forward_rule.dart';
import 'package:portlink/core/tunnel_engine.dart';
import 'package:portlink/core/tunnel_status.dart';
import 'package:portlink/data/host_trust_store.dart';
import 'package:portlink/data/profile_repository.dart';
import 'package:portlink/data/secret_store.dart';
import 'package:portlink/platform/desktop_integration.dart';
import 'package:portlink/platform/single_instance_guard.dart';
import 'package:portlink/ui/portlink_app.dart';

class CloseCounter with WindowListener {
  int count = 0;
  @override
  void onWindowClose() {
    count++;
  }
}

void nativeStep(String stage) {
  stdout.writeln('PORTLINK_NATIVE_SMOKE_STEP $stage');
}

void require(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> main(List<String> arguments) async {
  WidgetsFlutterBinding.ensureInitialized();
  var failed = false;
  final completed = <String>[];
  final measurements = <String, Object?>{};
  final options = <String, String>{};
  for (final argument in arguments) {
    if (argument.startsWith('--') && argument.contains('=')) {
      final split = argument.indexOf('=');
      options[argument.substring(2, split)] = argument.substring(split + 1);
    }
  }
  final cleanupOnly = options['cleanup-run-id'];
  if (cleanupOnly != null) {
    if (!Platform.isMacOS ||
        !RegExp(r'^smoke-[0-9]+-[0-9]+$').hasMatch(cleanupOnly)) {
      exit(64);
    }
    final cleanupStore = SecureSecretStore(
      storage: FlutterSecureStorage(
        mOptions: MacOsOptions(
          accountName: 'dev.portlink.native-smoke.$cleanupOnly',
          usesDataProtectionKeychain: false,
          synchronizable: false,
        ),
      ),
    );
    await cleanupStore.deletePassword(cleanupOnly);
    final removed = await cleanupStore.readPassword(cleanupOnly) == null;
    stdout.writeln(
      'PORTLINK_NATIVE_SMOKE_CLEANUP ${jsonEncode({'runId': cleanupOnly, 'removed': removed})}',
    );
    await stdout.flush();
    await ServicesBinding.instance.exitApplication(AppExitType.required);
    return;
  }
  final fixturePort = int.tryParse(options['fixture-port'] ?? '');
  final fingerprint = options['fingerprint'];
  if (!Platform.isMacOS ||
      fixturePort == null ||
      fingerprint == null ||
      !fingerprint.startsWith('SHA256:')) {
    stdout.writeln(
      'PORTLINK_NATIVE_SMOKE ${jsonEncode({'success': false, 'reason': 'valid isolated fixture arguments required'})}',
    );
    exit(64);
  }
  Directory? temporary;
  AppController? controller;
  DesktopIntegration? desktop;
  SingleInstanceGuard? guard;
  final runId =
      'smoke-${DateTime.now().microsecondsSinceEpoch}-${Random.secure().nextInt(1 << 30)}';
  final secrets = SecureSecretStore(
    storage: FlutterSecureStorage(
      mOptions: MacOsOptions(
        accountName: 'dev.portlink.native-smoke.$runId',
        usesDataProtectionKeychain: false,
        synchronizable: false,
      ),
    ),
  );
  var stage = 'start';
  var status = 'unknown';
  try {
    final support = await getApplicationSupportDirectory();
    final smokeRoot = await Directory(path.join(support.path, 'native-smoke'))
        .create(recursive: true);
    temporary = await smokeRoot.createTemp('run-');
    guard = await SingleInstanceGuard.acquire(
      path.join(temporary.path, 'instance.lock'),
    );
    completed.add('sandbox application support + OS file lock');
    stage = 'keychain';
    nativeStep(stage);
    await secrets
        .writePassword(runId, 'fixture-only-password')
        .timeout(const Duration(seconds: 20));
    require(
      await secrets.readPassword(runId) == 'fixture-only-password',
      'keychain read mismatch',
    );
    completed.add('native macOS login Keychain write/read');
    final repository = JsonProfileRepository(
      path.join(temporary.path, 'profiles.json'),
    );
    final trust = JsonHostTrustStore(
      path.join(temporary.path, 'known_hosts.json'),
    );
    final reservation = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final listenPort = reservation.port;
    await reservation.close();
    final secondReservation = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final secondPort = secondReservation.port;
    await secondReservation.close();
    final engine = SshTunnelEngine(
      trustStore: trust,
      timing: const TunnelTiming(
        healthInterval: Duration(seconds: 60),
        maxRetries: 0,
      ),
    );
    controller = AppController(
      repository: repository,
      secrets: secrets,
      engine: engine,
      newId: () => runId,
    );
    runApp(PortLinkApp(controller: controller));
    stage = 'desktop';
    nativeStep(stage);
    desktop = DesktopIntegration(controller);
    await desktop.initialize().timeout(const Duration(seconds: 20));
    require(desktop.warning == null, 'native tray initialization failed');
    require(tray.trayManager.isSupported, 'native tray unsupported');
    var bounds = await tray.trayManager.getBounds();
    for (var i = 0; i < 30 && (bounds == null || bounds.width <= 0); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      bounds = await tray.trayManager.getBounds();
    }
    require(
      bounds != null && bounds.width > 0,
      'native tray bounds unavailable',
    );
    require(
      tray.trayManager.trayIcon?.isVisible() == true,
      'native tray not visible',
    );
    const diagnostic = MethodChannel('dev.portlink/window_diagnostics');
    final startup = (await diagnostic.invokeMapMethod<String, dynamic>(
      'snapshot',
    ))!;
    require(
      !await windowManager.isVisible(),
      'menu-bar app showed a window at startup',
    );
    require(
      startup['lsuiElement'] == true && startup['activationPolicy'] == 1,
      'app is not accessory/no-Dock',
    );
    measurements['menuBarStartup'] = {
      'windowHidden': true,
      'lsuiElement': startup['lsuiElement'],
      'activationPolicy': startup['activationPolicy'],
    };
    Future<Map<String, dynamic>> exerciseTray(String method) async {
      final nativeMenu = tray.trayManager.trayIcon?.getContextMenu();
      require(nativeMenu != null, 'native context menu unavailable');
      final result = (await diagnostic
          .invokeMapMethod<String, dynamic>(method, {
            'menuAddress': nativeMenu!.nativeObject.address,
          })
          .timeout(const Duration(seconds: 10)))!;
      measurements[method] = result;
      for (var i = 0; i < 40 && !await windowManager.isVisible(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      require(
        await windowManager.isVisible(),
        'tray interaction failed to show GUI',
      );
      return result;
    }

    final rightClick = await exerciseTray('exerciseTrayMenu');
    require(
      rightClick['menuTrackingOpened'] == true &&
          rightClick['manageActionSelected'] == true,
      'right-click native menu did not open/select manager',
    );
    measurements['rightClickMenu'] = rightClick;
    completed.add(
      'AppKit right-click opens actual menu; management action shows GUI',
    );
    await windowManager.hide();
    final leftClick = await exerciseTray('exerciseTrayLeftClick');
    require(
      leftClick['menuTrackingOpened'] == false,
      'left click should show GUI without a second popup',
    );
    measurements['leftClickShow'] = leftClick;
    completed.add('AppKit left-click restores GUI without Dock');
    await desktop.finishStartup();
    require(
      await windowManager.isVisible(),
      'late startup hid manually shown GUI',
    );
    Future<Map<String, dynamic>> requireTrayColor(String color) async {
      const diagnostic = MethodChannel('dev.portlink/window_diagnostics');
      for (var attempt = 0; attempt < 40; attempt++) {
        final snapshot = (await diagnostic.invokeMapMethod<String, dynamic>(
          'snapshot',
        ))!;
        final images = (snapshot['trayImages'] as List?) ?? [];
        for (final raw in images) {
          final image = Map<String, dynamic>.from(raw as Map);
          if (image['isTemplate'] == false &&
              (image['width'] as num) >= 20 &&
              (image['height'] as num) >= 20 &&
              (image['${color}Pixels'] as num) > 20) {
            measurements['${color}Tray'] = image;
            return image;
          }
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      throw StateError(
        'native $color tray image not found or too small/template',
      );
    }

    await requireTrayColor('red');
    completed.add(
      'native tray creation/menu: red non-template image at least 20pt',
    );
    await controller.initialize();
    await controller.saveProfile(
      name: 'Native smoke fixture',
      host: '127.0.0.1',
      sshPort: fixturePort,
      username: 'portlink-test',
      password: 'fixture-only-password',
      makeDefault: true,
      rules: [
        ForwardRule(
          id: 'smoke',
          label: 'smoke',
          localPort: listenPort,
          remotePort: 3080,
        ),
        ForwardRule(
          id: 'second',
          label: 'second',
          bindHost: '127.0.0.1',
          localPort: secondPort,
          targetHost: 'localhost',
          remotePort: 3080,
        ),
      ],
    );
    require(controller.errorMessage == null, 'profile save failed');
    require(
      (await repository.load()).defaultProfileId == runId,
      'profile persistence mismatch',
    );
    completed.add('isolated persistent configuration + credential save');
    controller.addListener(() {
      final request = controller!.pendingTrust;
      if (request != null) {
        controller.answerHostTrust(request.fingerprint == fingerprint);
      }
    });
    stage = 'ssh';
    nativeStep(stage);
    await controller.connectProfile(runId).timeout(const Duration(seconds: 30));
    status = engine.status.phase.name;
    require(
      engine.status.phase == TunnelPhase.ready,
      'native SSH tunnel not ready',
    );
    completed.add(
      'real SSH password authentication + pinned fixture host + target probe',
    );
    await requireTrayColor('green');
    completed.add('ready native tray image: green and non-template');
    require(
      engine.status.rules.length == 2 && engine.status.readyRuleCount == 2,
      'two native forwarding rules did not become ready',
    );
    final secondSocket = await Socket.connect('127.0.0.1', secondPort);
    final secondInput = StreamIterator<List<int>>(secondSocket);
    final secondPayload = List<int>.generate(32768, (i) => (i + 23) % 251);
    try {
      secondSocket.add(secondPayload);
      await secondSocket.flush();
      final received = <int>[];
      while (received.length < secondPayload.length) {
        require(
          await secondInput.moveNext().timeout(const Duration(seconds: 10)),
          'second rule EOF',
        );
        received.addAll(secondInput.current);
      }
      require(
        received.length == secondPayload.length &&
            List.generate(
              received.length,
              (i) => received[i] == secondPayload[i],
            ).every((v) => v),
        'custom-bind second rule payload mismatch',
      );
    } finally {
      secondSocket.destroy();
      await secondInput.cancel();
    }
    final menuKeys = tray.trayManager.contextMenu!.items!
        .map((item) => item.key)
        .toSet();
    require(
      menuKeys.containsAll({
        'copy:smoke',
        'http:smoke',
        'copy:second',
        'http:second',
      }),
      'multi-rule tray actions missing',
    );
    measurements['multiPort'] = {
      'rules': 2,
      'ready': engine.status.readyRuleCount,
      'secondBind': '127.0.0.1',
      'secondTarget': 'localhost',
      'secondBytes': secondPayload.length,
      'matched': true,
    };
    completed.add(
      'two native forwards share SSH; custom bind/target, per-rule copy/HTTP menus and payloads verified',
    );
    for (var i = 0; i < 3; i++) {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4,
        listenPort,
      );
      final payload = List<int>.generate(128 * 1024, (j) => (j + i) % 251);
      final reply = socket.fold<List<int>>(
        [],
        (all, bytes) => all..addAll(bytes),
      );
      socket.add(payload);
      await socket.flush();
      await socket.close();
      final data = await reply.timeout(const Duration(seconds: 15));
      require(
        data.length == payload.length &&
            List.generate(
              data.length,
              (j) => data[j] == payload[j],
            ).every((x) => x),
        'native tunnel payload mismatch',
      );
      socket.destroy();
    }
    completed.add('real native-process tunneled payload roundtrips');
    stage = 'window-close';
    nativeStep(stage);
    require(
      desktop.warning == null && controller.platformWarning == null,
      'tray update failed before close',
    );
    final before = (await diagnostic.invokeMapMethod<String, dynamic>(
      'snapshot',
    ))!;
    final closeCounter = CloseCounter();
    windowManager.addListener(closeCounter);
    require(
      await windowManager.isPreventClose(),
      'native close prevention lost',
    );
    await windowManager.close();
    nativeStep('native close call returned');
    for (var i = 0; i < 30 && await windowManager.isVisible(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    require(!await windowManager.isVisible(), 'close did not hide to tray');
    final after = (await diagnostic.invokeMapMethod<String, dynamic>(
      'snapshot',
    ))!;
    windowManager.removeListener(closeCounter);
    require(
      closeCounter.count == 1,
      'native close callback was not delivered exactly once',
    );
    require(
      after['willCloseCount'] == before['willCloseCount'],
      'native window actually closed instead of hiding',
    );
    require(
      engine.status.phase == TunnelPhase.ready,
      'tunnel lost when hiding window',
    );
    completed.add(
      'native close event exactly once; NSWindowWillClose unchanged; tunnel remains ready',
    );
    nativeStep('window hidden');
    await desktop.showWindow();
    nativeStep('show window call returned');
    for (var i = 0; i < 30 && !await windowManager.isVisible(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    require(
      await windowManager.isVisible(),
      'tray show did not restore window',
    );
    completed.add('close-to-tray + window restore');
    await windowManager.hide();
    final repeatedMenu = await exerciseTray('exerciseTrayMenu');
    require(
      repeatedMenu['menuTrackingOpened'] == true &&
          repeatedMenu['manageActionSelected'] == true,
      'right menu stopped working after status update',
    );
    measurements['rightClickAfterConnect'] = repeatedMenu;
    final shownSnapshot = (await diagnostic.invokeMapMethod<String, dynamic>(
      'snapshot',
    ))!;
    require(
      shownSnapshot['activationPolicy'] == 1,
      'showing management GUI restored Dock',
    );
    completed.add(
      'right-click menu works again after SSH status updates; Dock remains absent',
    );
    nativeStep('large transfer');
    final largeSocket = await Socket.connect(
      InternetAddress.loopbackIPv4,
      listenPort,
    );
    final largeInput = StreamIterator<List<int>>(largeSocket);
    var pending = <int>[];
    final uploadClock = Stopwatch()..start();
    const rounds =
        512; // 32 MiB with a response before FIN, not a single bulk close.
    try {
      for (var round = 0; round < rounds; round++) {
        final chunk = List<int>.generate(64 * 1024, (i) => (i + round) % 251);
        largeSocket.add(chunk);
        await largeSocket.flush().timeout(const Duration(seconds: 15));
        while (pending.length < chunk.length) {
          require(
            await largeInput.moveNext().timeout(const Duration(seconds: 15)),
            'large transfer early EOF',
          );
          pending.addAll(largeInput.current);
        }
        for (var i = 0; i < chunk.length; i++) {
          require(pending[i] == chunk[i], 'large transfer byte mismatch');
        }
        pending = pending.sublist(chunk.length);
      }
    } finally {
      largeSocket.destroy();
      await largeInput.cancel();
    }
    uploadClock.stop();
    measurements['largeTransfer'] = {
      'bytes': rounds * 64 * 1024,
      'rounds': rounds,
      'milliseconds': uploadClock.elapsedMilliseconds,
      'matched': true,
    };
    require(
      engine.status.phase == TunnelPhase.ready,
      'large transfer broke tunnel',
    );
    completed.add(
      '32 MiB native sandbox SSH interactive transfer matched before FIN',
    );
    nativeStep('before disconnect');
    await controller.disconnect();
    await requireTrayColor('red');
    nativeStep('disconnect complete');
    final rebound = await ServerSocket.bind(
      InternetAddress.loopbackIPv4,
      listenPort,
    );
    await rebound.close();
    final secondRebound = await ServerSocket.bind('127.0.0.1', secondPort);
    await secondRebound.close();
    completed.add('disconnect releases both isolated local listeners');
    stage = 'autoconnect';
    nativeStep(stage);
    nativeStep('before shell cleanup');
    await desktop.prepareForExit();
    nativeStep('shell cleanup complete');
    controller.dispose();
    desktop = null;
    controller = null;
    final next = SshTunnelEngine(
      trustStore: trust,
      timing: const TunnelTiming(
        healthInterval: Duration(seconds: 60),
        maxRetries: 0,
      ),
    );
    controller = AppController(
      repository: repository,
      secrets: secrets,
      engine: next,
    );
    await controller.initialize().timeout(const Duration(seconds: 30));
    require(
      next.status.phase == TunnelPhase.ready,
      'saved default did not autoconnect',
    );
    require(controller.pendingTrust == null, 'saved pin prompted again');
    completed.add(
      'new controller reloads default and Keychain password + auto-connect without host prompt',
    );
    await controller.shutdown();
    controller.dispose();
    controller = null;
  } catch (error) {
    failed = true;
    // Never print raw platform/SSH exceptions or credential data.
    stdout.writeln(
      'PORTLINK_NATIVE_SMOKE_FAILURE ${jsonEncode({'stage': stage, 'errorType': error.runtimeType.toString(), 'assertion': error is StateError ? error.message.toString() : null, 'tunnelStatus': status})}',
    );
  } finally {
    try {
      await desktop?.prepareForExit();
      await controller?.shutdown();
      controller?.dispose();
    } catch (_) {
      failed = true;
    }
    try {
      await secrets.deletePassword(runId);
      require(
        await secrets.readPassword(runId) == null,
        'keychain cleanup mismatch',
      );
      completed.add('native Keychain fixture key deleted');
    } catch (_) {
      failed = true;
    }
    try {
      await guard?.release();
      if (temporary != null) await temporary.delete(recursive: true);
    } catch (_) {
      failed = true;
    }
    stdout.writeln(
      'PORTLINK_NATIVE_SMOKE ${jsonEncode({'success': !failed, 'checks': completed, 'measurements': measurements, 'localPort': 'isolated ephemeral; production remains 3080', 'server': 'isolated local SSH fixture; not user server'})}',
    );
    await stdout.flush();
    // AppKit does not preserve exitCode reliably; the harness requires the
    // explicit terminal JSON above, never just the process return code.
    await ServicesBinding.instance.exitApplication(AppExitType.required);
  }
}
