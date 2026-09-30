import 'collection.dart';
import 'note.dart';
import 'saved_view.dart';

/// A container for notes and labels. Every account has one default workspace
/// and may create more; members are invited per workspace and see every note
/// it holds. Its labels are a shared taxonomy rather than personal ones.
class Workspace {
  final String id;
  final List<NoteCollection> collections;
  final List<SavedView> savedViews;
  final String name;
  final bool notesEnabled;
  final bool boardEnabled;

  /// Null only for a workspace created locally that hasn't round-tripped
  /// through the server yet.
  final UserRef? owner;

  /// Everyone invited, excluding the owner.
  final List<UserRef> members;

  /// The workspace created with the account. It can't be deleted or left, so
  /// notes always have somewhere to live.
  final bool isDefault;

  final WorkspaceAi ai;

  const Workspace({
    required this.id,
    this.collections = const [],
    this.savedViews = const [],
    required this.name,
    this.notesEnabled = true,
    this.boardEnabled = true,
    this.owner,
    this.members = const [],
    this.isDefault = false,
    this.ai = const WorkspaceAi(),
  });

  bool isOwnedBy(String? userId) => owner == null || owner!.id == userId;

  /// Whether anyone besides the owner is in it.
  bool get isShared => members.isNotEmpty;

  Workspace copyWith({
    List<NoteCollection>? collections,
    List<SavedView>? savedViews,
    String? name,
    bool? notesEnabled,
    bool? boardEnabled,
    List<UserRef>? members,
    WorkspaceAi? ai,
  }) => Workspace(
    id: id,
    collections: collections ?? this.collections,
    savedViews: savedViews ?? this.savedViews,
    name: name ?? this.name,
    notesEnabled: notesEnabled ?? this.notesEnabled,
    boardEnabled: boardEnabled ?? this.boardEnabled,
    owner: owner,
    members: members ?? this.members,
    isDefault: isDefault,
    ai: ai ?? this.ai,
  );

  factory Workspace.fromJson(Map<String, dynamic> json) => Workspace(
    id: json['id'] as String,
    collections: [
      for (final c
          in json['collections'] as List? ??
              [
                NoteCollection.general(
                  json['id'] as String,
                  layout: json['notes_enabled'] == false ? 'board' : 'masonry',
                ).toJson(),
              ])
        NoteCollection.fromJson((c as Map).cast<String, dynamic>()),
    ],
    savedViews: [
      for (final entry in json['smart_views'] as List? ?? const [])
        if (entry is Map<String, dynamic>)
          if (SavedView.fromJson(entry) case final SavedView view) view,
    ],
    name: json['name'] as String? ?? '',
    notesEnabled: json['notes_enabled'] as bool? ?? true,
    boardEnabled: json['board_enabled'] as bool? ?? true,
    owner: json['owner'] == null
        ? null
        : UserRef.fromJson(json['owner'] as Map<String, dynamic>),
    members: ((json['members'] as List?) ?? const [])
        .map((j) => UserRef.fromJson(j as Map<String, dynamic>))
        .toList(),
    isDefault: json['is_default'] as bool? ?? false,
    ai: WorkspaceAi.fromJson(json['ai']),
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'collections': [for (final c in collections) c.toJson()],
    'smart_views': [for (final view in savedViews) view.toJson()],
    'name': name,
    'notes_enabled': notesEnabled,
    'board_enabled': boardEnabled,
    'owner': owner?.toJson(),
    'members': [for (final m in members) m.toJson()],
    'is_default': isDefault,
    'ai': ai.toJson(),
  };
}

enum AiFeature { labeling, chat, writing }

/// What AI a workspace allows. Only the owner flips these, and every member
/// gets the same AI there. [enabled] gates the three features without
/// overwriting them, so turning AI back on restores what was on before.
class AiSwitches {
  final bool enabled;
  final bool labeling;
  final bool chat;
  final bool writing;

  /// Whether personal access tokens (MCP) may reach the workspace's notes.
  final bool assistantAccess;

  const AiSwitches({
    this.enabled = true,
    this.labeling = true,
    this.chat = true,
    this.writing = true,
    this.assistantAccess = true,
  });

  bool allows(AiFeature feature) =>
      enabled &&
      switch (feature) {
        AiFeature.labeling => labeling,
        AiFeature.chat => chat,
        AiFeature.writing => writing,
      };

  AiSwitches copyWith({
    bool? enabled,
    bool? labeling,
    bool? chat,
    bool? writing,
    bool? assistantAccess,
  }) => AiSwitches(
    enabled: enabled ?? this.enabled,
    labeling: labeling ?? this.labeling,
    chat: chat ?? this.chat,
    writing: writing ?? this.writing,
    assistantAccess: assistantAccess ?? this.assistantAccess,
  );

  /// A switch the payload leaves out is on, as it is on the server.
  factory AiSwitches.fromJson(Object? json) {
    final map = json is Map ? json : const {};
    return AiSwitches(
      enabled: map['enabled'] != false,
      labeling: map['labeling'] != false,
      chat: map['chat'] != false,
      writing: map['writing'] != false,
      assistantAccess: map['assistant_access'] != false,
    );
  }

  Map<String, dynamic> toJson() => {
    'enabled': enabled,
    'labeling': labeling,
    'chat': chat,
    'writing': writing,
    'assistant_access': assistantAccess,
  };

  @override
  bool operator ==(Object other) =>
      other is AiSwitches &&
      other.enabled == enabled &&
      other.labeling == labeling &&
      other.chat == chat &&
      other.writing == writing &&
      other.assistantAccess == assistantAccess;

  @override
  int get hashCode =>
      Object.hash(enabled, labeling, chat, writing, assistantAccess);
}

/// A workspace's AI as a member sees it. Everything runs on the owner's
/// provider, which never leaves the server: members learn only whether there
/// is one and what the owner's rewrite tasks are called, so each task here
/// has an empty prompt.
class WorkspaceAi {
  final AiSwitches switches;
  final bool providerReady;
  final List<NoteRewriteTask> rewriteTasks;

  const WorkspaceAi({
    this.switches = const AiSwitches(),
    this.providerReady = false,
    this.rewriteTasks = const [],
  });

  /// Whether [feature] runs here: switched on, with a provider to run it.
  bool allows(AiFeature feature) => providerReady && switches.allows(feature);

  WorkspaceAi copyWith({AiSwitches? switches}) => WorkspaceAi(
    switches: switches ?? this.switches,
    providerReady: providerReady,
    rewriteTasks: rewriteTasks,
  );

  factory WorkspaceAi.fromJson(Object? json) {
    final map = json is Map ? json : const {};
    return WorkspaceAi(
      switches: AiSwitches.fromJson(map),
      providerReady: map['provider_ready'] == true,
      rewriteTasks: [
        for (final task in map['rewrite_tasks'] as List? ?? const [])
          if (task case {'id': final String id, 'name': final String name})
            NoteRewriteTask(id: id, name: name, prompt: ''),
      ],
    );
  }

  Map<String, dynamic> toJson() => {
    ...switches.toJson(),
    'provider_ready': providerReady,
    'rewrite_tasks': [
      for (final task in rewriteTasks) {'id': task.id, 'name': task.name},
    ],
  };
}
