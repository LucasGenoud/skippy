import { describe, expect, it } from "vitest";
import { makeNote, type Note } from "@/lib/models/note";
import {
  backlinksTo,
  findNoteLinks,
  linkCandidates,
  linkTitleEnd,
  linkTitleStart,
  markdownNoteLinks,
  NOTE_LINK_SCHEME,
  noteIdFromHref,
  noteLinkToken,
  openLinkQuery,
  plainNoteLinks,
  remapNoteLinks,
  snapOutOfLinks,
  widenLinkDeletion,
} from "./note-links";

// Ported from `app/test/note_links_test.dart`.

const A = "11111111-1111-4111-8111-111111111111";
const B = "22222222-2222-4222-8222-222222222222";
const note = (id: string, fields: Partial<Note> = {}): Note =>
  makeNote({ id, workspaceId: "w", createdAt: new Date(Date.UTC(2026, 0)), updatedAt: new Date(Date.UTC(2026, 0)), ...fields });

describe("findNoteLinks", () => {
  it("reads the id and title of every link", () => {
    const text = `see [[${A}|Groceries]] and [[${B}|Trip]]`;
    const links = findNoteLinks(text);
    expect(links.map((l) => l.noteId)).toEqual([A, B]);
    expect(links.map((l) => l.title)).toEqual(["Groceries", "Trip"]);
    const first = links[0];
    expect(first && text.slice(first.start, first.end)).toBe(`[[${A}|Groceries]]`);
    expect(first && text.slice(linkTitleStart(first), linkTitleEnd(first))).toBe("Groceries");
  });

  it("ignores brackets that are not a link", () => {
    expect(findNoteLinks("[[Groceries]] [[nope|x]] [x](y)")).toEqual([]);
  });
});

it("noteLinkToken keeps the token parseable whatever the title", () => {
  const links = findNoteLinks(noteLinkToken(A, "a [b] | c\nd"));
  expect(links[0]?.noteId).toBe(A);
  expect(links[0]?.title).toBe("a b c d");
  expect(noteLinkToken(A, "  ")).toBe(`[[${A}|Untitled note]]`);
});

it("plain and markdown forms show titles and follow ids", () => {
  expect(plainNoteLinks(`see [[${A}|Old]] now`, () => "New")).toBe("see New now");
  expect(plainNoteLinks(`see [[${A}|Old]] now`)).toBe("see Old now");
  expect(markdownNoteLinks(`see [[${A}|Old]]`)).toBe(`see [Old](${NOTE_LINK_SCHEME}:${A})`);
  expect(noteIdFromHref(`${NOTE_LINK_SCHEME}:${A}`)).toBe(A);
  expect(noteIdFromHref("https://example.com")).toBeNull();
});

it("remapNoteLinks follows copied notes and leaves the rest", () => {
  const copy = "33333333-3333-4333-8333-333333333333";
  expect(remapNoteLinks(`[[${A}|A]] [[${B}|B]]`, { [A]: copy })).toBe(`[[${copy}|A]] [[${B}|B]]`);
});

describe("openLinkQuery", () => {
  it("is the text typed after an unclosed [[", () => {
    expect(openLinkQuery("go to [[gro", 11)).toBe("gro");
    expect(openLinkQuery("go to [[", 8)).toBe("");
  });

  it("is null once closed or across a line", () => {
    const closed = `[[${A}|A]] x`;
    expect(openLinkQuery(closed, closed.length)).toBeNull();
    expect(openLinkQuery("[[gro\nceries", 12)).toBeNull();
    expect(openLinkQuery("no link", 7)).toBeNull();
  });
});

it("backlinks and candidates", () => {
  const notes = [note(A, { title: "A" }), note(B, { title: "B", content: `see [[${A}|A]]` }), note("c", { title: "C", content: "nothing" })];
  expect(backlinksTo(A, notes).map((n) => n.id)).toEqual([B]);
  expect(backlinksTo(B, notes)).toEqual([]);
  const old = note(A, { title: "Grocery list" });
  const recent = note(B, { content: "buy groceries", updatedAt: new Date(Date.UTC(2026, 1)) });
  expect(linkCandidates([old, recent], "groc").map((n) => n.id)).toEqual([B, A]);
  expect(linkCandidates([old, recent], "groc", B)).toHaveLength(1);
});

describe("atomic links", () => {
  const text = `x [[${A}|A]] y`;
  const link = findNoteLinks(text)[0] as NonNullable<ReturnType<typeof findNoteLinks>[number]>;

  it("a caret inside a link snaps to the edge it moved toward", () => {
    expect(snapOutOfLinks(text, link.start + 3, link.start)).toBe(link.end);
    expect(snapOutOfLinks(text, link.end - 1, link.end)).toBe(link.start);
    expect(snapOutOfLinks(text, 1, 0)).toBe(1);
  });

  it("deleting part of a link deletes all of it; typing passes through", () => {
    const after = text.slice(0, link.end - 1) + text.slice(link.end);
    expect(widenLinkDeletion(text, after)).toEqual({ text: "x  y", caret: 2 });
    expect(widenLinkDeletion("ab", "abc")).toBeNull();
  });
});
