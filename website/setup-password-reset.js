#!/usr/bin/env node
/**
 * One-time setup for password reset email on the web app.
 * Prompts for your Resend API key, then sets the Firebase secret and deploys the functions.
 *
 * Run from the website folder: node setup-password-reset.js
 * Or on Mac: double-click "Setup Password Reset.command"
 */

const { createInterface } = require("readline");
const { execSync } = require("child_process");
const fs = require("fs");
const path = require("path");

const WEBSITE_DIR = path.resolve(__dirname);
const SECRET_NAME = "RESEND_API_KEY";

function log(msg) {
  console.log(msg);
}

function run(cmd, options = {}) {
  log(`\n▶ ${cmd}`);
  try {
    execSync(cmd, {
      cwd: WEBSITE_DIR,
      stdio: "inherit",
      ...options,
    });
  } catch (e) {
    if (e.status !== undefined) process.exit(e.status);
    throw e;
  }
}

function prompt(question) {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  return new Promise((resolve) => {
    rl.question(question, (answer) => {
      rl.close();
      resolve((answer || "").trim());
    });
  });
}

async function main() {
  log("Password reset setup – web app");
  log("This will set your Resend API key in Firebase and deploy the functions.\n");

  const key = await prompt("Paste your Resend API key (from https://resend.com/api-keys, starts with re_): ");
  if (!key || !key.startsWith("re_")) {
    log("\n❌ A valid Resend API key is required (starts with re_). Exiting.");
    process.exit(1);
  }

  const tmpFile = path.join(WEBSITE_DIR, ".resend-key-tmp");
  try {
    fs.writeFileSync(tmpFile, key, { mode: 0o600 });
    run(`firebase functions:secrets:set ${SECRET_NAME} --data-file=${tmpFile}`);
    log("\n✅ Secret set.");
  } finally {
    try {
      fs.unlinkSync(tmpFile);
    } catch (_) {}
  }

  log("\nInstalling function dependencies...");
  run("npm install --prefix functions");

  log("\nDeploying functions (this may take 1–2 minutes)...");
  run("firebase deploy --only functions");

  log("\n✅ Done. The password reset email should now work on the setup-password page.");
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
