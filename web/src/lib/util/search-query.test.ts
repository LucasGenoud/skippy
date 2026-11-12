import { describe, expect, it } from "vitest";
import { makeNote, type Attachment, type ChecklistItem, type Label, type Note } from "@/lib/models/note";
import { selectNotes } from "@/lib/state/note-collection";
import {
  cycleSearchFilter,
  filterToString,
  negateSearchFilter,
  parseSearchQuery,
  queryMatches,
  queryText,
  searchContext,
  searchQueryHas,
  tokenizeSearchQuery,
  toggleSearchFilter,
  unknownFilters,
} from "./search-query";

// Ported from `app/test/search_query_test.dart` (the parsing, toggling,
// matching and view-integration groups; the controller group is UI).

const created = new Date(2026, 0, 1);
const note = (id: string, fields: Partial<Note> & { ownerId?: string } = {}): Note => {
  const { ownerId = "me", ...rest } = fields;
  return makeNote({ id, owner: { id: ownerId, name: ownerId }, createdAt: created, updatedAt: created, ...rest });
};
const labels: Label[] = [
  { id: "l-work", workspaceId: "", name: "Work", color: null, icon: null, position: 0 },
  { id: "l-todo", workspaceId: "", name: "To do", color: null, icon: null, position: 0 },
];
const context = searchContext(labels);
const matches = (q: string, n: Note): boolean => queryMatches(parseSearchQuery(q), n, context);
const item = (id: string, text: string, done = false): ChecklistItem => ({ id, text, done, depth: 0 });
const attachment = (id: string, mime: string, ocrText = ""): Attachment => ({ id, mime, filename: "", size: 0, url: null, ocrText });

describe("parsing", () => {
  it("splits free text from operators", () => {
    const q = parseSearchQuery("milk label:work is:pinned eggs");
    expect(q.terms.map((t) => t.text)).toEqual(["milk", "eggs"]);
    expect(q.filters).toEqual([
      { field: "label", value: "work", negated: false },
      { field: "state", value: "pinned", negated: false },
    ]);
    expect(queryText(q)).toBe("milk eggs");
  });

  it("keeps quoted values together and strips the quotes", () => {
    const q = parseSearchQuery('label:"to do" "buy milk"');
    expect(q.filters[0]?.value).toBe("to do");
    expect(q.terms[0]?.text).toBe("buy milk");
  });

  it("reads a leading dash as negation on text and filters", () => {
    const q = parseSearchQuery("-is:pinned -milk");
    expect(q.filters[0]?.negated).toBe(true);
    expect(q.terms[0]).toEqual({ text: "milk", negated: true });
    expect(queryText(q)).toBe("");
  });

  it("reads a negative field spelling as the same filter as a dash", () => {
    const excluded = { field: "has", value: "link", negated: true };
    expect(parseSearchQuery("hasnot:link").filters).toEqual([excluded]);
    expect(parseSearchQuery("-has:link").filters).toEqual([excluded]);
    expect(parseSearchQuery("HasNot:Link").filters).toEqual([excluded]);
    expect(parseSearchQuery("notlabel:work").filters).toEqual([{ field: "label", value: "work", negated: true }]);
    expect(parseSearchQuery("nottype:audio").filters).toEqual([{ field: "kind", value: "audio", negated: true }]);
    expect(parseSearchQuery("-hasnot:link").filters[0]?.negated).toBe(false);
  });

  it("prints a filter the way a user could type it back", () => {
    expect(filterToString(parseSearchQuery("-has:link").filters[0] as never)).toBe("hasnot:link");
    expect(filterToString(parseSearchQuery("-tag:work").filters[0] as never)).toBe("notlabel:work");
  });

  it("leaves an unknown prefix as text so URLs keep matching", () => {
    const q = parseSearchQuery("https://example.com/x");
    expect(q.filters).toEqual([]);
    expect(q.terms[0]?.text).toBe("https://example.com/x");
  });

  it("accepts aliases and is case insensitive", () => {
    expect(parseSearchQuery("TAG:Work TYPE:Checklist").filters).toEqual([
      { field: "label", value: "work", negated: false },
      { field: "kind", value: "checklist", negated: false },
    ]);
  });

  it("reports operators it cannot satisfy", () => {
    expect(unknownFilters(parseSearchQuery("is:pinned"))).toEqual([]);
    expect(unknownFilters(parseSearchQuery("is:favourite has:sketch kind:drawing")).map((f) => f.value)).toEqual(["favourite", "sketch", "drawing"]);
    expect(unknownFilters(parseSearchQuery("label:nope"))).toEqual([]);
    expect(unknownFilters(parseSearchQuery("hasnot:sketch")).map(filterToString)).toEqual(["hasnot:sketch"]);
  });
});

