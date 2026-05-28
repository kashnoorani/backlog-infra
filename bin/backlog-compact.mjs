#!/usr/bin/env node
// backlog-compact.mjs — move completed items from `## Done` to `## Archive`
// so the Done section stays focused on recent completions. Archival is
// non-destructive: items are preserved under `## Archive` (creating it
// at the end if it doesn't exist). The `## Done` section is reset to `(none)`.

import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const REPO_ROOT = process.cwd();

function findBacklogFile() {
  const docs = join(REPO_ROOT, "docs", "Backlog.md");
  if (existsSync(docs)) return docs;
  const root = join(REPO_ROOT, "Backlog.md");
  if (existsSync(root)) return root;
  const legacy = join(REPO_ROOT, "backlog.txt");
  if (existsSync(legacy)) return legacy;
  return null;
}

function main() {
  const bf = findBacklogFile();
  if (!bf) {
    console.error("backlog-compact: no docs/Backlog.md or backlog.txt found");
    process.exit(1);
  }

  const lines = readFileSync(bf, "utf8").split("\n");

  // Find `## Done` section boundaries.  A section starts at its `## Name`
  // header and ends at the next `## ` header (or EOF).
  let doneStart = -1;
  let doneEnd = lines.length;
  for (let i = 0; i < lines.length; i++) {
    const m = lines[i].match(/^## (.+)/);
    if (!m) continue;
    if (doneStart === -1 && m[1] === "Done") {
      doneStart = i;
    } else if (doneStart !== -1) {
      doneEnd = i;
      break;
    }
  }

  if (doneStart === -1) {
    console.error("backlog-compact: no ## Done section found");
    process.exit(1);
  }

  // Collect done items and preserved non-done lines from the Done section.
  const doneItems = [];
  const remaining = [];
  for (let i = doneStart + 1; i < doneEnd; i++) {
    if (/^(- )?\[x\] /.test(lines[i])) {
      doneItems.push(lines[i]);
    } else {
      remaining.push(lines[i]);
    }
  }

  if (doneItems.length === 0) {
    console.log("backlog-compact: no done items to archive");
    process.exit(0);
  }

  // Rebuild the file: everything before Done, rebuilt Done, everything after.
  const final = [];
  for (let i = 0; i < doneStart; i++) final.push(lines[i]);

  // Rebuilt Done section.
  final.push("## Done");
  const leftover = remaining.filter((l) => l.trim() !== "");
  if (leftover.length === 0) {
    final.push("(none)");
  } else {
    for (const l of leftover) final.push(l);
  }

  for (let i = doneEnd; i < lines.length; i++) final.push(lines[i]);

  // Insert done items into Archive (existing or new at end).
  const archiveIdx = final.findIndex((l) => /^## Archive/.test(l));
  if (archiveIdx !== -1) {
    final.splice(archiveIdx + 1, 0, ...doneItems);
  } else {
    if (final[final.length - 1] !== "") final.push("");
    final.push(`## Archive (${new Date().toISOString().slice(0, 7)})`);
    final.push(...doneItems);
  }

  writeFileSync(bf, final.join("\n"), "utf8");
  console.log(`backlog-compact: archived ${doneItems.length} item(s) from ## Done → ## Archive`);
}

main();
