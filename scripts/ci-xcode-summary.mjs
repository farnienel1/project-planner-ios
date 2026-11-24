#!/usr/bin/env node
// CI only. Reads an xcodebuild log (and, when there is one, the JSON from
// `xcrun xcresulttool get test-results tests`) and writes a short job summary to
// $GITHUB_STEP_SUMMARY: compile errors (file:line) and failing tests with their messages,
// so a red run can be read without downloading any artifact. Never fails the job.
//
//   node scripts/ci-xcode-summary.mjs --title "Parity tests" --log xcodebuild.log \
//     [--results results.json] [--all] [--status <exit code>]
//
// --all lists passing tests too (the screen checks always listed every check).

import fs from 'node:fs';

function arg(name, fallback = null) {
  const i = process.argv.indexOf(`--${name}`);
  if (i === -1) return fallback;
  const next = process.argv[i + 1];
  return next === undefined || next.startsWith('--') ? true : next;
}

const title = String(arg('title', 'xcodebuild'));
const logPath = arg('log');
const resultsPath = arg('results');
const listAll = arg('all', false) === true;
const status = arg('status');

const workspace = (process.env.GITHUB_WORKSPACE || '').replace(/\/?$/, '/');
const trimPath = (s) => (workspace.length > 1 ? s.split(workspace).join('') : s);
const read = (p) => {
  try {
    return p && fs.existsSync(p) ? fs.readFileSync(p, 'utf8') : null;
  } catch {
    return null;
  }
};
// A summary line must not close the code fence it sits in.
const safe = (s) => String(s).replace(/```/g, "'''").slice(0, 400);
const uniq = (a) => [...new Set(a)];

export function compileErrors(log) {
  if (!log) return [];
  const lines = log.split(/\r?\n/);
  const errors = lines
    .filter((l) => /^\/.*:\d+:\d+: error:/.test(l) || /^xcodebuild: error:/.test(l) || /^error: /.test(l))
    .map((l) => trimPath(l.trim()));
  return uniq(errors);
}

export function logTestFailures(log) {
  if (!log) return [];
  const lines = log.split(/\r?\n/);
  const out = [];
  for (const l of lines) {
    let m = l.match(/Test Case '-\[(\S+) (\S+)\]' failed/);
    if (m) { out.push(`${m[1]}.${m[2]}`); continue; }
    m = l.match(/^.*:\d+: error: -\[(\S+) (\S+)\] : (.*)$/);
    if (m) { out.push(`${m[1]}.${m[2]} — ${m[3]}`); continue; }
    // Swift Testing
    m = l.match(/✘ Test (.+?) (?:failed|recorded an issue)(.*)$/);
    if (m) out.push(`${m[1]}${m[2] ? ' ' + m[2].trim() : ''}`);
  }
  return uniq(out.map((s) => trimPath(s)));
}

export function resultTests(json) {
  if (!json) return null;
  let r;
  try {
    r = JSON.parse(json);
  } catch {
    return null;
  }
  const tests = [];
  const walk = (n) => {
    if (n.nodeType === 'Test Case') {
      const msgs = [];
      const grab = (c) => {
        if (c.nodeType === 'Failure Message') msgs.push(c.name);
        (c.children || []).forEach(grab);
      };
      (n.children || []).forEach(grab);
      tests.push({ name: n.nodeIdentifier || n.name, result: n.result, messages: msgs });
    }
    (n.children || []).forEach(walk);
  };
  (r.testNodes || []).forEach(walk);
  return tests;
}

function main() {
  const log = read(logPath);
  const tests = resultTests(read(resultsPath));
  const errors = compileErrors(log);
  const md = [`## ${title}`];

  if (status !== null && status !== true) md.push(`xcodebuild exit status: \`${safe(status)}\``);
  if (!log) {
    md.push('No xcodebuild log. The job stopped before the build started (setup failed, timed out or was cancelled).');
  }
  const cutOff = !!log && !/\*\* (TEST|BUILD) (SUCCEEDED|FAILED|INTERRUPTED) \*\*/.test(log);
  if (cutOff) {
    md.push('The xcodebuild log has no final result line: the build or test run was cut off (step timeout or cancel). See the last lines below and the uploaded log.');
  }

  if (errors.length) {
    md.push(`### Compile errors (${errors.length})`, '```', ...errors.slice(0, 60).map(safe), '```');
    for (const e of errors.slice(0, 30)) console.log(`::error::${e.replace(/\r?\n/g, ' ')}`);
  }

  let failed = [];
  if (tests) {
    failed = tests.filter((t) => t.result !== 'Passed' && t.result !== 'Skipped' && t.result !== 'Expected Failure');
    const passed = tests.filter((t) => t.result === 'Passed').length;
    const skipped = tests.filter((t) => t.result === 'Skipped').length;
    md.push(`Tests: ${passed} passed, ${failed.length} failed, ${skipped} skipped.`);
    const shown = listAll ? tests : failed;
    if (shown.length) {
      md.push(listAll ? '### Results' : `### Failing tests (${failed.length})`, '```');
      for (const t of shown.slice(0, 200)) {
        md.push(safe(`${t.result === 'Passed' ? 'PASS' : t.result === 'Skipped' ? 'SKIP' : 'FAIL'}  ${t.name}`));
        for (const m of t.messages.slice(0, 5)) md.push(safe(`        ${m}`));
      }
      md.push('```');
    }
  } else {
    const fromLog = logTestFailures(log);
    if (fromLog.length) md.push(`### Failing tests (${fromLog.length}, from the log)`, '```', ...fromLog.slice(0, 200).map(safe), '```');
  }

  const nonZero = status !== null && status !== true && status !== '0';
  if (log && (cutOff || (nonZero && !errors.length && !failed.length))) {
    const tail = log.trimEnd().split(/\r?\n/).slice(-40).map((l) => trimPath(l));
    md.push('### Last 40 log lines', '```', ...tail.map(safe), '```');
  }

  md.push('Full log, result bundle (zipped) and screenshots: the artifacts of this run (kept 7 days).', '');
  const text = md.join('\n');
  console.log(text);
  if (process.env.GITHUB_STEP_SUMMARY) fs.appendFileSync(process.env.GITHUB_STEP_SUMMARY, text + '\n');
}

if (import.meta.url === `file://${process.argv[1]}`) {
  try {
    main();
  } catch (e) {
    console.log(`::warning::Could not write the summary: ${e && e.message}`);
  }
}
