import 'package:flutter_test/flutter_test.dart';
import 'package:portlink/core/forward_rule.dart';
import 'package:portlink/core/server_profile.dart';
import 'package:portlink/core/tunnel_status.dart';
import 'package:portlink/platform/desktop_integration.dart';

ForwardRule rule(
  String id, {
  int local = 8080,
  int remote = 80,
  String bind = '127.0.0.1',
  String target = '127.0.0.1',
  bool enabled = true,
  String? label,
}) => ForwardRule(
  id: id,
  label: label ?? id,
  localPort: local,
  remotePort: remote,
  bindHost: bind,
  targetHost: target,
  enabled: enabled,
);

void main() {
  group('ForwardRule validation', () {
    test('accepts ordinary rules and custom hosts', () {
      expect(rule('a').validate(), isNull);
      expect(rule('a', bind: '0.0.0.0').validate(), isNull);
      expect(rule('a', bind: '192.168.1.20').validate(), isNull);
      expect(rule('a', target: '10.0.0.5').validate(), isNull);
      expect(rule('a', target: 'db.internal').validate(), isNull);
      expect(rule('a', target: '::1').validate(), isNull);
    });

    test('rejects privileged local ports and out-of-range ports', () {
      expect(rule('a', local: 80).validate(), isNotNull);
      expect(rule('a', local: 1023).validate(), isNotNull);
      expect(rule('a', local: 1024).validate(), isNull);
      expect(rule('a', local: 65536).validate(), isNotNull);
      expect(rule('a', remote: 0).validate(), isNotNull);
      expect(rule('a', remote: 65536).validate(), isNotNull);
      expect(rule('a', remote: 22).validate(), isNull);
    });

    test('the listen address must be a literal IPv4 address', () {
      for (final bad in ['localhost', 'example.com', '::1', '', '999.1.1.1']) {
        expect(rule('a', bind: bad).validate(), isNotNull, reason: bad);
      }
    });

    test('target host cannot smuggle a scheme, path, whitespace or userinfo', () {
      for (final bad in [
        'http://x',
        'a b',
        'a/b',
        'user@host',
        '',
        ' x',
        'a?b',
      ]) {
        expect(rule('a', target: bad).validate(), isNotNull, reason: bad);
      }
    });

    test('labels are bounded and free of control characters', () {
      expect(rule('a', label: '').validate(), isNotNull);
      expect(rule('a', label: 'x' * 41).validate(), isNotNull);
      expect(rule('a', label: 'bad\nlabel').validate(), isNotNull);
      expect(rule('a', label: ' padded').validate(), isNotNull);
    });

    test('loopback detection distinguishes network exposure', () {
      expect(rule('a').exposesToNetwork, isFalse);
      expect(rule('a', bind: '127.0.0.2').exposesToNetwork, isFalse);
      expect(rule('a', bind: '0.0.0.0').exposesToNetwork, isTrue);
      expect(rule('a', bind: '192.168.1.20').exposesToNetwork, isTrue);
    });
  });

  group('rule set validation', () {
    test('needs at least one enabled rule and is size-bounded', () {
      expect(ForwardRule.validateAll([]), isNotNull);
      expect(
        ForwardRule.validateAll([rule('a', enabled: false)]),
        isNotNull,
      );
      expect(
        ForwardRule.validateAll([
          for (var i = 0; i < ForwardRule.maxRules + 1; i++)
            rule('r$i', local: 2000 + i),
        ]),
        isNotNull,
      );
      expect(
        ForwardRule.validateAll([
          for (var i = 0; i < ForwardRule.maxRules; i++)
            rule('r$i', local: 2000 + i),
        ]),
        isNull,
      );
    });

    test('duplicate ids and clashing local ports are rejected', () {
      expect(ForwardRule.validateAll([rule('a'), rule('a', local: 9000)]), isNotNull);
      expect(ForwardRule.validateAll([rule('a'), rule('b')]), isNotNull);
      expect(
        ForwardRule.validateAll([rule('a'), rule('b', local: 9000)]),
        isNull,
      );
    });

    test('the same port on different loopback addresses is allowed', () {
      expect(
        ForwardRule.validateAll([
          rule('a', bind: '127.0.0.1'),
          rule('b', bind: '127.0.0.2'),
        ]),
        isNull,
      );
    });

    test('0.0.0.0 overlaps every address on that port', () {
      expect(
        ForwardRule.validateAll([
          rule('a', bind: '0.0.0.0'),
          rule('b', bind: '127.0.0.1'),
        ]),
        isNotNull,
      );
    });

    test('a disabled rule does not reserve its port', () {
      expect(
        ForwardRule.validateAll([rule('a'), rule('b', enabled: false)]),
        isNull,
      );
    });
  });

  group('JSON and migration', () {
    test('rules round-trip and reject unknown or mistyped fields', () {
      final r = rule('a', bind: '0.0.0.0', target: 'db.internal', local: 9000);
      expect(ForwardRule.fromJson(r.toJson()).toJson(), r.toJson());
      expect(
        () => ForwardRule.fromJson({...r.toJson(), 'extra': 1}),
        throwsFormatException,
      );
      expect(
        () => ForwardRule.fromJson({...r.toJson(), 'localPort': '9000'}),
        throwsFormatException,
      );
      expect(
        () => ForwardRule.fromJson({...r.toJson(), 'localPort': 80}),
        throwsFormatException,
      );
    });

    test('a v1 profile without rules upgrades to the legacy 3080 rule', () {
      final profile = ServerProfile.fromJson({
        'id': 'one',
        'name': '旧配置',
        'host': 'example.com',
        'sshPort': 22,
        'username': 'alice',
      });
      final only = profile.rules.single;
      expect([only.localPort, only.remotePort], [3080, 3080]);
      expect([only.bindHost, only.targetHost], ['127.0.0.1', '127.0.0.1']);
      expect(only.enabled, isTrue);
    });

    test('a profile with rules round-trips through JSON', () {
      final profile = ServerProfile(
        id: 'one',
        name: '多端口',
        host: 'example.com',
        username: 'alice',
        rules: [rule('a'), rule('b', local: 9000, remote: 5432)],
      );
      final again = ServerProfile.fromJson(profile.toJson());
      expect(again.toJson(), profile.toJson());
      expect(again.rules.length, 2);
    });

    test('a stored profile with invalid rules is rejected', () {
      expect(
        () => ServerProfile.fromJson({
          'id': 'one',
          'name': 'x',
          'host': 'example.com',
          'sshPort': 22,
          'username': 'alice',
          'rules': <Object?>[],
        }),
        throwsFormatException,
      );
    });
  });

  group('tray icon colour', () {
    RuleStatus s(String id, RuleState state) =>
        RuleStatus(rule: rule(id, local: 9000 + id.codeUnitAt(0)), state: state);
    TunnelStatus status(TunnelPhase phase, [List<RuleStatus> rules = const []]) =>
        TunnelStatus(phase: phase, rules: rules);

    test('green only when connected and every rule is usable', () {
      expect(
        DesktopIntegration.trayIconFor(
          status(TunnelPhase.ready, [s('a', RuleState.ready)]),
        ),
        'ready',
      );
      expect(
        DesktopIntegration.trayIconFor(
          status(TunnelPhase.ready, [
            s('a', RuleState.ready),
            s('b', RuleState.ready),
          ]),
        ),
        'ready',
      );
    });

    test('red when not connected or failed', () {
      expect(DesktopIntegration.trayIconFor(status(TunnelPhase.idle)), 'failed');
      expect(DesktopIntegration.trayIconFor(status(TunnelPhase.failed)), 'failed');
    });

    test('yellow while connecting or only partially usable', () {
      for (final phase in [
        TunnelPhase.connecting,
        TunnelPhase.verifyingHost,
        TunnelPhase.reconnecting,
        TunnelPhase.targetUnavailable,
      ]) {
        expect(DesktopIntegration.trayIconFor(status(phase)), 'pending');
      }
      expect(
        DesktopIntegration.trayIconFor(
          status(TunnelPhase.ready, [
            s('a', RuleState.ready),
            s('b', RuleState.bindFailed),
          ]),
        ),
        'pending',
      );
      expect(
        DesktopIntegration.trayIconFor(
          status(TunnelPhase.ready, [
            s('a', RuleState.ready),
            s('b', RuleState.targetUnavailable),
          ]),
        ),
        'pending',
      );
    });
  });
}
