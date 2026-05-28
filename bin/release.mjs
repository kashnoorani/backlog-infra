#!/usr/bin/env node
/**
 * release.mjs — promote main → release, tag, deploy to Cloudflare Pages.
 *
 * Single entry point for a production deploy. Aborts at the first failure;
 * nothing touches origin or Cloudflare until the local gate (steps 1–5)
 * has passed.
 *
 * Shared copy at ~/dev/projects/active/backlog-infra/bin/release.mjs. Per-project wrappers at
 * <project>/scripts/release.mjs call this with --project <name>.
 *
 * Usage:
 *   node ~/dev/projects/active/backlog-infra/bin/release.mjs --project <cf-project-name>
 *   node ~/dev/projects/active/backlog-infra/bin/release.mjs --project <cf-project-name> --dry-run
 */

import { execSync, spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const REPO_ROOT = process.cwd();
const RELEASE_BRANCH = "release";
const MAIN_BRANCH = "main";

// ---------- arg parsing ----------
function parseArgs() {
  const argv = process.argv.slice(2);
  const opts = { project: "", dryRun: false };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--project") opts.project = argv[++i] ?? "";
    else if (a === "--dry-run") opts.dryRun = true;
  }
  if (!opts.project) {
    console.error("release: --project <name> is required");
    process.exit(2);
  }
  return opts;
}

const { project: CF_PROJECT, dryRun: DRY_RUN } = parseArgs();

function fail(step, message) {
  console.error(`\n✗ release aborted at ${step}: ${message}`);
  process.exit(1);
}

function info(message) {
  console.log(`\n→ ${message}`);
}

function ok(message) {
  console.log(`  ✓ ${message}`);
}

function sh(cmd, { capture = true } = {}) {
  if (capture) {
    return execSync(cmd, { cwd: REPO_ROOT, encoding: "utf8" }).trim();
  }
  const r = spawnSync(cmd, { cwd: REPO_ROOT, shell: true, stdio: "inherit" });
  if (r.status !== 0) throw new Error(`exit ${r.status}`);
  return "";
}

// ---------- Step 1: clean working tree ----------
info("Step 1/10 — clean working tree");
{
  const status = sh("git status --porcelain");
  if (status.length > 0) {
    fail(
      "step 1 (clean tree)",
      `working tree is dirty. Commit or stash before releasing.\n${status}`,
    );
  }
  ok("git status is clean");
}

// ---------- Step 2: on main ----------
info(`Step 2/10 — on ${MAIN_BRANCH} branch`);
const currentBranch = sh("git rev-parse --abbrev-ref HEAD");
if (currentBranch !== MAIN_BRANCH) {
  fail(
    "step 2 (branch check)",
    `expected branch "${MAIN_BRANCH}", got "${currentBranch}".`,
  );
}
ok(`on ${MAIN_BRANCH}`);

// ---------- Step 3: up to date with origin/main ----------
info(`Step 3/10 — sync with origin/${MAIN_BRANCH}`);
try {
  sh(`git fetch origin ${MAIN_BRANCH}`, { capture: false });
} catch {
  fail("step 3 (fetch)", `git fetch origin ${MAIN_BRANCH} failed.`);
}
const behindCount = Number(
  sh(`git rev-list --count HEAD..origin/${MAIN_BRANCH}`),
);
if (behindCount > 0) {
  fail(
    "step 3 (sync)",
    `local ${MAIN_BRANCH} is ${behindCount} commit(s) behind origin/${MAIN_BRANCH}. Pull first.`,
  );
}
const aheadCount = Number(
  sh(`git rev-list --count origin/${MAIN_BRANCH}..HEAD`),
);
ok(
  aheadCount > 0
    ? `local ${MAIN_BRANCH} is ${aheadCount} commit(s) ahead of origin/${MAIN_BRANCH} (will be pushed via the release branch)`
    : `local ${MAIN_BRANCH} matches origin/${MAIN_BRANCH}`,
);

// ---------- Step 4: release is an ancestor of main ----------
info(`Step 4/10 — ${RELEASE_BRANCH} is an ancestor of ${MAIN_BRANCH}`);
const releaseExists =
  spawnSync("git", ["show-ref", "--verify", "--quiet", `refs/heads/${RELEASE_BRANCH}`], {
    cwd: REPO_ROOT,
  }).status === 0;
