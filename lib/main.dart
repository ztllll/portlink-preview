import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'app_controller.dart';
import 'core/tunnel_engine.dart';
import 'data/host_trust_store.dart';
import 'data/profile_repository.dart';
import 'data/secret_store.dart';
import 'platform/android_session.dart';
import 'platform/desktop_integration.dart';
import 'ui/portlink_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Never print raw framework/platform exceptions: transport errors may include
  // host identifiers, and library trace output must not expose credentials.
  FlutterError.onError = (details) {
    FlutterError.presentError(
      FlutterErrorDetails(
        exception: '应用界面发生错误，请重新打开窗口或重启应用。',
        library: 'PortLink',
      ),
    );
  };
  try {
    final directory = await getApplicationSupportDirectory();
    await directory.create(recursive: true);
    final android = AndroidSession();
    await android.initialize();
    final controller = AppController(
      repository: JsonProfileRepository(
        path.join(directory.path, 'profiles.json'),
      ),
      secrets: SecureSecretStore(),
      engine: SshTunnelEngine(
        trustStore: JsonHostTrustStore(
          path.join(directory.path, 'known_hosts.json'),
        ),
      ),
      startSession: android.start,
      stopSession: android.stop,
    );
    android.setStopHandler(controller.disconnect);
    runApp(PortLinkApp(controller: controller));
    DesktopIntegration? desktop;
    if (DesktopIntegration.isDesktop) {
      desktop = DesktopIntegration(controller);
      await desktop.initialize();
    }
    // Render first so first-use trust confirmation is visible during autoconnect.
    await controller.initialize();
    await desktop?.finishStartup();
  } catch (_) {
    runApp(const _StartupFailure());
  }
}

class _StartupFailure extends StatelessWidget {
  const _StartupFailure();
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: '端口连 PortLink',
    home: Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 42),
              const SizedBox(height: 20),
              Text('无法初始化应用', style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 12),
              const Text(
                '请检查应用数据目录与系统权限后重新启动。\n不会使用明文方式保存密码。',
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