describe("tokens and toggling", () => {
  it("carries source offsets, quotes included", () => {
    const query = 'milk label:"to do" eggs';
    const tokens = tokenizeSearchQuery(query);
    expect(tokens.map((t) => t.raw)).toEqual(["milk", 'label:"to do"', "eggs"]);
    expect(tokens.map((t) => t.filter !== null)).toEqual([false, true, false]);
    for (const token of tokens) {
      expect(query.slice(token.start, token.end)).toBe(token.raw);
    }
  });

  it("toggling adds a filter, then takes the same one back out", () => {
    let query = toggleSearchFilter("", "is:pinned");
    expect(query).toBe("is:pinned");
    query = toggleSearchFilter(query, "has:reminder");
    expect(query).toBe("is:pinned has:reminder");
    expect(searchQueryHas(query, "is:pinned")).toBe(true);
    expect(searchQueryHas(query, "is:open")).toBe(false);
    expect(toggleSearchFilter(query, "is:pinned")).toBe("has:reminder");
  });

  it("toggling leaves typed words exactly as typed", () => {
    const typed = 'Sourdough "Rye Bread" -Milk';
    const added = toggleSearchFilter(typed, "is:pinned");
    expect(added).toBe('Sourdough "Rye Bread" -Milk is:pinned');
    expect(toggleSearchFilter(added, "is:pinned")).toBe(typed);
  });

  it("negating rewrites the field, not the value", () => {
    expect(negateSearchFilter("has:link")).toBe("hasnot:link");
    expect(negateSearchFilter("hasnot:link")).toBe("has:link");
    expect(negateSearchFilter("-has:link")).toBe("has:link");
    expect(negateSearchFilter("color:red")).toBe("notcolor:red");
    expect(negateSearchFilter('label:"To do"')).toBe('notlabel:"To do"');
    expect(negateSearchFilter("milk")).toBe("milk");
    expect(negateSearchFilter("https://example.com")).toBe("https://example.com");
  });

  it("a chip cycles off, matching, excluding, off, rewriting in place", () => {
    let query = cycleSearchFilter("milk", "has:link");
    expect(query).toBe("milk has:link");
    query = cycleSearchFilter(query, "has:link");
    expect(query).toBe("milk hasnot:link");
    expect(cycleSearchFilter(query, "has:link")).toBe("milk");
    expect(cycleSearchFilter("is:pinned has:link kind:text", "has:link")).toBe("is:pinned hasnot:link kind:text");
    expect(cycleSearchFilter("-has:link", "has:link")).toBe("");
    expect(toggleSearchFilter("tag:work", "label:work")).toBe("");
  });
});

