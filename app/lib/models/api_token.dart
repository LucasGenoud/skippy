/// What a personal access token lets an AI client do. The wire values are
/// shared with the backend (`models.rs`, `TokenScope`).
enum TokenScope {
  read('read', 'Read only'),
  write('write', 'Read and add');

  final String wire;
  final String label;

  const TokenScope(this.wire, this.label);

  static TokenScope fromWire(String? value) =>
      value == write.wire ? write : read;
}

/// A token as its owner sees it listed. The secret is never part of it.
class ApiToken {
  final String id;
  final String name;
  final TokenScope scope;
  final DateTime createdAt;
  final DateTime? lastUsedAt;

  const ApiToken({
    required this.id,
    required this.name,
    required this.scope,
    required this.createdAt,
    this.lastUsedAt,
  });

  factory ApiToken.fromJson(Map<String, dynamic> json) => ApiToken(
    id: json['id'] as String,
    name: json['name'] as String? ?? '',
    scope: TokenScope.fromWire(json['scope'] as String?),
    createdAt:
        DateTime.tryParse(json['created_at'] as String? ?? '') ??
        DateTime.now(),
    lastUsedAt: DateTime.tryParse(json['last_used_at'] as String? ?? ''),
  );
}

/// A token just created: the one time its secret is shown.
class CreatedApiToken {
  final ApiToken token;
  final String secret;

  const CreatedApiToken({required this.token, required this.secret});

  factory CreatedApiToken.fromJson(Map<String, dynamic> json) =>
      CreatedApiToken(
        token: ApiToken.fromJson(json),
        secret: json['secret'] as String,
      );
}

/// Where an MCP client connects.
String mcpUrl(String baseUrl) =>
    '${baseUrl.replaceAll(RegExp(r'/+$'), '')}/api/mcp';

/// The command that adds this server to Claude Code.
String claudeCodeCommand(String baseUrl, String secret) =>
    'claude mcp add --transport http skippy ${mcpUrl(baseUrl)} '
    '--header "Authorization: Bearer $secret"';
