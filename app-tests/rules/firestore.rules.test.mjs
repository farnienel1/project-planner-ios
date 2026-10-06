/**
 * Security-rules tests for the file the iOS app ships:
 *   Project Planner/firestore.rules
 * (Project Planner/firebase.json → "rules": "firestore.rules")
 *
 * website/firestore.rules is not loaded. These tests run against the
 * Firestore emulator only. They do not start an iOS simulator.
 *
 * Forbidden actions stay forbidden. If the current rules allow one, the
 * suite fails and app-tests/REPORT.md records a CRITICAL gap.
 */
import assert from "node:assert/strict";
import { readFileSync, writeFileSync, existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} from "@firebase/rules-unit-testing";
import {
  collection,
  deleteDoc,
  doc,
  getDoc,
  getDocs,
  query,
  setDoc,
  updateDoc,
  where,
} from "firebase/firestore";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const rulesPath = path.join(root, "Project Planner", "firestore.rules");
const reportPath = path.join(root, "app-tests", "REPORT.md");

const ORG_A = "org-a";
const ORG_B = "org-b";

const ROLES = {
  admin: {
    uid: "user-admin",
    email: "admin@orga.test",
    org: ORG_A,
    data: {
      role: "admin",
      adminAccess: true,
      manager: false,
      operativeMode: false,
      operatives: true,
      wholesalersOrderHistory: true,
      subContractors: true,
      materials: true,
      siteAudit: true,
    },
  },
  manager: {
    uid: "user-manager",
    email: "manager@orga.test",
    org: ORG_A,
    data: {
      role: "manager",
      adminAccess: false,
      manager: true,
      operativeMode: false,
      operatives: true,
      wholesalersOrderHistory: true,
      subContractors: true,
      materials: true,
      siteAudit: true,
    },
  },
  operative: {
    uid: "user-operative",
    email: "op@orga.test",
    org: ORG_A,
    data: {
      role: "operative",
      adminAccess: false,
      manager: false,
      operativeMode: true,
      operatives: false,
      wholesalersOrderHistory: false,
      subContractors: false,
      materials: false,
      siteAudit: true,
    },
  },
  qs: {
    uid: "user-qs",
    email: "qs@orga.test",
    org: ORG_A,
    data: {
      role: "qs",
      adminAccess: false,
      manager: false,
      operativeMode: false,
      operatives: false,
      wholesalersOrderHistory: false,
      subContractors: false,
      materials: false,
      siteAudit: false,
    },
  },
  subcontractor: {
    uid: "user-sub",
    email: "sub@orga.test",
    org: ORG_A,
    data: {
      role: "subcontractor",
      adminAccess: false,
      manager: false,
      operativeMode: false,
      operatives: false,
      wholesalersOrderHistory: false,
      subContractors: true,
      materials: false,
      siteAudit: false,
    },
  },
  otherOrg: {
    uid: "user-other",
    email: "other@orgb.test",
    org: ORG_B,
    data: {
      role: "operative",
      adminAccess: false,
      manager: false,
      operativeMode: true,
      operatives: false,
      wholesalersOrderHistory: false,
      subContractors: false,
      materials: false,
      siteAudit: true,
    },
  },
  otherOrgAdmin: {
    uid: "user-other-admin",
    email: "admin@orgb.test",
    org: ORG_B,
    data: {
      role: "admin",
      adminAccess: true,
      manager: false,
      operativeMode: false,
      operatives: true,
      wholesalersOrderHistory: true,
      subContractors: true,
      materials: true,
      siteAudit: true,
    },
  },
};

const ACTORS = ["admin", "manager", "operative", "qs", "subcontractor", "otherOrg", "otherOrgAdmin", "signedOut"];

