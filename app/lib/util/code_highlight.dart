/// A small, language-tolerant tokenizer for code blocks in notes.
///
/// Not a parser: it colours what reads the same across most languages
/// (comments, strings, numbers, keywords, types, calls) and leaves the rest
/// plain. Wrong guesses cost a colour, never text, because the tokens always
/// concatenate back to the source.
library;

enum CodeTokenKind { plain, keyword, string, number, comment, type, call }

typedef CodeToken = ({String text, CodeTokenKind kind});

/// Languages whose line comments start with `#`.
const _hashCommentLanguages = {
  'bash',
  'sh',
  'shell',
  'zsh',
  'python',
  'py',
  'ruby',
  'rb',
  'yaml',
  'yml',
  'toml',
  'perl',
  'r',
  'dockerfile',
  'make',
  'makefile',
  'ini',
  'conf',
  'nix',
  'elixir',
};

/// Languages whose line comments start with `--`.
const _dashCommentLanguages = {'sql', 'lua', 'haskell', 'hs', 'elm'};

/// Keywords common to the languages people paste into notes. A union rather
/// than per-language tables: a Rust `fn` coloured in a Python block is the
/// whole cost of sharing it.
const _keywords = {
  'abstract', 'and', 'as', 'async', 'await', 'break', 'case', 'catch', //
  'class', 'const', 'continue', 'def', 'default', 'defer', 'del', 'do',
  'elif', 'else', 'enum', 'except', 'export', 'extends', 'extern', 'false',
  'final', 'finally', 'fn', 'for', 'from', 'func', 'function', 'go', 'if',
  'impl', 'implements', 'import', 'in', 'interface', 'is', 'lambda', 'late',
  'let', 'loop', 'match', 'mod', 'module', 'mut', 'new', 'nil', 'none',
  'None', 'not', 'null', 'or', 'override', 'package', 'pass', 'private',
  'protected', 'pub', 'public', 'raise', 'required', 'return', 'select',
  'self', 'Self', 'static', 'struct', 'super', 'switch', 'this', 'throw',
  'trait', 'true', 'True', 'False', 'try', 'type', 'typedef', 'undefined',
  'unsafe', 'use', 'val', 'var', 'void', 'where', 'while', 'with', 'yield',
  'then', 'fi', 'done', 'esac', 'echo', 'local', 'readonly',
  // SQL, which people write in either case.
  'SELECT', 'FROM', 'WHERE', 'INSERT', 'INTO', 'VALUES', 'UPDATE', 'SET',
  'DELETE', 'CREATE', 'TABLE', 'JOIN', 'LEFT', 'INNER', 'ON', 'GROUP', 'BY',
  'ORDER', 'LIMIT', 'AND', 'OR', 'NOT', 'NULL', 'AS', 'PRIMARY', 'KEY',
};

final _identifier = RegExp(r'[A-Za-z_$][A-Za-z0-9_$]*');
final _number = RegExp(
  r'0[xX][0-9a-fA-F_]+|\d[\d_]*(\.\d[\d_]*)?([eE][+-]?\d+)?',
);

/// Splits [source] into coloured runs. [language] is the fence's info string
/// (`dart` in ```` ```dart ````), lower- or mixed-case, possibly empty.
List<CodeToken> highlightCode(String source, {String language = ''}) {
  final lang = language.trim().toLowerCase();
  final hashComments = _hashCommentLanguages.contains(lang) || lang.isEmpty;
  final dashComments = _dashCommentLanguages.contains(lang);
  final slashComments = !_hashCommentLanguages.contains(lang);

  final tokens = <CodeToken>[];
  final plain = StringBuffer();

  void emit(String text, CodeTokenKind kind) {
    if (plain.isNotEmpty) {
      tokens.add((text: plain.toString(), kind: CodeTokenKind.plain));
      plain.clear();
    }
    tokens.add((text: text, kind: kind));
  }

  var i = 0;
  while (i < source.length) {
    final char = source[i];

    // Line comments run to the end of the line.
    final lineComment =
        (slashComments && source.startsWith('//', i)) ||
        (dashComments && source.startsWith('--', i)) ||
        (hashComments && char == '#' && _startsWord(source, i));
    if (lineComment) {
      final end = source.indexOf('\n', i);
      final stop = end < 0 ? source.length : end;
      emit(source.substring(i, stop), CodeTokenKind.comment);
      i = stop;
      continue;
    }

    if (slashComments && source.startsWith('/*', i)) {
      final end = source.indexOf('*/', i + 2);
      final stop = end < 0 ? source.length : end + 2;
      emit(source.substring(i, stop), CodeTokenKind.comment);
      i = stop;
      continue;
    }

    if (char == '"' || char == "'" || char == '`') {
      final stop = _stringEnd(source, i);
      emit(source.substring(i, stop), CodeTokenKind.string);
      i = stop;
      continue;
    }

    if (_isDigit(char) && _startsWord(source, i, allowSymbols: true)) {
      final match = _number.matchAsPrefix(source, i)!;
      emit(match[0]!, CodeTokenKind.number);
      i = match.end;
      continue;
    }

    if (_identifier.matchAsPrefix(source, i) case final match?) {
      final word = match[0]!;
      emit(word, _wordKind(source, word, match.end));
      i = match.end;
      continue;
    }

    plain.write(char);
    i++;
  }

  if (plain.isNotEmpty) {
    tokens.add((text: plain.toString(), kind: CodeTokenKind.plain));
  }
  return tokens;
}

CodeTokenKind _wordKind(String source, String word, int end) {
  if (_keywords.contains(word)) {
    return CodeTokenKind.keyword;
  }

  // A name followed by `(` is a call or a definition.
  var next = end;
  while (next < source.length && source[next] == ' ') {
    next++;
  }
  if (next < source.length && source[next] == '(') {
    return CodeTokenKind.call;
  }

  // Capitalised names are types by the convention most languages share.
  final first = word.codeUnitAt(0);
  if (first >= 0x41 && first <= 0x5A && word.length > 1) {
    return CodeTokenKind.type;
  }
  return CodeTokenKind.plain;
}

/// The index just past the string opening at [start]. A quote or backtick
/// string ends at its matching unescaped delimiter; an ordinary quote also
/// ends at a newline, so one stray apostrophe cannot paint the whole block.
int _stringEnd(String source, int start) {
  final quote = source[start];
  var i = start + 1;
  while (i < source.length) {
    final char = source[i];
    if (char == '\\') {
      i += 2;
      continue;
    }
    if (char == quote) {
      return i + 1;
    }
    if (char == '\n' && quote != '`') {
      return i;
    }
    i++;
  }
  return source.length;
}

/// Whether the character at [i] begins a word: nothing alphanumeric sits
/// right before it. `x1` is a name, not `x` then the number `1`.
bool _startsWord(String source, int i, {bool allowSymbols = false}) {
  if (i == 0) {
    return true;
  }
  final before = source[i - 1];
  if (allowSymbols) {
    return !_isWordChar(before);
  }
  return before == ' ' || before == '\t' || before == '\n';
}

bool _isDigit(String char) {
  final unit = char.codeUnitAt(0);
  return unit >= 0x30 && unit <= 0x39;
}

bool _isWordChar(String char) =>
    _isDigit(char) || RegExp(r'[A-Za-z_$.]').hasMatch(char);
