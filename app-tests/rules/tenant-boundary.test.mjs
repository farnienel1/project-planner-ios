/**
 * Organisation A must not be readable or writable by a member of organisation B,
 * including a member whose own user document has adminAccess.
 */
import { readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import { assertFails, assertSucceeds, initializeTestEnvironment } from "@firebase/rules-unit-testing";
import { doc, getDoc, setDoc } from "firebase/firestore";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const rules = readFileSync(path.join(root, "Project Planner", "firestore.rules"), "utf8");

test("a member of organisation B cannot read or write organisation A", async () => {
  if (!process.env.FIRESTORE_EMULATOR_HOST) {
    throw new Error("FIRESTORE_EMULATOR_HOST is not set");
  }
  const [host, portText] = process.env.FIRESTORE_EMULATOR_HOST.split(":");
  const testEnv = await initializeTestEnvironment({
    projectId: "demo-project-planner",
    firestore: { rules, host, port: Number(portText) },
  });
  try {
    await testEnv.clearFirestore();
    await testEnv.withSecurityRulesDisabled(async (context) => {
      const database = context.firestore();
      await setDoc(doc(database, "organizations/org-a"), {
        name: "A",
        creatorUserId: "admin-a",
        members: { "admin-a": "admin" },
      });
      await setDoc(doc(database, "organizations/org-b"), {
        name: "B",
        creatorUserId: "admin-b",
        members: { "admin-b": "admin", "user-b": "member" },
      });
      await setDoc(doc(database, "users/admin-a"), {
        organizationId: "org-a",
        role: "admin",
        adminAccess: true,
      });
      await setDoc(doc(database, "users/admin-b"), {
        organizationId: "org-b",
        role: "admin",
        adminAccess: true,
      });
      await setDoc(doc(database, "users/user-b"), {
        organizationId: "org-b",
        role: "operative",
        adminAccess: false,
      });
      await setDoc(doc(database, "organizations/org-a/projects/job-1"), {
        name: "A job",
        organizationId: "org-a",
      });
      await setDoc(doc(database, "organizations/org-a/bookings/booking-1"), {
        organizationId: "org-a",
      });
    });

    const adminA = testEnv.authenticatedContext("admin-a", { email: "a@example.com" }).firestore();
    const adminB = testEnv.authenticatedContext("admin-b", { email: "b@example.com" }).firestore();
    const userB = testEnv.authenticatedContext("user-b", { email: "op@example.com" }).firestore();

    await assertSucceeds(getDoc(doc(adminA, "organizations/org-a/projects/job-1")));
    await assertFails(getDoc(doc(adminB, "organizations/org-a/projects/job-1")));
    await assertFails(getDoc(doc(userB, "organizations/org-a/projects/job-1")));
    await assertFails(getDoc(doc(adminB, "organizations/org-a")));
    await assertFails(getDoc(doc(userB, "organizations/org-a/bookings/booking-1")));
    await assertFails(
      setDoc(doc(adminB, "organizations/org-a/bookings/intruder"), { organizationId: "org-a" })
    );
    await assertFails(
      setDoc(doc(userB, "organizations/org-a/projects/intruder"), { organizationId: "org-a", name: "leak" })
    );
  } finally {
    await testEnv.cleanup();
  }
});
