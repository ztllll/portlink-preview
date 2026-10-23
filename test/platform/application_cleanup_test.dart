import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:portlink/platform/application_cleanup.dart';

void main() {
  test('simultaneous exit paths share ordered cleanup once', () async {
    final gate = Completer<void>();
    final calls = <String>[];
    final cleanup = ApplicationCleanup([
      () async {
        calls.add('engine');
        await gate.future;
      },
      () async {
        calls.add('service');
      },
      () async {
        calls.add('lock');
      },
    ]);
    final one = cleanup.run();
    final two = cleanup.run();
    expect(identical(one, two), isTrue);
    expect(calls, ['engine']);
    gate.complete();
    await Future.wait([one, two]);
    await cleanup.run();
    expect(calls, ['engine', 'service', 'lock']);
  });
  test(
    'startup cleanup continues releasing session and lock after engine failure',
    () async {
      final calls = <String>[];
      final cleanup = ApplicationCleanup([
        () async {
          calls.add('engine');
          throw StateError('private-error');
        },
        () async {
          calls.add('service');
          throw StateError('secondary-error');
        },
        () async {
          calls.add('lock');
        },
      ]);
      await expectLater(cleanup.run(), throwsStateError);
      expect(calls, ['engine', 'service', 'lock']);
      await expectLater(cleanup.run(), throwsStateError);
      expect(calls.length, 3);
    },
  );
}
