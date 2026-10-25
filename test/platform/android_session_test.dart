import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:portlink/platform/android_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.portlink/session');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late AndroidSession session;
  late List<String> calls;
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    session = AndroidSession();
    calls = [];
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      return null;
    });
  });
  tearDown(() async {
    await session.dispose();
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });
  Future<Object?> nativeStop() async {
    final response = Completer<ByteData?>();
    messenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        const MethodCall('stopRequested'),
      ),
      response.complete,
    );
    final bytes = await response.future;
    return bytes == null
        ? null
        : const StandardMethodCodec().decodeEnvelope(bytes);
  }

  test('desktop adapter never invokes Android platform channel', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    await session.initialize();
    await session.start();
    await session.stop();
    expect(calls, isEmpty);
  });
  test('concurrent initialization is one platform request', () async {
    await Future.wait([session.initialize(), session.initialize()]);
    expect(calls, ['initialize']);
  });
  test(
    'no tunnel session may start without a registered stop handler',
    () async {
      await expectLater(session.start(), throwsStateError);
      expect(calls, ['initialize']);
    },
  );
  test(
    'concurrent starts wait for actual foreground confirmation once',
    () async {
      final gate = Completer<void>();
      session.setStopHandler(() async {});
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'start') await gate.future;
        return null;
      });
      var complete = false;
      final one = session.start().then((_) {
        complete = true;
      });
      final two = session.start();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      expect(complete, isFalse);
      expect(calls, ['initialize', 'start']);
      gate.complete();
      await Future.wait([one, two]);
    },
  );
  test('native stop acknowledges only completed actual disconnect', () async {
    final gate = Completer<void>();
    var stops = 0;
    session.setStopHandler(() async {
      stops++;
      await gate.future;
    });
    await session.start();
    var replied = false;
    final stop = nativeStop().then((r) {
      replied = true;
      return r;
    });
    await Future<void>.delayed(const Duration(milliseconds: 5));
    expect(replied, isFalse);
    expect(stops, 1);
    gate.complete();
    expect(await stop, isTrue);
  });
  test(
    'failed disconnect returns false so native watchdog can close isolate',
    () async {
      session.setStopHandler(() async {
        throw StateError('private failure');
      });
      await session.start();
      expect(await nativeStop(), isFalse);
    },
  );
  test(
    'notification permission and FGS errors propagate without fallback',
    () async {
      session.setStopHandler(() async {});
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'start') {
          throw PlatformException(code: 'notifications_disabled');
        }
        return null;
      });
      await expectLater(session.start(), throwsA(isA<PlatformException>()));
      expect(calls, ['initialize', 'start']);
    },
  );
  test(
    'native stop without handler is never acknowledged as disconnected',
    () async {
      await session.initialize();
      expect(await nativeStop(), isFalse);
    },
  );

  test('duplicate native stops share one pending disconnect', () async {
    final gate = Completer<void>();
    var stops = 0;
    session.setStopHandler(() async {
      stops++;
      await gate.future;
    });
    await session.start();
    final one = nativeStop();
    final two = nativeStop();
    await Future<void>.delayed(Duration.zero);
    expect(stops, 1);
    gate.complete();
    expect(await Future.wait([one, two]), [true, true]);
  });

  test(
    'native disconnect may call session stop without a channel deadlock',
    () async {
      session.setStopHandler(session.stop);
      await session.start();
      expect(await nativeStop(), isTrue);
      expect(calls, ['initialize', 'start', 'stop']);
    },
  );

  test(
    'failed initialization can retry and restore native stop callback',
    () async {
      var attempts = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'initialize' && ++attempts == 1) {
          throw PlatformException(code: 'engine_unavailable');
        }
        return null;
      });
      session.setStopHandler(() async {});
      await expectLater(session.start(), throwsA(isA<PlatformException>()));
      expect(await nativeStop(), isNull);
      await session.start();
      expect(await nativeStop(), isTrue);
      expect(calls, ['initialize', 'initialize', 'start']);
    },
  );

  test('stop while initializing prevents the delayed platform start', () async {
    final gate = Completer<void>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'initialize') await gate.future;
      return null;
    });
    session.setStopHandler(() async {});
    final start = expectLater(
      session.start(),
      throwsA(
        isA<PlatformException>().having((e) => e.code, 'code', 'cancelled'),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    await session.stop();
    gate.complete();
    await start;
    expect(calls, ['initialize']);
  });

  test('late foreground ack cannot complete a cancelled Dart start', () async {
    final gate = Completer<void>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'start') await gate.future;
      return null;
    });
    session.setStopHandler(() async {});
    final start = expectLater(
      session.start(),
      throwsA(
        isA<PlatformException>().having((e) => e.code, 'code', 'cancelled'),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    await session.stop();
    gate.complete();
    await start;
    expect(calls, ['initialize', 'start', 'stop']);
  });

  test(
    'new start does not reuse the previous cancelled platform operation',
    () async {
      final firstGate = Completer<void>();
      var starts = 0;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'start' && ++starts == 1) await firstGate.future;
        return null;
      });
      session.setStopHandler(() async {});
      final oldStart = expectLater(
        session.start(),
        throwsA(isA<PlatformException>()),
      );
      await Future<void>.delayed(Duration.zero);
      await session.stop();
      await session.start();
      firstGate.complete();
      await oldStart;
      expect(starts, 2);
    },
  );

  test(
    'dispose rejects restart while native cleanup is still pending',
    () async {
      final gate = Completer<void>();
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'stop') await gate.future;
        return null;
      });
      session.setStopHandler(() async {});
      await session.start();
      final disposal = session.dispose();
      try {
        await expectLater(session.start(), throwsStateError);
        await expectLater(session.initialize(), throwsStateError);
        expect(() => session.setStopHandler(() async {}), throwsStateError);
        expect(await nativeStop(), isFalse);
        expect(calls, ['initialize', 'start', 'stop']);
      } finally {
        gate.complete();
        await disposal;
      }
      expect(await nativeStop(), isNull);
    },
  );

  test(
    'disposed session cannot restart and unregisters its callback',
    () async {
      session.setStopHandler(() async {});
      await session.start();
      await session.dispose();
      await expectLater(session.start(), throwsStateError);
      expect(calls, ['initialize', 'start', 'stop']);
      expect(await nativeStop(), isNull);
    },
  );
}
