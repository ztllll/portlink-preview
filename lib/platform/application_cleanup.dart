/// Coordinates every graceful exit path, including partial startup failure.
/// Steps run exactly once and in order; later cleanup is attempted even if an
/// earlier step fails. Raw exceptions remain private to the caller.
final class ApplicationCleanup {
  ApplicationCleanup(this._steps);
  final List<Future<void> Function()> _steps;
  Future<void>? _operation;

  Future<void> run() => _operation ??= _run();
  Future<void> _run() async {
    Object? failure;
    StackTrace? stack;
    for (final step in _steps) {
      try {
        await step();
      } catch (error, trace) {
        failure ??= error;
        stack ??= trace;
      }
    }
    if (failure != null) Error.throwWithStackTrace(failure, stack!);
  }
}
