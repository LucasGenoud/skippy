// Keeps the app on its shared spacing and motion system: a stray padding or
// curve fails here instead of drifting in unnoticed.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Where spacing tokens are defined, so it alone may hold their raw values.
const String _tokenFile = 'lib/theme.dart';

/// Where motion tokens are defined.
const String _motionFile = 'lib/util/motion.dart';

/// The grid every literal spacing value sits on.
const double _grid = 4;

/// A number standing alone as an argument: `vertical: 6`, `(10)`, `? 9 : 0`.
/// Arithmetic such as `kSpaceHair / 2` is a derived value and passes.
final RegExp _literal = RegExp(r'(?:^|[(,:?])\s*(\d+(?:\.\d+)?)\s*(?=[,)]|$)');

final RegExp _insets = RegExp(r'EdgeInsets(?:Directional)?\.\w+\(');
final RegExp _gap = RegExp(r'SizedBox\((?:width|height):\s*([\d.]+)\s*\)');
final RegExp _wrap = RegExp(r'\b(?:spacing|runSpacing):\s*([\d.]+)\s*[,)]');
final RegExp _curve = RegExp(r'\bCurves\.\w+');
final RegExp _duration = RegExp(
  r'\b(?:duration|reverseDuration|transitionDuration|delay):\s*'
  r'(?:const\s+)?Duration\(',
);

List<File> _sources() =>
    Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

int _line(String source, int offset) =>
    '\n'.allMatches(source.substring(0, offset)).length + 1;

/// The arguments of the call whose opening parenthesis ends at [start].
String _arguments(String source, int start) {
  var depth = 1;
  var i = start;
  while (depth > 0 && i < source.length) {
    final char = source[i];
    if (char == '(') {
      depth++;
    } else if (char == ')') {
      depth--;
    }
    i++;
  }
  return source.substring(start, i - 1);
}

bool _offGrid(String arguments) => _literal
    .allMatches(arguments)
    .any((m) => double.parse(m.group(1)!) % _grid != 0);

void main() {
  test('spacing literals sit on the 4px grid or come from tokens', () {
    final offenders = <String>[];
    for (final file in _sources()) {
      if (file.path == _tokenFile) {
        continue;
      }

      final source = file.readAsStringSync();
      for (final match in _insets.allMatches(source)) {
        if (_offGrid(_arguments(source, match.end))) {
          offenders.add('${file.path}:${_line(source, match.start)}');
        }
      }
      for (final match in [
        ..._gap.allMatches(source),
        ..._wrap.allMatches(source),
      ]) {
        if (_offGrid('(${match.group(1)})')) {
          offenders.add('${file.path}:${_line(source, match.start)}');
        }
      }
    }
    expect(offenders, isEmpty, reason: 'use a kSpace token or name the value');
  });

  test('animations take their curves and durations from Motion', () {
    final offenders = <String>[];
    for (final file in _sources()) {
      if (file.path == _motionFile) {
        continue;
      }

      final source = file.readAsStringSync();
      for (final match in [
        ..._curve.allMatches(source),
        ..._duration.allMatches(source),
      ]) {
        offenders.add('${file.path}:${_line(source, match.start)}');
      }
    }
    expect(offenders, isEmpty, reason: 'use a Motion token');
  });
}
