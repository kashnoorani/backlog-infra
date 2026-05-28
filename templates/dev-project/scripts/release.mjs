#!/usr/bin/env node
// Thin wrapper — delegates to the shared release script at ~/dev/projects/active/backlog-infra/bin/release.mjs
// with this project's name. The shared script handles all 10 release steps.
import { homedir } from "node:os";
import { spawnSync } from "node:child_process";
const args = [
  homedir() + "/dotfiles/bin/release.mjs",
  "--project", "__PROJECT_NAME__",
  ...process.argv.slice(2),
];
process.exit(spawnSync("node", args, { stdio: "inherit" }).status ?? 1);