describe("matching", () => {
  it("label: resolves the name, with none/any for the edges", () => {
    const labelled = note("a", { labelIds: ["l-work"] });
    const bare = note("b");
    expect(matches("label:work", labelled)).toBe(true);
    expect(matches("label:work", bare)).toBe(false);
    expect(matches('label:"to do"', labelled)).toBe(false);
    expect(matches("label:none", bare)).toBe(true);
    expect(matches("label:any", labelled)).toBe(true);
  });

  it("is: covers pin, share and checklist progress", () => {
    expect(matches("is:pinned", note("a", { pinned: true }))).toBe(true);
    expect(matches("-is:pinned", note("a", { pinned: true }))).toBe(false);
    expect(matches("is:shared", note("b", { collaborators: [{ id: "u2", name: "Ada" }] }))).toBe(true);
    const done = note("c", { kind: "checklist", items: [item("1", "Milk", true)] });
    const open = note("d", { kind: "checklist", items: [item("1", "Milk", true), item("2", "Eggs")] });
    expect(matches("is:done", done)).toBe(true);
    expect(matches("is:done", open)).toBe(false);
    expect(matches("is:open", open)).toBe(true);
    expect(matches("is:open", done)).toBe(false);
    expect(matches("is:done", note("e", { kind: "checklist" }))).toBe(false);
  });

  it("has: covers reminders, attachments and links", () => {
    expect(matches("has:reminder", note("a", { reminderAt: new Date(2026, 1, 1) }))).toBe(true);
    const withImage = note("b", { attachments: [attachment("f1", "image/png")] });
    expect(matches("has:image", withImage)).toBe(true);
    expect(matches("has:attachment", withImage)).toBe(true);
    expect(matches("has:audio", withImage)).toBe(false);
    expect(matches("has:link", note("c", { content: "see https://example.com for more" }))).toBe(true);
    expect(matches("has:link", note("d", { content: "no url here" }))).toBe(false);
  });

  it("a negative filter keeps what the positive one drops", () => {
    const withLink = note("a", { content: "see https://example.com" });
    const withoutLink = note("b", { content: "no url here" });
    expect(matches("hasnot:link", withoutLink)).toBe(true);
    expect(matches("hasnot:link", withLink)).toBe(false);
    expect(matches("notlabel:work", note("c", { labelIds: ["l-work"] }))).toBe(false);
    const red = note("e", { color: "red", kind: "markdown" });
    expect(matches("notcolor:red", red)).toBe(false);
    expect(matches("notkind:text", red)).toBe(true);
    expect(matches("colour:red", red)).toBe(true);
    expect(matches("kind:markdown", red)).toBe(true);
  });

  it("free text searches title, content, items, label names and OCR text", () => {
    expect(matches("sourdough", note("a", { items: [item("1", "Sourdough")] }))).toBe(true);
    expect(matches("wor", note("b", { labelIds: ["l-work"] }))).toBe(true);
    const photo = note("c", { attachments: [attachment("f1", "image/jpeg", "PHARMACY RECEIPT ibuprofen 4.20")] });
    expect(matches("ibuprofen", photo)).toBe(true);
    expect(matches("pharmacy", photo)).toBe(true);
    expect(matches("aspirin", photo)).toBe(false);
    expect(matches("-ibuprofen", photo)).toBe(false);
    expect(matches("grocer label:work is:pinned", note("d", { title: "Groceries", pinned: true, labelIds: ["l-work"] }))).toBe(true);
  });
});

describe("view integration", () => {
  const archived = (id: string): Note => note(id, { title: id, archived: true });
  const select = (notes: Note[], query: string, view: "notes" | "archive" | "label" = "notes", labelId?: string) =>
    selectNotes({ notes, labels, selection: { view, labelId }, query, sortMode: "custom", currentUserId: "me" }).others.map((n) => n.id);

  it("is:archived reveals archived notes from the notes view", () => {
    expect(select([note("live"), archived("old")], "is:archived")).toEqual(["old"]);
  });

  it("is:trashed still refuses a note the user does not own", () => {
    expect(select([note("mine", { trashed: true }), note("theirs", { trashed: true, ownerId: "someone-else" })], "is:trashed")).toEqual(["mine"]);
  });

  it("negated state filters narrow the view instead of replacing it", () => {
    expect(select([note("live"), archived("old")], "isnot:archived")).toEqual(["live"]);
    expect(select([note("a"), note("b", { pinned: true }), archived("c")], "-is:pinned")).toEqual(["a"]);
  });

  it("an override inside a label view keeps the label filter", () => {
    expect(select([note("tagged", { archived: true, labelIds: ["l-work"] }), note("untagged", { archived: true })], "is:archived", "label", "l-work")).toEqual([
      "tagged",
    ]);
  });

  it("the archive view is unaffected by an is: filter it already implies", () => {
    expect(select([archived("a"), note("b")], "is:archived", "archive")).toEqual(["a"]);
  });
});