const GROUPS = {
  "tenant-hole": {
    title: "Any signed-in user can read and write another organisation's data",
    rule: "function canAccessOrganization",
    lines: "90–96",
    also: "function isAdminOrSuperAdmin lines 212–216. Matches that call canAccessOrganization include projects (429–433), smallWorks (442–445), clients (455–458), operatives (461–464), bookings (467–470), qualifications (473–476), skills (478–481), settings (484–487), tasks (489–492), managers (495–498), notifications (501–505), materials read (507–508), managerSiteBookings (534–538), subcontractors (540–543), subcontractorBookings (546–549), operativeProfiles (557–559), siteAudits (561–565), and the catch-all read at 592–594 (operativeDayRateHistory and any other subcollection).",
    fix: "Delete `|| organizationExists(organizationId)` from canAccessOrganization. Do not treat isAdminOrSuperAdmin() as membership: that helper is not scoped to the path's organisation, so an admin of company B matches it for company A. canAccessOrganization should be belongsToOrganization(organizationId) only. Then add role checks on each match so operativeMode, role == 'operative', role == 'qs', and role == 'subcontractor' cannot write staff-only collections (projects, clients, bookings, settings, wholesalers, the managers roster, and the rest of the staff write list below).",
  },
  "staff-write": {
    title: "Operatives, QS, and sub contractor accounts can change staff-only organisation data",
    rule: "per-collection allow create/update that calls canAccessOrganization or allow write",
    lines: "429–559",
    also: "See each example path. settings is lines 484–487. qualifications and skills use allow write at 473–481, which includes delete.",
    fix: "After canAccessOrganization is tenant-scoped, require an org admin or manager (materialManagerLikeUser / isOrganizationAdmin, same organisation) for creates and updates on projects, smallWorks, clients, operatives, bookings, qualifications, skills, settings other than the caller's own timesheet, managers, notifications, materialCatalogue, wholesalers, managerSiteBookings, subcontractors, subcontractorBookings, and staff edits of someone else's materials. Operatives with siteAudit may write siteAudits. Operatives may write their own operativeProfiles/{uid} and their own holidayBookings. They must not write the managers roster, org settings, or catalogue/wholesaler records.",
  },
  "staff-read": {
    title: "Operatives, QS, and sub contractor accounts can read staff-only or financial records",
    rule: "allow read: if canAccessOrganization(organizationId), and the catch-all read",
    lines: "484–487, 495–498, 507–508, 516–518, 521–524, 529–530, 592–594",
    also: "operativeDayRateHistory has no match of its own, so the catch-all at 592–594 allows the read. materialSendRecords (521–524) is already limited to admins and managers; keep that.",
    fix: "Add match /operativeDayRateHistory/{id} with read, create, update, delete only for isOrganizationAdmin or isOrganizationMaterialManager of that same organisation. Restrict settings/payroll and other people's timesheet_* documents the same way. Restrict managers, materialCatalogue, and wholesalers reads to admin and manager. Do not leave financial documents on the catch-all.",
  },
  "admin-delete": {
    title: "Non-admins can delete organisation records",
    rule: "allow write / allow delete on the match in the example path",
    lines: "473–481 and 557–559",
    also: "qualifications and skills use allow write, so delete is included. operativeProfiles allows delete for canAccessOrganization.",
    fix: "Split allow write into allow create, update and allow delete. Delete of qualifications, skills, and operativeProfiles should require isOrganizationAdmin(organizationId). Do not grant delete through canAccessOrganization.",
  },
  variations: {
    title: "Any signed-in user can read, write, and change variation status, including across organisations",
    rule: "match /variations/{variationId} and match /variationTrackers/{parentId}",
    lines: "582–588",
    also: "The comment above the match says the rule is auth-open like holidayBookings. The iOS client only lets admins, and managers assigned to that job, see or edit variations (WorkAccess.canAccessVariations). There is no QS role. Operatives never get the feature.",
    fix: "Replace `if request.auth != null` with belongsToOrganization(organizationId). Allow update of status only when isOrganizationAdmin(organizationId) is true, or when the caller is a manager in this organisation and request.auth.uid is in the parent project or small-work document's managerUserIds. Deny role == 'operative', operativeMode, role == 'qs', and role == 'subcontractor'. Apply the same tenant check to variationTrackers. A manager who is not on that job's managerUserIds must not change status.",
  },
  holidayBookings: {
    title: "Any signed-in user can read and write every organisation's holiday bookings",
    rule: "match /holidayBookings/{bookingId}",
    lines: "552–555",
    also: "The comment marks this as temporary.",
    fix: "Replace `if request.auth != null` with belongsToOrganization(organizationId). A member may create and update their own booking (userId == request.auth.uid). Approving or deleting someone else's booking should require an org admin or a manager with operatives permission in that same organisation.",
  },
  settings: {
    title: "Operatives can change organisation settings, including payroll settings",
    rule: "match /settings/{settingId}",
    lines: "484–487",
    also: "allow write is canAccessOrganization, so every member (and, until tenant-hole is fixed, every signed-in user) can overwrite jobTypes, payroll, and variationTrades.",
    fix: "Keep read of non-financial settings such as jobTypes for organisation members. allow write only for isOrganizationAdmin or a manager who is not operativeMode, scoped with belongsToOrganization. Put payrollTimePolicy and invoicing amounts on settings/payroll (or a private doc) and allow read of that document only for admins and managers. The organisation root document currently also stores payrollTimePolicy, and every member can read that root.",
  },
  timesheets: {
    title: "Operatives can read and edit other people's timesheets",
    rule: "match /settings/{settingId}",
    lines: "484–487",
    also: "Timesheets are settings documents whose id is timesheet_{userId}_{weekStamp} (FirebaseBackend.timesheetStateDocumentRef). The same allow read/write covers every settings id, so ownership is never checked.",
    fix: "When the document id matches timesheet_ or resource.data.userId is a string, allow read and write only if request.auth.uid == that userId, or the caller is an org admin, or a manager in the same organisation. Deny everyone else, including other operatives, QS, and sub contractor accounts. Do not use a blanket allow write on settings/{settingId}.",
  },
  "users-read": {
    title: "Any signed-in user can read every user document, including another organisation's payroll fields",
    rule: "match /users/{userId}",
    lines: "288–290",
    also: "allow read and allow list are `if request.auth != null`. User documents store dayRate, hourlyRate, vatNumber, and utrNumber.",
    fix: "Allow get of users/{uid} when request.auth.uid == uid, or when the caller is an admin or manager whose users/{uid}.organizationId matches the target document's organizationId. Deny list of the whole users collection. A query filtered to the caller's own organisation can stay allowed for admins and managers. Move dayRate, hourlyRate, vatNumber, and utrNumber to users/{uid}/payroll/current and allow that subdocument only to the user, their manager, and an org admin. Until that split exists, operatives must not be able to get a colleague's user document.",
  },
  "users-write": {
    title: "A user can grant themselves admin, and any signed-in user can patch another person's day rate",
    rule: "match /users/{userId} allow update, plus function canPatchOperativeProfileMetadataOnly",
    lines: "255–265 and 323–342",
    also: "Self-update is allowed with no field list, so role, adminAccess, isSuperAdmin, and organizationId can be changed. canPatchOperativeProfileMetadataOnly is true for any signed-in user whose changed keys are only day rate and employment metadata.",
    fix: "Remove canPatchOperativeProfileMetadataOnly from the update allow. Keep canManagerUpdateOperativeProfile for a manager in the same organisation. When request.auth.uid == userId, changedKeys().hasOnly a profile allow-list that does not include role, adminAccess, isSuperAdmin, manager, operativeMode, organizationId, dayRate, hourlyRate, vatNumber, or utrNumber.",
  },
  "org-doc": {
    title: "Any organisation member can rewrite company settings, including warning detection and payroll",
    rule: "match /organizations/{organizationId} allow update",
    lines: "420–425",
    also: "The third clause allows the update when the caller is still in request.resource.data.members and the organisation exists. It does not limit which fields change. warningDetection and payrollTimePolicy live on this document.",
    fix: "Delete the members-map branch. Allow update only for isOrganizationAdmin(organizationId) (same organisation, not a global admin flag). Operatives, QS, sub contractor accounts, and managers must not be able to write warningDetection or payrollTimePolicy.",
  },
  "org-list": {
    title: "Any signed-in user can list every organisation",
    rule: "match /organizations/{organizationId} allow list",
    lines: "415",
    also: "Get of a single organisation document is tighter than list. list returns every organisation document to any authenticated user.",
    fix: "Remove `allow list: if request.auth != null`. Clients should get the organisation by id from users/{uid}.organizationId. If a list is required, it has to be constrained to organisations whose members map contains request.auth.uid (a query the rules can prove).",
  },
  "global-admin": {
    title: "An admin of one organisation is treated as an admin of every organisation",
    rule: "function isAdminOrSuperAdmin, used by match /organizations/{organizationId} allow read",
    lines: "212–216 and 408–413",
    also: "isAdminOrSuperAdmin() does not compare organizationId. A company admin of org B therefore passes the org A read rule.",
    fix: "On organisation documents, drop the bare isAdminOrSuperAdmin() clause. Membership, userOrgIdMatchesPath(organizationId), or creatorUserId is enough. Anywhere else that helper gates another tenant's data, require userOrgIdMatchesPath for that path as well. Reserve a true platform super-admin (isSuperAdmin == true) for platformConfig only.",
  },
  invitations: {
    title: "Signed-out users can read invitations, and any signed-in user can write them",
    rule: "match /invitations/{invitationId}",
    lines: "275–279",
    also: "allow read: if true covers get and list, so the whole invitation collection (emails, organisation ids, permissions) is public. allow write: if request.auth != null lets an operative create invites.",
    fix: "Remove `allow read: if true` and the open write. Allow get and write only for an admin of the invitation's organizationId. Redeem a signup invitation through a Cloud Function so an unauthenticated client never lists this collection.",
  },
  userEmails: {
    title: "Any signed-in user can read or claim email rows in another organisation",
    rule: "match /userEmails/{emailKey}",
    lines: "396–402",
    also: "allow read is any authenticated user. create/update allows any caller who sets userId to their own uid, in any organisation path.",
    fix: "allow read only for belongsToOrganization(organizationId). allow create, update only when belongsToOrganization(organizationId) and (isOrganizationAdmin(organizationId) or request.resource.data.userId == request.auth.uid). Keep delete on isOrganizationAdmin.",
  },
  orgMemberships: {
    title: "A global admin flag can read and write org memberships in another organisation",
    rule: "match /users/{userId}/orgMemberships/{orgId}",
    lines: "377–389",
    also: "isAdminOrSuperAdmin() is not compared to orgId.",
    fix: "Allow read, write, and delete when request.auth.uid == userId, or when the caller is an admin whose users document organizationId matches both the target user and orgId. Do not use a global isAdminOrSuperAdmin() check here.",
  },
  platformConfig: {
    title: "Any company admin can write platform-wide config",
    rule: "match /platformConfig/{docId}",
    lines: "597–600",
    also: "allow write: if isAdminOrSuperAdmin() is true for every user with adminAccess or role == 'admin', in every organisation.",
    fix: "allow read: if request.auth != null can stay for the shared toolbox library. allow write only when users/{uid}.isSuperAdmin == true. A company admin must not write platformConfig.",
  },
  notifications: {
    title: "Operatives can create warning notifications",
    rule: "match /notifications/{notificationId}",
    lines: "501–505",
    also: "allow create, update is canAccessOrganization. Issuing a warning is a notification whose type is warning_removed or booking_clash. The product does not let operatives issue warnings.",
    fix: "Allow create and update for organisation members only when request.resource.data.type is not a warning type (warning_removed, booking_clash, and the other warning notification types). Warning types require an org admin or manager in that organisation. Combine this with the tenant fix so another organisation's user cannot create them either.",
  },
  "org-delete": {
    title: "The organisation document can be deleted",
    rule: "match /organizations/{organizationId} allow delete",
    lines: "427",
    also: "The rule is `allow delete: if false`.",
    fix: "Keep `allow delete: if false`.",
  },
  storage: {
    title: "No storage.rules file is shipped with the app",
    rule: "Project Planner/firebase.json has no storage.rules entry",
    lines: "n/a",
    also: "Searched Project Planner/storage.rules, website/storage.rules, and storage.rules. None exist. The iOS client uploads to organizations/{orgId}/tasks/.../files|images, healthSafety, siteAudits, userProfiles, branding/company_logo, operatives/.../certificates, variations/{variationId}, and timesheetExports.",
    fix: "Add Project Planner/storage.rules and point firebase.json at it. Deny unauthenticated access. Allow read and write only when the signed-in user's organisation matches the organizations/{orgId} prefix. Deny every other prefix. Do not leave the bucket on the console default.",
  },
};