if (releaseExists) {
  const isAncestor =
    spawnSync(
      "git",
      ["merge-base", "--is-ancestor", RELEASE_BRANCH, MAIN_BRANCH],
      { cwd: REPO_ROOT },
    ).status === 0;
  if (!isAncestor) {
    const releaseSha = sh(`git rev-parse ${RELEASE_BRANCH}`);
    fail(
      "step 4 (ancestry)",
      `${RELEASE_BRANCH} (${releaseSha.slice(0, 7)}) has diverged from ${MAIN_BRANCH}. Reconcile by hand before releasing.`,
    );
  }
  const pending = Number(
    sh(`git rev-list --count ${RELEASE_BRANCH}..${MAIN_BRANCH}`),
  );
  ok(`${pending} commit(s) pending promotion`);
} else {
  ok(`${RELEASE_BRANCH} branch will be created`);
}

// ---------- Step 5: build + tests ----------
info("Step 5/10 — build + tests (SG_ENV=production npm run build)");
try {
  sh("SG_ENV=production npm run build", { capture: false });
} catch {
  fail("step 5 (build)", "npm run build failed. See output above.");
}
ok("build green");

// ---------- Step 6: read version from dist/version.json ----------
info("Step 6/10 — read version stamp");
let versionRaw;
try {
  versionRaw = JSON.parse(
    readFileSync(resolve(REPO_ROOT, "dist/version.json"), "utf8"),
  ).version;
} catch (err) {
  fail("step 6 (version)", `could not read dist/version.json: ${err.message}`);
}
// Strip " (production)" suffix → tag body.
const version = versionRaw.replace(/\s*\(.*\)\s*$/, "");
const tag = `release-${version}`;
const headSha = sh("git rev-parse HEAD");
ok(`version=${version}  tag=${tag}  sha=${headSha.slice(0, 7)}`);

if (DRY_RUN) {
  console.log(
    `\n--- dry run ---\nwould fast-forward ${RELEASE_BRANCH} to ${headSha}\nwould create tag ${tag}\nwould push origin ${RELEASE_BRANCH} ${tag}\nwould run: wrangler pages deploy dist --project-name=${CF_PROJECT}\n`,
  );
  process.exit(0);
}

// ---------- Step 7: fast-forward release to main HEAD ----------
info(`Step 7/10 — fast-forward ${RELEASE_BRANCH} → ${headSha.slice(0, 7)}`);
try {
  sh(`git update-ref refs/heads/${RELEASE_BRANCH} ${headSha}`);
} catch (err) {
  fail("step 7 (update-ref)", err.message);
}
ok(`${RELEASE_BRANCH} updated`);

// ---------- Step 8: create annotated tag ----------
info(`Step 8/10 — create tag ${tag}`);
const tagExists =
  spawnSync("git", ["rev-parse", "--verify", "--quiet", `refs/tags/${tag}`], {
    cwd: REPO_ROOT,
  }).status === 0;
if (tagExists) {
  fail(
    "step 8 (tag)",
    `tag ${tag} already exists. Same-second re-release? Wait a moment and try again.`,
  );
}
try {
  sh(`git tag -a ${tag} ${headSha} -m "Release ${version}"`);
} catch (err) {
  fail("step 8 (tag)", err.message);
}
ok(`tag ${tag} created`);

// ---------- Step 9: push branch + tag ----------
info(`Step 9/10 — push origin ${RELEASE_BRANCH} ${tag}`);
try {
  sh(`git push origin ${RELEASE_BRANCH} refs/tags/${tag}`, { capture: false });
} catch {
  fail(
    "step 9 (push)",
    `git push failed. Local ${RELEASE_BRANCH} and tag are intact — fix the push issue and retry from this step.`,
  );
}
ok("pushed");

// ---------- Step 10: deploy to Cloudflare Pages ----------
info(`Step 10/10 — wrangler pages deploy → ${CF_PROJECT}`);
try {
  sh(
    `wrangler pages deploy dist --project-name=${CF_PROJECT} --branch=${RELEASE_BRANCH}`,
    { capture: false },
  );
} catch {
  console.error(
    `\n✗ wrangler deploy failed. The tag ${tag} and ${RELEASE_BRANCH} branch are already pushed —\n  retry the deploy with:\n    wrangler pages deploy dist --project-name=${CF_PROJECT} --branch=${RELEASE_BRANCH}\n  (the dist/ output is still on disk from step 5)`,
  );
  process.exit(1);
}

console.log(
  `\n✓ release complete\n  version: ${version}\n  tag:     ${tag}\n  sha:     ${headSha}\n  branch:  ${RELEASE_BRANCH} now at ${headSha.slice(0, 7)}\n  project: ${CF_PROJECT}\n`,
);
