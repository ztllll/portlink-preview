import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:portlink/core/server_profile.dart';
import 'package:portlink/core/tunnel_status.dart';
import 'package:portlink/ui/portlink_app.dart';

import 'fake_app_controller.dart';

/// Opt-in documentation captures of the real Flutter widget tree.
/// The controller is simulated: these images are not evidence of a live tunnel.
///
/// Run from the application directory with:
/// PORTLINK_CAPTURE_PREVIEW=1 PORTLINK_PREVIEW_FONT=/absolute/path/to/font.ttf
/// flutter test test/ui/preview_capture_test.dart
void main() {
  final captureEnabled =
      Platform.environment['PORTLINK_CAPTURE_PREVIEW'] == '1';

  testWidgets(
    'capture simulated configuration previews from real Flutter rendering',
    (tester) async {
      final fontPath = Platform.environment['PORTLINK_PREVIEW_FONT'];
      expect(
        fontPath,
        isNot(isEmpty),
        reason: 'Set PORTLINK_PREVIEW_FONT to a readable Chinese font file.',
      );
      if (fontPath == null || fontPath.isEmpty) {
        fail(
          'PORTLINK_PREVIEW_FONT is required when preview capture is enabled.',
        );
      }

      await tester.runAsync(() async {
        final bytes = await File(fontPath).readAsBytes();
        final data = ByteData.sublistView(bytes);
        // Override the test-only Ahem default and provide our theme fallback.
        for (final family in ['Roboto', 'PingFang SC', 'monospace']) {
          final loader = FontLoader(family)..addFont(Future.value(data));
          await loader.load();
        }
        final icons = FontLoader('MaterialIcons')
          ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
        await icons.load();
      });

      const work = ServerProfile(
        id: 'preview-work',
        name: '工作服务器',
        host: 'work.example.com',
        username: 'alice',
      );
      const home = ServerProfile(
        id: 'preview-home',
        name: '个人服务器',
        host: 'home.example.com',
        username: 'alice',
        sshPort: 2222,
      );
      final controller = FakeAppController()
        ..profiles = [work, home]
        ..defaultProfileId = work.id
        ..activeProfile = work
        ..tunnelStatus = const TunnelStatus(
          phase: TunnelPhase.ready,
          profileId: 'preview-work',
        );
      addTearDown(controller.dispose);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.light;
      tester.view.devicePixelRatio = 1;

      for (final capture in const {
        'desktop': Size(1280, 900),
        // A tall mobile-width viewport shows the scrollable server list too.
        'mobile': Size(390, 1440),
      }.entries) {
        tester.view.physicalSize = capture.value;
        final boundaryKey = GlobalKey();
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundaryKey,
            child: PortLinkApp(controller: controller),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(controller.connectedIds, isEmpty);
        expect(controller.initializeCalls, 0);
        final boundary =
            boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final output = File('docs/screenshots/${capture.key}.png');
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 2);
          try {
            final png = await image.toByteData(format: ui.ImageByteFormat.png);
            if (png == null) fail('Flutter returned no PNG bytes.');
            await output.parent.create(recursive: true);
            await output.writeAsBytes(
              png.buffer.asUint8List(png.offsetInBytes, png.lengthInBytes),
              flush: true,
            );
          } finally {
            image.dispose();
          }
        });
        debugPrint('${output.path}: 模拟配置界面预览，非真实服务器连接');
      }
      await tester.pumpWidget(const SizedBox.shrink());
    },
    skip: !captureEnabled,
  );
}