const gaps = [];
const notes = [];
const seen = new Set();
let deniedCorrectly = 0;
let allowedCorrectly = 0;
const sanityFailures = [];

function addGap(entry) {
  const key = `${entry.fixGroup}|${entry.role}|${entry.action}|${entry.path}`;
  if (seen.has(key)) return;
  seen.add(key);
  gaps.push(entry);
}

function uidOf(role) {
  return role === "signedOut" ? null : ROLES[role].uid;
}

function isOutsider(role, org) {
  if (role === "signedOut") return true;
  return ROLES[role].org !== org;
}

function roleAllows(role, level) {
  switch (level) {
    case "member":
      return role === "admin" || role === "manager" || role === "operative" || role === "qs" || role === "subcontractor";
    case "staff":
      return role === "admin" || role === "manager";
    case "admin":
      return role === "admin";
    case "operativeOrStaff":
      return role === "admin" || role === "manager" || role === "operative";
    case "assignedStaff":
      return role === "admin" || role === "manager";
    case "none":
      return false;
    default:
      return false;
  }
}

function expectation(role, org, level) {
  if (isOutsider(role, org)) return "deny";
  return roleAllows(role, level) ? "allow" : "deny";
}

function insiderGroup(action, col) {
  if (action === "get" || action === "list") return col.readGroup;
  if (action === "delete") return col.deleteGroup;
  return col.writeGroup;
}

