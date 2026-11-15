import type { Label } from "@/lib/models/note";
import type { NoteCollection } from "@/lib/models/workspace";

// How a card draws a label or its collection marker (`note_card/labels.dart`):
// a name, a hex colour and an icon key, blanks read as unset. Compared by
// value, so a card re-renders only when one of its own labels changes.

export interface CardTag {
  readonly id: string;
  readonly name: string;
  readonly color: string | null;
  readonly icon: string | null;
}

const unlessBlank = (value: string | null | undefined): string | null => (value ? value : null);

export function tagOf(entity: Pick<Label, "id" | "name" | "color" | "icon"> | Pick<NoteCollection, "id" | "name" | "color" | "icon">): CardTag {
  return { id: entity.id, name: entity.name, color: unlessBlank(entity.color), icon: unlessBlank(entity.icon) };
}

/** The labels a card shows, sorted by name. */
export function cardTags(labelIds: readonly string[], labels: readonly Label[]): CardTag[] {
  if (labelIds.length === 0) {
    return [];
  }
  const tags: CardTag[] = [];
  for (const id of labelIds) {
    const label = labels.find((l) => l.id === id);
    if (label) {
      tags.push(tagOf(label));
    }
  }
  return tags.sort((a, b) => a.name.toLowerCase().localeCompare(b.name.toLowerCase()));
}

export function tagEqual(a: CardTag | null, b: CardTag | null): boolean {
  if (a === b) {
    return true;
  }
  if (!a || !b) {
    return false;
  }
  return a.id === b.id && a.name === b.name && a.color === b.color && a.icon === b.icon;
}

export function tagsEqual(a: readonly CardTag[], b: readonly CardTag[]): boolean {
  return a.length === b.length && a.every((tag, i) => tagEqual(tag, b[i] ?? null));
}
