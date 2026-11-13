// A small, language-tolerant tokenizer for code blocks in notes. Ported from
// `util/code_highlight.dart`.
//
// Not a parser: it colours what reads the same across most languages
// (comments, strings, numbers, keywords, types, calls) and leaves the rest
// plain. Wrong guesses cost a colour, never text: the tokens always
// concatenate back to the source.

export type CodeTokenKind = "plain" | "keyword" | "string" | "number" | "comment" | "type" | "call";

export interface CodeToken {
  readonly text: string;
  readonly kind: CodeTokenKind;
}

/** Languages whose line comments start with `#`. */
const HASH_COMMENT_LANGUAGES = new Set([
  "bash", "sh", "shell", "zsh", "python", "py", "ruby", "rb", "yaml", "yml", "toml", "perl", "r",
  "dockerfile", "make", "makefile", "ini", "conf", "nix", "elixir",
]);

/** Languages whose line comments start with `--`. */
const DASH_COMMENT_LANGUAGES = new Set(["sql", "lua", "haskell", "hs", "elm"]);

/**
 * Keywords common to the languages people paste into notes. A union rather
 * than per-language tables: a Rust `fn` coloured in a Python block is the
 * whole cost of sharing it.
 */
const KEYWORDS = new Set([
  "abstract", "and", "as", "async", "await", "break", "case", "catch",
  "class", "const", "continue", "def", "default", "defer", "del", "do",
  "elif", "else", "enum", "except", "export", "extends", "extern", "false",
  "final", "finally", "fn", "for", "from", "func", "function", "go", "if",
  "impl", "implements", "import", "in", "interface", "is", "lambda", "late",
  "let", "loop", "match", "mod", "module", "mut", "new", "nil", "none",
  "None", "not", "null", "or", "override", "package", "pass", "private",
  "protected", "pub", "public", "raise", "required", "return", "select",
  "self", "Self", "static", "struct", "super", "switch", "this", "throw",
  "trait", "true", "True", "False", "try", "type", "typedef", "undefined",
  "unsafe", "use", "val", "var", "void", "where", "while", "with", "yield",
  "then", "fi", "done", "esac", "echo", "local", "readonly",
  // SQL, which people write in either case.
  "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE", "SET",
  "DELETE", "CREATE", "TABLE", "JOIN", "LEFT", "INNER", "ON", "GROUP", "BY",
  "ORDER", "LIMIT", "AND", "OR", "NOT", "NULL", "AS", "PRIMARY", "KEY",
]);

const IDENTIFIER = /[A-Za-z_$][A-Za-z0-9_$]*/y;
const NUMBER = /0[xX][0-9a-fA-F_]+|\d[\d_]*(\.\d[\d_]*)?([eE][+-]?\d+)?/y;
const WORD_CHAR = /[A-Za-z0-9_$.]/;
const UPPER_A = 0x41;
const UPPER_Z = 0x5a;

function matchAt(pattern: RegExp, source: string, index: number): string | null {
  pattern.lastIndex = index;
  return pattern.exec(source)?.[0] ?? null;
}

const isDigit = (char: string): boolean => char >= "0" && char <= "9";

/** Whether the character at [i] begins a word: nothing alphanumeric right before it. */
function startsWord(source: string, i: number, allowSymbols = false): boolean {
  if (i === 0) {
    return true;
  }
  const before = source[i - 1] ?? "";
  if (allowSymbols) {
    return !WORD_CHAR.test(before);
  }
  return before === " " || before === "\t" || before === "\n";
}

/**
 * The index just past the string opening at [start]. An ordinary quote also
 * ends at a newline, so one stray apostrophe cannot paint the whole block.
 */
function stringEnd(source: string, start: number): number {
  const quote = source[start];
  let i = start + 1;
  while (i < source.length) {
    const char = source[i];
    if (char === "\\") {
      i += 2;
      continue;
    }
    if (char === quote) {
      return i + 1;
    }
    if (char === "\n" && quote !== "`") {
      return i;
    }
    i++;
  }
  return source.length;
}

function wordKind(source: string, word: string, end: number): CodeTokenKind {
  if (KEYWORDS.has(word)) {
    return "keyword";
  }
  // A name followed by `(` is a call or a definition.
  let next = end;
  while (next < source.length && source[next] === " ") {
    next++;
  }
  if (source[next] === "(") {
    return "call";
  }
  // Capitalised names are types by the convention most languages share.
  const first = word.charCodeAt(0);
  if (first >= UPPER_A && first <= UPPER_Z && word.length > 1) {
    return "type";
  }
  return "plain";
}

/** Splits [source] into coloured runs; [language] is the fence's info string. */
export function highlightCode(source: string, language = ""): CodeToken[] {
  const lang = language.trim().toLowerCase();
  const hashComments = HASH_COMMENT_LANGUAGES.has(lang) || lang === "";
  const dashComments = DASH_COMMENT_LANGUAGES.has(lang);
  const slashComments = !HASH_COMMENT_LANGUAGES.has(lang);

  const tokens: CodeToken[] = [];
  let plain = "";
  const emit = (text: string, kind: CodeTokenKind): void => {
    if (plain) {
      tokens.push({ text: plain, kind: "plain" });
      plain = "";
    }
    tokens.push({ text, kind });
  };

  let i = 0;
  while (i < source.length) {
    const char = source[i] ?? "";

    const lineComment =
      (slashComments && source.startsWith("//", i)) ||
      (dashComments && source.startsWith("--", i)) ||
      (hashComments && char === "#" && startsWord(source, i));
    if (lineComment) {
      const end = source.indexOf("\n", i);
      const stop = end < 0 ? source.length : end;
      emit(source.slice(i, stop), "comment");
      i = stop;
      continue;
    }

    if (slashComments && source.startsWith("/*", i)) {
      const end = source.indexOf("*/", i + 2);
      const stop = end < 0 ? source.length : end + 2;
      emit(source.slice(i, stop), "comment");
      i = stop;
      continue;
    }

    if (char === '"' || char === "'" || char === "`") {
      const stop = stringEnd(source, i);
      emit(source.slice(i, stop), "string");
      i = stop;
      continue;
    }

    if (isDigit(char) && startsWord(source, i, true)) {
      const number = matchAt(NUMBER, source, i) ?? char;
      emit(number, "number");
      i += number.length;
      continue;
    }

    const word = matchAt(IDENTIFIER, source, i);
    if (word) {
      emit(word, wordKind(source, word, i + word.length));
      i += word.length;
      continue;
    }

    plain += char;
    i++;
  }

  if (plain) {
    tokens.push({ text: plain, kind: "plain" });
  }
  return tokens;
}