const ORG_COLLECTIONS = [
  { id: "projects", docId: "project-1", read: "member", write: "staff", del: "admin", outsider: "tenant-hole", readGroup: "staff-read", writeGroup: "staff-write", deleteGroup: "admin-delete" },
  { id: "smallWorks", docId: "sw-1", read: "member", write: "staff", del: "admin", outsider: "tenant-hole", readGroup: "staff-read", writeGroup: "staff-write", deleteGroup: "admin-delete" },
  { id: "clients", read: "member", write: "staff", del: "admin", outsider: "tenant-hole", readGroup: "staff-read", writeGroup: "staff-write", deleteGroup: "admin-delete" },
  { id: "operatives", read: "member", write: "staff", del: "admin", outsider: "tenant-hole", readGroup: "staff-read", writeGroup: "staff-write", deleteGroup: "admin-delete" },
  { id: "bookings", read: "member", write: "staff", del: "admin", outsider: "tenant-hole", readGroup: "staff-read", writeGroup: "staff-write", deleteGroup: "admin-delete" },
  { id: "qualifications", read: "member", write: "staff", del: "admin", outsider: "tenant-hole", readGroup: "staff-read", writeGroup: "staff-write", deleteGroup: "admin-delete" },
  { id: "skills", read: "member", write: "staff", del: "admin", outsider: "tenant-hole", readGroup: "staff-read", writeGroup: "staff-write", deleteGroup: "admin-delete" },
  { id: "settings", docId: "jobTypes", read: "member", listLevel: "staff", write: "staff", del: "admin", outsider: "tenant-hole", readGroup: "settings", writeGroup: "settings", deleteGroup: "settings" },
  { id: "tasks", read: "member", write: "member", del: "admin", outsider: "tenant-hole", readGroup: "staff-read", writeGroup: "staff-write", deleteGroup: "admin-delete" },
  { id: "managers", read: "staff", write: "staff", del: "admin", outsider: "tenant-hole", readGroup: "staff-read", writeGroup: "staff-write", deleteGroup: "admin-delete" },
  { id: "notifications", read: "member", write: "staff", del: "admin", outsider: "tenant-hole", readGroup: "notifications", writeGroup: "notifications", deleteGroup: "admin-delete" },
  { id: "materials", read: "member", write: "staff", del: "staff", outsider: "tenant-hole", readGroup: "staff-read", writeGroup: "staff-write", deleteGroup: "admin-delete" },
  { id: "materialCatalogue", read: "staff", write: "staff", del: "staff", outsider: "tenant-hole", readGroup: "staff-read", writeGroup: "staff-write", deleteGroup: "admin-delete" },
  { id: "materialSendRecords", read: "staff", write: "staff", del: "admin", outsider: "tenant-hole", readGroup: "staff-read", writeGroup: "staff-write", deleteGroup: "admin-delete" },
  { id: "wholesalers", read: "staff", write: "staff", del: "staff", outsider: "tenant-hole", readGroup: "staff-read", writeGroup: "staff-write", deleteGroup: "admin-delete" },
  { id: "managerSiteBookings", read: "staff", write: "staff", del: "staff", outsider: "tenant-hole", readGroup: "staff-read", writeGroup: "staff-write", deleteGroup: "admin-delete" },
  { id: "subcontractors", read: "member", write: "staff", del: "admin", outsider: "tenant-hole", readGroup: "staff-read", writeGroup: "staff-write", deleteGroup: "admin-delete" },
  { id: "subcontractorBookings", read: "member", write: "staff", del: "staff", outsider: "tenant-hole", readGroup: "staff-read", writeGroup: "staff-write", deleteGroup: "admin-delete" },
  { id: "holidayBookings", read: "member", write: "member", del: "member", outsider: "holidayBookings", readGroup: "holidayBookings", writeGroup: "holidayBookings", deleteGroup: "holidayBookings" },
  { id: "operativeProfiles", docId: "user-operative", read: "member", write: "operativeOrStaff", del: "staff", outsider: "tenant-hole", readGroup: "staff-read", writeGroup: "staff-write", deleteGroup: "admin-delete" },
  { id: "siteAudits", read: "member", write: "operativeOrStaff", del: "admin", outsider: "tenant-hole", readGroup: "staff-read", writeGroup: "staff-write", deleteGroup: "admin-delete" },
  { id: "variations", read: "assignedStaff", write: "assignedStaff", del: "admin", outsider: "variations", readGroup: "variations", writeGroup: "variations", deleteGroup: "variations" },
  { id: "variationTrackers", docId: "project-1", read: "assignedStaff", write: "assignedStaff", del: "admin", outsider: "variations", readGroup: "variations", writeGroup: "variations", deleteGroup: "variations" },
  { id: "operativeDayRateHistory", read: "staff", write: "staff", del: "admin", outsider: "tenant-hole", readGroup: "staff-read", writeGroup: "staff-write", deleteGroup: "admin-delete" },
  {
    id: "projectHealthSafety",
    docId: "hs-1",
    doc: (org, id) => `organizations/${org}/projects/project-1/healthSafety/${id}`,
    list: (org) => `organizations/${org}/projects/project-1/healthSafety`,
    read: "member",
    write: "staff",
    del: "admin",
    outsider: "tenant-hole",
    readGroup: "staff-read",
    writeGroup: "staff-write",
    deleteGroup: "admin-delete",
  },
  {
    id: "smallWorkHealthSafety",
    docId: "hs-1",
    doc: (org, id) => `organizations/${org}/smallWorks/sw-1/healthSafety/${id}`,
    list: (org) => `organizations/${org}/smallWorks/sw-1/healthSafety`,
    read: "member",
    write: "staff",
    del: "admin",
    outsider: "tenant-hole",
    readGroup: "staff-read",
    writeGroup: "staff-write",
    deleteGroup: "admin-delete",
  },
];

function docPath(col, org, id) {
  const documentId = id || col.docId || "doc-1";
  if (col.doc) return col.doc(org, documentId);
  return `organizations/${org}/${col.id}/${documentId}`;
}

function listPath(col, org) {
  if (col.list) return col.list(org);
  return `organizations/${org}/${col.id}`;
}

function levelFor(col, action) {
  if (action === "list" && col.listLevel) return col.listLevel;
  if (action === "get" || action === "list") return col.read;
  if (action === "delete") return col.del;
  return col.write;
}

function createBody(col, role, org) {
  const uid = uidOf(role);
  const base = { name: "probe", organizationId: org };
  if (col.id === "notifications") {
    return { ...base, type: "warning_removed", title: "Warning issued" };
  }
  if (col.id === "materials") return { ...base, addedByUserId: uid, addedBy: "Probe User" };
  if (col.id === "variations" || col.id === "variationTrackers") {
    return { ...base, status: "open", heading: "probe", parentId: "project-1", orgId: org };
  }
  if (col.id === "holidayBookings") return { ...base, userId: uid, status: "pending" };
  if (col.id === "operativeDayRateHistory") return { ...base, userId: uid, dayRate: 999 };
  if (col.id === "operativeProfiles") return { ...base, userId: uid };
  return base;
}

