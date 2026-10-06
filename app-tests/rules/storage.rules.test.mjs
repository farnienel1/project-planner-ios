import assert from "node:assert/strict";
import { existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");

const CANDIDATES = [
  "Project Planner/storage.rules",
  "website/storage.rules",
  "storage.rules",
];

const APP_UPLOAD_PREFIXES = [
  "organizations/{orgId}/tasks/{taskId}/files/",
  "organizations/{orgId}/tasks/{taskId}/images/",
  "organizations/{orgId}/healthSafety/{projectId}/",
  "organizations/{orgId}/siteAudits/{auditId}/images/",
  "organizations/{orgId}/userProfiles/{userId}/profile.jpg",
  "organizations/{orgId}/branding/company_logo/",
  "organizations/{orgId}/operatives/{operativeId}/qualifications/{qualificationId}/certificates/",
  "organizations/{orgId}/variations/{variationId}/",
  "organizations/{orgId}/timesheetExports/",
];

test("storage.rules blocks signed-out and cross-organisation access", () => {
  const found = CANDIDATES.find((relative) => existsSync(path.join(root, relative)));
  assert.ok(
    found,
    [
      "CRITICAL: the app ships no storage.rules file.",
      "Project Planner/firebase.json only sets firestore.rules.",
      "iOS still uploads to Firebase Storage at:",
      ...APP_UPLOAD_PREFIXES.map((prefix) => `  - ${prefix}`),
      "Add Project Planner/storage.rules, point firebase.json storage.rules at it, and deny",
      "unauthenticated access and any object whose organization id is not the caller's org.",
    ].join("\n")
  );
});
