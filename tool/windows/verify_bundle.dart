import 'dart:convert';
import 'dart:io';

import 'bundle_inspector.dart';

void main(List<String> arguments) {
  String argument(String name) {
    final index = arguments.indexOf(name);
    if (index < 0 || index + 1 >= arguments.length) {
      throw ArgumentError('Missing $name');
    }
    return arguments[index + 1];
  }

  try {
    final report = WindowsBundleInspector(
      bundle: Directory(argument('--bundle')),
      architecture: argument('--arch'),
      generatedPlugins: File(argument('--plugins')).readAsStringSync(),
    ).inspect();
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(report));
    exitCode = report['valid'] == true ? 0 : 2;
  } on Object catch (error) {
    stderr.writeln('Bundle inspection failed: $error');
    exitCode = 2;
  }
}