function updateBody(col, role) {
  if (col.id === "variations" || col.id === "variationTrackers") return { heading: `edited-${role}` };
  if (col.id === "notifications") return { type: "warning_removed", title: `edited-${role}` };
  if (col.id === "operativeDayRateHistory") return { dayRate: 1 };
  return { name: `edited-${role}` };
}

function userRecord(role) {
  const spec = ROLES[role];
  return {
    email: spec.email,
    organizationId: spec.org,
    firstName: role,
    surname: "Tester",
    dayRate: 250,
    hourlyRate: 31.25,
    vatNumber: "GB999999973",
    utrNumber: "1234567890",
    isSuperAdmin: false,
    ...spec.data,
  };
}

function orgRecord(org, memberUids, creatorUid) {
  const members = {};
  for (const uid of memberUids) members[uid] = "member";
  members[creatorUid] = "admin";
  return {
    name: org,
    creatorUserId: creatorUid,
    members,
    warningDetection: { enabled: true, excludedUserIdsFromUnbookedWarnings: [] },
    payrollTimePolicy: { standardDayHours: 8 },
    settings: { invoicing: { currency: "GBP" } },
  };
}

const contexts = new Map();

function dbFor(testEnv, role) {
  if (contexts.has(role)) return contexts.get(role);
  const database = role === "signedOut"
    ? testEnv.unauthenticatedContext().firestore()
    : testEnv.authenticatedContext(ROLES[role].uid, { email: ROLES[role].email }).firestore();
  contexts.set(role, database);
  return database;
}

async function accessResult(promise, expect) {
  if (expect === "deny") {
    try {
      await assertFails(promise);
      return "denied";
    } catch (error) {
      if (/succeeded/i.test(String(error && error.message))) return "allowed";
      return "denied";
    }
  }
  try {
    await assertSucceeds(promise);
    return "allowed";
  } catch {
    return "denied";
  }
}

async function probe(testEnv, { role, action, path, expect, fixGroup, run }) {
  const result = await accessResult(run(dbFor(testEnv, role)), expect);
  if (expect === "deny" && result === "allowed") {
    addGap({ role, action, path, fixGroup });
  } else if (expect === "allow" && result === "denied") {
    notes.push({ role, action, path, fixGroup });
  } else if (expect === "deny") {
    deniedCorrectly += 1;
  } else {
    allowedCorrectly += 1;
  }
}

async function seed(testEnv) {
  const orgAMembers = ["user-admin", "user-manager", "user-operative", "user-qs", "user-sub"];
  const orgBMembers = ["user-other", "user-other-admin"];
  const docs = [];

  docs.push([`organizations/${ORG_A}`, orgRecord(ORG_A, orgAMembers, "user-admin")]);
  docs.push([`organizations/${ORG_B}`, orgRecord(ORG_B, orgBMembers, "user-other-admin")]);

  for (const role of Object.keys(ROLES)) {
    const spec = ROLES[role];
    docs.push([`users/${spec.uid}`, userRecord(role)]);
    docs.push([`users/${spec.uid}/orgMemberships/${spec.org}`, { organizationId: spec.org, role: spec.data.role }]);
  }

  for (const org of [ORG_A, ORG_B]) {
    const managerUserIds = org === ORG_A ? ["user-manager"] : ["user-other-admin"];
    docs.push([`organizations/${org}/projects/project-1`, {
      name: "High Street",
      organizationId: org,
      managerIds: ["mgr-record-1"],
      managerUserIds,
      jobType: "project",
    }]);
    docs.push([`organizations/${org}/projects/project-2`, {
      name: "Unassigned job",
      organizationId: org,
      managerIds: ["someone-else"],
      managerUserIds: ["someone-else"],
      jobType: "project",
    }]);
    docs.push([`organizations/${org}/projects/project-1/healthSafety/hs-1`, { name: "rams", organizationId: org }]);
    docs.push([`organizations/${org}/smallWorks/sw-1`, { name: "Small job", organizationId: org, managerUserIds }]);
    docs.push([`organizations/${org}/smallWorks/sw-1/healthSafety/hs-1`, { name: "rams", organizationId: org }]);
    for (const col of ORG_COLLECTIONS) {
      if (col.id === "projectHealthSafety" || col.id === "smallWorkHealthSafety" || col.id === "projects" || col.id === "smallWorks") {
        continue;
      }
      const data = {
        name: "seed",
        organizationId: org,
        status: "open",
        heading: "Seed variation",
        parentId: "project-1",
        orgId: org,
        addedByUserId: "user-admin",
        addedBy: "Admin Tester",
        userId: col.id === "holidayBookings" ? "user-operative" : "user-admin",
        dayRate: 250,
        type: "task_assigned",
        title: "Seed",
      };
      docs.push([docPath(col, org), data]);
    }
    docs.push([`organizations/${org}/settings/jobTypes`, { types: ["reactive"], organizationId: org }]);
    docs.push([`organizations/${org}/settings/payroll`, { standardDayHours: 8, currency: "GBP", organizationId: org }]);
    docs.push([`organizations/${org}/settings/timesheet_user-operative_1700000000`, {
      userId: "user-operative",
      hours: 8,
      organizationId: org,
    }]);
    docs.push([`organizations/${org}/settings/timesheet_user-manager_1700000000`, {
      userId: "user-manager",
      hours: 40,
      grossPay: 1200,
      organizationId: org,
    }]);
    docs.push([`organizations/${org}/variations/var-assigned`, {
      status: "open",
      parentId: "project-1",
      parentType: "project",
      heading: "Assigned job variation",
      orgId: org,
      organizationId: org,
    }]);
    docs.push([`organizations/${org}/variations/var-unassigned`, {
      status: "open",
      parentId: "project-2",
      parentType: "project",
      heading: "Other job variation",
      orgId: org,
      organizationId: org,
    }]);
    docs.push([`organizations/${org}/userEmails/admin@${org}.test`, { userId: org === ORG_A ? "user-admin" : "user-other-admin" }]);
    docs.push([`organizations/${org}/managers/mgr-record-1`, { userId: managerUserIds[0], email: "manager@test", organizationId: org }]);
  }

  docs.push(["invitations/invite-1", {
    email: "invitee@orga.test",
    organizationId: ORG_A,
    invitedBy: "user-admin",
    role: "operative",
  }]);
  docs.push(["platformConfig/toolboxTalkLibrary", { talks: [{ title: "Ladder safety" }] }]);

  await testEnv.withSecurityRulesDisabled(async (context) => {
    const database = context.firestore();
    for (let index = 0; index < docs.length; index += 20) {
      await Promise.all(docs.slice(index, index + 20).map(([docPathValue, data]) => setDoc(doc(database, docPathValue), data)));
    }
  });
}

