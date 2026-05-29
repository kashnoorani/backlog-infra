#!/usr/bin/env node
//
// backlog-lint.mjs — a standalone schema linter for docs/Backlog.md.
//
// The backlog is hand- and agent-edited GFM markdown and is the single source
// of truth for the autonomous worker. Malformed edits (mis-ordered sections,
// bad markers, duplicate titles, a stray "- [" that isn't a real checkbox) have
// caused real breakage. This validator asserts the §2 data-model grammar so a
// pre-commit hook or top-of-tick guard can reject a corrupt queue.
//
// No external deps — node:fs only. Exit 0 when clean, exit 1 with a violation
// list otherwise.
//
// Usage:  node bin/backlog-lint.mjs [path/to/Backlog.md]   (default ./docs/Backlog.md)

import { readFileSync } from "node:fs";

// Canonical section order (§2). Missing sections are fine; the ones PRESENT must
// appear in this relative order. Archive is optional and, if present, must be
// last.
const CANONICAL_ORDER = [
  "Thinking",
  "Open",
  "In progress",
  "Blocked",
  "Done",
  "Archive",
];

// Valid item markers (the character inside the brackets). §2 marker table.
const VALID_MARKERS = new Set([" ", "~", "?", "!", "x"]);

// A checklist line: optional indent, optional "- ", then "[<marker>]" then body.
// We capture the marker char so we can validate it.
const ITEM_RE = /^\s*(?:- )?\[(.)\]\s?(.*)$/;

// A line that LOOKS like it wants to be a checklist item — starts (after
// optional indent and an optional "- ") with a "[" — but isn't a valid marker.
// Used to catch obviously-malformed "- [" lines. We anchor on the bracket so we
// don't flag ordinary prose that merely contains "[".
const LOOKS_LIKE_ITEM_RE = /^\s*(?:- )?\[/;

function lint(text) {
  const lines = text.split(/\r?\n/);
  const violations = [];

  // --- pass 1: discover sections in document order ---
  // Record every "## " heading we see, in the order they appear.
  const seenSections = []; // { name, line }
  for (let i = 0; i < lines.length; i++) {
    const m = /^##\s+(.+?)\s*$/.exec(lines[i]);
    if (m) seenSections.push({ name: m[1].trim(), line: i + 1 });
  }

  // --- check (1): canonical section order ---
  // Filter to recognized canonical sections, then assert their relative order
  // matches CANONICAL_ORDER. Unknown "## " headings are ignored for ordering
  // (they may be sub-notes), but we still track the known ones.
  const known = seenSections.filter((s) => CANONICAL_ORDER.includes(s.name));
  let lastRank = -1;
  for (const s of known) {
    const rank = CANONICAL_ORDER.indexOf(s.name);
    if (rank < lastRank) {
      violations.push(
        `section order: "## ${s.name}" (line ${s.line}) appears after a later-ranked section; ` +
          `expected order is ${CANONICAL_ORDER.join(" → ")}`
      );
    }
    lastRank = Math.max(lastRank, rank);
  }

  // Duplicate canonical section headings are also malformed.
  const sectionCounts = new Map();
  for (const s of known) {
    sectionCounts.set(s.name, (sectionCounts.get(s.name) || 0) + 1);
  }
  for (const [name, count] of sectionCounts) {
    if (count > 1) {
      violations.push(`duplicate section: "## ${name}" appears ${count} times`);
    }
  }

  // --- passes (2)/(3)/(4): walk lines, tracking the current section ---
  let currentSection = null;
  const openTitles = new Map(); // normalized title -> first line number

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const lineNo = i + 1;

    const heading = /^##\s+(.+?)\s*$/.exec(line);
    if (heading) {
      currentSection = heading[1].trim();
      continue;
    }

    const item = ITEM_RE.exec(line);
    if (item) {
      const marker = item[1];
      const body = item[2];

      // (2) valid marker
      if (!VALID_MARKERS.has(marker)) {
        violations.push(
          `bad marker: line ${lineNo} uses "[${marker}]" — valid markers are ` +
            `[ ] [~] [?] [!] [x]`
        );
        // still continue; a bad marker line shouldn't also count as a title.
        continue;
      }

      // (3) no duplicate titles within Open
      if (currentSection === "Open") {
        const title = normalizeTitle(body);
        if (title.length > 0) {
          if (openTitles.has(title)) {
            violations.push(
              `duplicate Open title: line ${lineNo} repeats "${truncate(body)}" ` +
                `(first seen at line ${openTitles.get(title)})`
            );
          } else {
            openTitles.set(title, lineNo);
          }
        }
      }
      continue;
    }

    // (4) obviously malformed: looks like an item but didn't parse as a valid
    // marker line. Skip blockquotes (the "> " rationalization notes) and lines
    // already handled above.
    if (LOOKS_LIKE_ITEM_RE.test(line)) {
      violations.push(
        `malformed item: line ${lineNo} starts a checkbox-like "[" but is not a ` +
          `valid marker line: ${truncate(line.trim())}`
      );
    }
  }

  return violations;
}

// Normalize a title for duplicate comparison: strip surrounding whitespace,
// collapse internal runs of whitespace, lowercase. Markdown emphasis markers
// (**, *, `) are left in place — they're part of the literal title and two
// items differing only in emphasis are still distinct enough to keep; but
// trailing whitespace and case are not meaningful.
function normalizeTitle(body) {
  return body.replace(/\s+/g, " ").trim().toLowerCase();
}

function truncate(s, n = 80) {
  return s.length > n ? s.slice(0, n - 1) + "…" : s;
}

function main(argv) {
  const path = argv[2] || "./docs/Backlog.md";

  let text;
  try {
    text = readFileSync(path, "utf8");
  } catch (err) {
    console.error(`backlog-lint: cannot read ${path}: ${err.message}`);
    process.exit(1);
  }

  const violations = lint(text);

  if (violations.length === 0) {
    console.log(`backlog-lint: OK — ${path} is well-formed`);
    process.exit(0);
  }

  console.error(`backlog-lint: FAILED — ${violations.length} violation(s) in ${path}:`);
  for (const v of violations) console.error(`  - ${v}`);
  process.exit(1);
}

main(process.argv);
