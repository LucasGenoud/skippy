"use client";

// Placeholder: the EDITOR agent replaces these.
export function NoteEditor({ noteId, onClose }: { noteId: string; onClose(): void }) {
  return (
    <div data-placeholder="note-editor" data-note={noteId}>
      <button type="button" onClick={onClose}>
        Close
      </button>
    </div>
  );
}

export function HistoryScreen({ noteId, onClose }: { noteId: string; onClose(): void }) {
  return (
    <div data-placeholder="history" data-note={noteId}>
      <button type="button" onClick={onClose}>
        Close
      </button>
    </div>
  );
}