async function runCollectionMatrix(testEnv) {
  for (const org of [ORG_A, ORG_B]) {
    for (const col of ORG_COLLECTIONS) {
      for (const role of ACTORS) {
        const path = docPath(col, org);
        const actions = [
          ["get", () => getDoc(doc(dbFor(testEnv, role), path))],
          ["list", () => getDocs(collection(dbFor(testEnv, role), listPath(col, org)))],
          ["create", () => setDoc(doc(dbFor(testEnv, role), docPath(col, org, `create-${role}`)), createBody(col, role, org))],
          ["update", () => updateDoc(doc(dbFor(testEnv, role), path), updateBody(col, role))],
          ["delete", () => deleteDoc(doc(dbFor(testEnv, role), docPath(col, org, `delete-${role}`)))],
        ];
        for (const [action, build] of actions) {
          const expect = expectation(role, org, levelFor(col, action));
          const fixGroup = isOutsider(role, org) ? col.outsider : insiderGroup(action, col);
          await probe(testEnv, {
            role,
            action,
            path: action === "list" ? listPath(col, org) : action === "create" ? docPath(col, org, `create-${role}`) : action === "delete" ? docPath(col, org, `delete-${role}`) : path,
            expect,
            fixGroup,
            run: () => build(),
          });
        }
      }
    }
  }
}

async function runFocusedChecks(testEnv) {
  const payrollReadersDenied = ["operative", "qs", "subcontractor", "otherOrg", "otherOrgAdmin", "signedOut"];
  for (const role of payrollReadersDenied) {
    await probe(testEnv, {
      role,
      action: "get",
      path: `organizations/${ORG_A}/settings/payroll`,
      expect: "deny",
      fixGroup: role === "otherOrg" || role === "otherOrgAdmin" || role === "signedOut" ? "tenant-hole" : "settings",
      run: (database) => getDoc(doc(database, `organizations/${ORG_A}/settings/payroll`)),
    });
  }
  await probe(testEnv, {
    role: "admin",
    action: "get",
    path: `organizations/${ORG_A}/settings/payroll`,
    expect: "allow",
    fixGroup: "settings",
    run: (database) => getDoc(doc(database, `organizations/${ORG_A}/settings/payroll`)),
  });

  const timesheetDenied = ["operative", "qs", "subcontractor", "otherOrg", "otherOrgAdmin", "signedOut"];
  for (const action of ["get", "update"]) {
    for (const role of timesheetDenied) {
      await probe(testEnv, {
        role,
        action,
        path: `organizations/${ORG_A}/settings/timesheet_user-manager_1700000000`,
        expect: "deny",
        fixGroup: "timesheets",
        run: (database) => action === "get"
          ? getDoc(doc(database, `organizations/${ORG_A}/settings/timesheet_user-manager_1700000000`))
          : updateDoc(doc(database, `organizations/${ORG_A}/settings/timesheet_user-manager_1700000000`), { hours: 1 }),
      });
    }
  }
  await probe(testEnv, {
    role: "operative",
    action: "update",
    path: `organizations/${ORG_A}/settings/timesheet_user-operative_1700000000`,
    expect: "allow",
    fixGroup: "timesheets",
    run: (database) => updateDoc(doc(database, `organizations/${ORG_A}/settings/timesheet_user-operative_1700000000`), { hours: 7 }),
  });
  await probe(testEnv, {
    role: "manager",
    action: "update",
    path: `organizations/${ORG_A}/settings/timesheet_user-operative_1700000000`,
    expect: "allow",
    fixGroup: "timesheets",
    run: (database) => updateDoc(doc(database, `organizations/${ORG_A}/settings/timesheet_user-operative_1700000000`), { signedOff: true }),
  });

  const statusDenied = ["operative", "qs", "subcontractor", "otherOrg", "otherOrgAdmin", "signedOut"];
  for (const role of statusDenied) {
    await probe(testEnv, {
      role,
      action: "update-status",
      path: `organizations/${ORG_A}/variations/var-assigned`,
      expect: "deny",
      fixGroup: "variations",
      run: (database) => updateDoc(doc(database, `organizations/${ORG_A}/variations/var-assigned`), { status: "submitted" }),
    });
  }
  await probe(testEnv, {
    role: "manager",
    action: "update-status",
    path: `organizations/${ORG_A}/variations/var-unassigned`,
    expect: "deny",
    fixGroup: "variations",
    run: (database) => updateDoc(doc(database, `organizations/${ORG_A}/variations/var-unassigned`), { status: "submitted" }),
  });
  await probe(testEnv, {
    role: "admin",
    action: "update-status",
    path: `organizations/${ORG_A}/variations/var-assigned`,
    expect: "allow",
    fixGroup: "variations",
    run: (database) => updateDoc(doc(database, `organizations/${ORG_A}/variations/var-assigned`), { status: "submitted" }),
  });
  await probe(testEnv, {
    role: "manager",
    action: "update-status",
    path: `organizations/${ORG_A}/variations/var-assigned`,
    expect: "allow",
    fixGroup: "variations",
    run: (database) => updateDoc(doc(database, `organizations/${ORG_A}/variations/var-assigned`), { status: "closed" }),
  });

  for (const role of ["operative", "qs", "subcontractor", "manager", "otherOrg", "otherOrgAdmin", "signedOut"]) {
    await probe(testEnv, {
      role,
      action: "update",
      path: `organizations/${ORG_A}`,
      expect: "deny",
      fixGroup: role === "otherOrgAdmin" ? "global-admin" : role === "otherOrg" || role === "signedOut" ? "tenant-hole" : "org-doc",
      run: (database) => updateDoc(doc(database, `organizations/${ORG_A}`), {
        warningDetection: { enabled: false, excludedUserIdsFromUnbookedWarnings: [uidOf(role) || "x"] },
      }),
    });
    await probe(testEnv, {
      role,
      action: "update-payroll",
      path: `organizations/${ORG_A}`,
      expect: "deny",
      fixGroup: role === "otherOrgAdmin" ? "global-admin" : role === "otherOrg" || role === "signedOut" ? "tenant-hole" : "org-doc",
      run: (database) => updateDoc(doc(database, `organizations/${ORG_A}`), {
        payrollTimePolicy: { standardDayHours: 4 },
      }),
    });
  }

  for (const role of ACTORS) {
    await probe(testEnv, {
      role,
      action: "delete",
      path: `organizations/${ORG_A}`,
      expect: "deny",
      fixGroup: "org-delete",
      run: (database) => deleteDoc(doc(database, `organizations/${ORG_A}`)),
    });
  }

  for (const role of ["otherOrg", "otherOrgAdmin", "signedOut", "operative", "qs", "subcontractor"]) {
    await probe(testEnv, {
      role,
      action: "get",
      path: "users/user-admin",
      expect: "deny",
      fixGroup: "users-read",
      run: (database) => getDoc(doc(database, "users/user-admin")),
    });
  }
  await probe(testEnv, {
    role: "operative",
    action: "get",
    path: "users/user-operative",
    expect: "allow",
    fixGroup: "users-read",
    run: (database) => getDoc(doc(database, "users/user-operative")),
  });
  await probe(testEnv, {
    role: "manager",
    action: "get",
    path: "users/user-operative",
    expect: "allow",
    fixGroup: "users-read",
    run: (database) => getDoc(doc(database, "users/user-operative")),
  });
  await probe(testEnv, {
    role: "admin",
    action: "get",
    path: "users/user-other",
    expect: "deny",
    fixGroup: "users-read",
    run: (database) => getDoc(doc(database, "users/user-other")),
  });
  for (const role of ["operative", "otherOrg", "otherOrgAdmin", "signedOut", "qs", "subcontractor"]) {
    await probe(testEnv, {
      role,
      action: "list",
      path: "users",
      expect: "deny",
      fixGroup: "users-read",
      run: (database) => getDocs(collection(database, "users")),
    });
  }
  await probe(testEnv, {
    role: "otherOrg",
    action: "query",
    path: `users where organizationId == ${ORG_A}`,
    expect: "deny",
    fixGroup: "users-read",
    run: (database) => getDocs(query(collection(database, "users"), where("organizationId", "==", ORG_A))),
  });

  for (const role of ["operative", "qs", "subcontractor", "otherOrg", "otherOrgAdmin"]) {
    await probe(testEnv, {
      role,
      action: "update-dayRate",
      path: "users/user-manager",
      expect: "deny",
      fixGroup: "users-write",
      run: (database) => updateDoc(doc(database, "users/user-manager"), { dayRate: 1, updatedAt: new Date().toISOString() }),
    });
  }
  for (const role of ["operative", "qs", "subcontractor"]) {
    await probe(testEnv, {
      role,
      action: "self-escalate",
      path: `users/${ROLES[role].uid}`,
      expect: "deny",
      fixGroup: "users-write",
      run: (database) => updateDoc(doc(database, `users/${ROLES[role].uid}`), { adminAccess: true, role: "admin" }),
    });
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(doc(context.firestore(), `users/${ROLES[role].uid}`), userRecord(role));
    });
  }

  for (const role of ["signedOut", "otherOrg", "otherOrgAdmin", "operative", "qs", "subcontractor"]) {
    await probe(testEnv, {
      role,
      action: "get",
      path: "invitations/invite-1",
      expect: "deny",
      fixGroup: "invitations",
      run: (database) => getDoc(doc(database, "invitations/invite-1")),
    });
    await probe(testEnv, {
      role,
      action: "list",
      path: "invitations",
      expect: "deny",
      fixGroup: "invitations",
      run: (database) => getDocs(collection(database, "invitations")),
    });
  }
  for (const role of ["operative", "qs", "subcontractor", "otherOrg", "signedOut"]) {
    await probe(testEnv, {
      role,
      action: "create",
      path: `invitations/created-by-${role}`,
      expect: "deny",
      fixGroup: "invitations",
      run: (database) => setDoc(doc(database, `invitations/created-by-${role}`), {
        email: "new@orga.test",
        organizationId: ORG_A,
        role: "operative",
      }),
    });
  }

  for (const role of ["otherOrg", "otherOrgAdmin", "signedOut"]) {
    await probe(testEnv, {
      role,
      action: "get",
      path: `organizations/${ORG_A}/userEmails/admin@org-a.test`,
      expect: "deny",
      fixGroup: "userEmails",
      run: (database) => getDoc(doc(database, `organizations/${ORG_A}/userEmails/admin@org-a.test`)),
    });
    await probe(testEnv, {
      role,
      action: "create",
      path: `organizations/${ORG_A}/userEmails/intruder@orgb.test`,
      expect: "deny",
      fixGroup: "userEmails",
      run: (database) => setDoc(doc(database, `organizations/${ORG_A}/userEmails/intruder@orgb.test`), {
        userId: uidOf(role) || "anonymous",
      }),
    });
  }

  for (const role of ["otherOrgAdmin", "signedOut", "operative"]) {
    await probe(testEnv, {
      role,
      action: "get",
      path: "users/user-manager/orgMemberships/org-a",
      expect: "deny",
      fixGroup: role === "operative" ? "orgMemberships" : "orgMemberships",
      run: (database) => getDoc(doc(database, "users/user-manager/orgMemberships/org-a")),
    });
  }

  for (const role of ["signedOut"]) {
    await probe(testEnv, {
      role,
      action: "get",
      path: "platformConfig/toolboxTalkLibrary",
      expect: "deny",
      fixGroup: "platformConfig",
      run: (database) => getDoc(doc(database, "platformConfig/toolboxTalkLibrary")),
    });
  }
  for (const role of ["admin", "manager", "operative", "otherOrgAdmin", "qs", "subcontractor"]) {
    await probe(testEnv, {
      role,
      action: "update",
      path: "platformConfig/toolboxTalkLibrary",
      expect: "deny",
      fixGroup: "platformConfig",
      run: (database) => updateDoc(doc(database, "platformConfig/toolboxTalkLibrary"), { talks: [{ title: "tampered" }] }),
    });
  }

  for (const role of ["otherOrg", "otherOrgAdmin", "signedOut"]) {
    await probe(testEnv, {
      role,
      action: "list",
      path: "organizations",
      expect: "deny",
      fixGroup: "org-list",
      run: (database) => getDocs(collection(database, "organizations")),
    });
  }
  await probe(testEnv, {
    role: "otherOrg",
    action: "get",
    path: `organizations/${ORG_A}`,
    expect: "deny",
    fixGroup: "global-admin",
    run: (database) => getDoc(doc(database, `organizations/${ORG_A}`)),
  });
  await probe(testEnv, {
    role: "otherOrgAdmin",
    action: "get",
    path: `organizations/${ORG_A}`,
    expect: "deny",
    fixGroup: "global-admin",
    run: (database) => getDoc(doc(database, `organizations/${ORG_A}`)),
  });

  await probe(testEnv, {
    role: "operative",
    action: "update",
    path: `organizations/${ORG_A}/operativeProfiles/user-manager`,
    expect: "deny",
    fixGroup: "staff-write",
    run: (database) => setDoc(doc(database, `organizations/${ORG_A}/operativeProfiles/user-manager`), {
      name: "taken-over",
      organizationId: ORG_A,
    }),
  });
}

function storageGap() {
  const candidates = ["Project Planner/storage.rules", "website/storage.rules", "storage.rules"];
  if (candidates.some((relative) => existsSync(path.join(root, relative)))) return;
  addGap({
    role: "n/a",
    action: "rules-file",
    path: "Project Planner/storage.rules",
    fixGroup: "storage",
  });
}

function writeReport() {
  storageGap();
  const byGroup = new Map();
  for (const gap of gaps) {
    if (!byGroup.has(gap.fixGroup)) byGroup.set(gap.fixGroup, []);
    byGroup.get(gap.fixGroup).push(gap);
  }
  const lines = [];
  lines.push("# Security rules report");
  lines.push("");
  lines.push("Tested rules file: `Project Planner/firestore.rules`.");
  lines.push("");
  lines.push("That is the file `Project Planner/firebase.json` deploys (`firestore.rules` next to that config). `website/firestore.rules` was not loaded. It is a separate copy and is missing later matches (`materialSendRecords`, `wholesalers`, `platformConfig`, and others).");
  lines.push("");
  lines.push("These results come from `@firebase/rules-unit-testing` against the Firestore emulator. They are not UI tests.");
  lines.push("");
  const criticalCount = byGroup.size;
  lines.push(`Result: ${criticalCount === 0 && sanityFailures.length === 0 ? "PASS" : "FAIL"}.`);
  lines.push("");
  lines.push(`Probes that correctly denied access: ${deniedCorrectly}. Probes that correctly allowed access: ${allowedCorrectly}. Forbidden actions that were allowed: ${gaps.length}, in ${criticalCount} rule group${criticalCount === 1 ? "" : "s"}.`);
  lines.push("");
  if (sanityFailures.length) {
    lines.push("## Sanity failures");
    lines.push("");
    for (const failure of sanityFailures) lines.push(`- ${failure}`);
    lines.push("");
  }
  lines.push("## CRITICAL");
  lines.push("");
  if (criticalCount === 0) {
    lines.push("None. The rules blocked every forbidden action in this run.");
    lines.push("");
  }
  let index = 1;
  for (const [groupId, items] of byGroup) {
    const meta = GROUPS[groupId];
    lines.push(`### ${index}. ${meta ? meta.title : groupId}`);
    lines.push("");
    if (meta) {
      lines.push(`- Rule: \`${meta.rule}\` in \`Project Planner/firestore.rules\``);
      lines.push(`- Lines: ${meta.lines}`);
      lines.push(`- Also: ${meta.also}`);
      lines.push(`- Suggested fix: ${meta.fix}`);
    } else {
      lines.push(`- Rule group \`${groupId}\` has no write-up. Treat the examples as the rule path.`);
    }
    lines.push("");
    lines.push("Examples the emulator allowed:");
    lines.push("");
    const sample = items.slice(0, 12);
    for (const item of sample) {
      lines.push(`- ${item.role} ${item.action} \`${item.path}\``);
    }
    if (items.length > sample.length) {
      lines.push(`- ${items.length - sample.length} more ${groupId} allows were recorded in this run.`);
    }
    lines.push("");
    index += 1;
  }
  if (notes.length) {
    lines.push("## Not CRITICAL");
    lines.push("");
    lines.push("These probes expected an allow and the rules denied it. That is tighter than the product client, not an extra grant. They do not by themselves fail the security assertion.");
    lines.push("");
    for (const note of notes.slice(0, 40)) {
      lines.push(`- ${note.role} ${note.action} \`${note.path}\` was denied`);
    }
    if (notes.length > 40) lines.push(`- ${notes.length - 40} further legitimate allows were denied.`);
    lines.push("");
  }
  writeFileSync(reportPath, lines.join("\n"));
}

test("firestore.rules blocks cross-org access, signed-out reads, and the wrong roles", { timeout: 300000 }, async () => {
  if (!process.env.FIRESTORE_EMULATOR_HOST) {
    throw new Error(
      "FIRESTORE_EMULATOR_HOST is not set. Run npm run test:rules or scripts/test-rules.sh so the Firestore emulator is started."
    );
  }
  if (!existsSync(rulesPath)) {
    throw new Error(`Missing rules file: ${rulesPath}`);
  }
  const [host, portText] = process.env.FIRESTORE_EMULATOR_HOST.split(":");
  const testEnv = await initializeTestEnvironment({
    projectId: "demo-project-planner",
    firestore: {
      rules: readFileSync(rulesPath, "utf8"),
      host,
      port: Number(portText),
    },
  });
  try {
    await testEnv.clearFirestore();
    await seed(testEnv);
    const adminProject = await accessResult(
      getDoc(doc(dbFor(testEnv, "admin"), `organizations/${ORG_A}/projects/project-1`)),
      "allow"
    );
    if (adminProject !== "allowed") {
      sanityFailures.push("Admin of organisation A could not read organizations/org-a/projects/project-1. The rules file did not load or the admin fixture is not recognised.");
    } else {
      allowedCorrectly += 1;
    }
    await runCollectionMatrix(testEnv);
    await runFocusedChecks(testEnv);
  } finally {
    writeReport();
    await testEnv.cleanup();
  }
  assert.equal(
    sanityFailures.length,
    0,
    sanityFailures.join("\n")
  );
  assert.equal(
    gaps.length,
    0,
    `${gaps.length} forbidden actions were allowed. See app-tests/REPORT.md.`
  );
});
