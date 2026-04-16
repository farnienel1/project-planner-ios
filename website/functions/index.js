/**
 * Password reset via Resend (same as the app's "Send password reset" from Manage Users).
 *
 * Two entry points:
 * - Callable: sendProjectPlannerPasswordReset (for Firebase SDK)
 * - HTTP: sendPasswordResetHttp (for fetch() from web – no SDK, works with CORS)
 *
 * One-time setup:
 *   firebase functions:secrets:set RESEND_API_KEY
 *   npm install --prefix functions && firebase deploy --only functions
 */

import { initializeApp } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";
import { onCall, onRequest, HttpsError } from "firebase-functions/v2/https";
import { defineSecret } from "firebase-functions/params";

const resendApiKey = defineSecret("RESEND_API_KEY");

initializeApp();
const db = getFirestore();

const BASE_URL = "https://projectplanner.us";
const FROM_EMAIL = "info@projectplanner.us";

function buildResetEmailHtml(firstName, token) {
  const url = `${BASE_URL}/setup-password.html?token=${encodeURIComponent(token)}`;
  return `<!DOCTYPE html>
<html>
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"></head>
<body style="margin:0;padding:0;font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:#f4f4f5;">
<table width="100%" cellspacing="0" cellpadding="0" style="background:#f4f4f5;padding:40px 20px;">
<tr><td align="center">
<table width="600" cellspacing="0" cellpadding="0" style="max-width:600px;width:100%;background:#fff;border-radius:12px;box-shadow:0 4px 24px rgba(0,0,0,0.08);">
<tr><td style="background:linear-gradient(135deg,#007AFF 0%,#5856D6 100%);padding:28px 32px;text-align:center;">
<h1 style="margin:0;color:#fff;font-size:24px;">Project Planner</h1>
<p style="margin:6px 0 0 0;color:rgba(255,255,255,0.9);font-size:14px;">Project Management for Construction Teams</p>
</td></tr>
<tr><td style="padding:40px 32px;">
<h2 style="margin:0 0 24px 0;color:#111827;font-size:20px;">Reset your password</h2>
<p style="margin:0 0 16px 0;color:#4b5563;font-size:16px;line-height:1.6;">Hello ${firstName},</p>
<p style="margin:0 0 28px 0;color:#4b5563;font-size:16px;line-height:1.6;">We received a request to reset the password for your Project Planner account. Click the button below to choose a new password.</p>
<table width="100%" cellspacing="0" cellpadding="0"><tr><td align="center" style="padding:8px 0 28px 0;">
<a href="${url}" style="display:inline-block;background:linear-gradient(135deg,#007AFF 0%,#0051D5 100%);color:#fff;padding:16px 36px;text-decoration:none;font-size:16px;font-weight:600;border-radius:8px;">Reset password</a>
</td></tr></table>
<p style="margin:0 0 8px 0;color:#6b7280;font-size:13px;">If the button doesn't work, copy this link: ${url}</p>
<div style="background:#fef3c7;border:1px solid #fcd34d;border-radius:8px;padding:14px 16px;">
<p style="margin:0;color:#92400e;font-size:13px;"><strong>Security:</strong> This link expires in 7 days.</p>
</div>
</td></tr>
<tr><td style="padding:24px 32px;background:#f9fafb;border-top:1px solid #e5e7eb;">
<p style="margin:0;color:#9ca3af;font-size:12px;text-align:center;">This email was sent by Project Planner.</p>
</td></tr>
</table>
</td></tr>
</table>
</body>
</html>`;
}

async function sendResetEmailForAddress(email, apiKey) {
  const emailTrimmed = email.trim().toLowerCase();
  const emailOriginal = email.trim();
  if (!emailTrimmed) return { sent: false, reason: "invalid" };

  const usersSnap = await db.collection("users")
    .where("email", "==", emailTrimmed)
    .limit(2)
    .get();

  let userDoc = usersSnap.docs[0];
  if (!userDoc && emailOriginal !== emailTrimmed) {
    const altSnap = await db.collection("users")
      .where("email", "==", emailOriginal)
      .limit(1)
      .get();
    userDoc = altSnap.docs[0];
  }

  if (!userDoc) return { sent: false, reason: "not_found" };

  const data = userDoc.data();
  const organizationId = data.organizationId;
  const firstName = data.firstName || "there";
  const mobileNumber = data.mobileNumber || null;
  if (!organizationId) return { sent: false, reason: "no_org" };

  let orgName = null;
  try {
    const orgSnap = await db.collection("organizations").doc(organizationId).get();
    if (orgSnap.exists) orgName = orgSnap.data().name;
  } catch (_) {}

  const invitationId = crypto.randomUUID();
  const permissions = data.permissions || {};
  const invitationData = {
    email: data.email || emailTrimmed,
    organizationId,
    invitedBy: "",
    firstName: data.firstName || "",
    surname: data.surname || "",
    permissions: {
      adminAccess: permissions.adminAccess ?? false,
      manager: permissions.manager ?? false,
      operatives: permissions.operatives ?? false,
      skills: permissions.skills ?? false,
      qualifications: permissions.qualifications ?? false,
      operativeMode: permissions.operativeMode ?? false,
    },
    createdAt: new Date(),
    isUsed: false,
  };
  if (mobileNumber) invitationData.mobileNumber = mobileNumber;
  await db.collection("invitations").doc(invitationId).set(invitationData);

  const fromDisplay = orgName ? `${orgName} <${FROM_EMAIL}>` : `Project Planner <${FROM_EMAIL}>`;
  const body = JSON.stringify({
    from: fromDisplay,
    to: [data.email || emailTrimmed],
    subject: "Reset Your Project Planner Password",
    html: buildResetEmailHtml(firstName, invitationId),
  });

  const res = await fetch("https://api.resend.com/emails", {
    method: "POST",
    headers: {
      Authorization: `Bearer ${apiKey}`,
      "Content-Type": "application/json",
    },
    body,
  });

  if (!res.ok) {
    const errText = await res.text();
    console.error("Resend API error:", res.status, errText);
    return { sent: false, reason: "resend_error" };
  }

  return { sent: true };
}

export const sendProjectPlannerPasswordReset = onCall(
  { region: "us-central1", secrets: [resendApiKey] },
  async (request) => {
    const email = request.data?.email;
    if (!email || typeof email !== "string") {
      throw new HttpsError("invalid-argument", "Email is required.");
    }
    const apiKey = resendApiKey.value();
    if (!apiKey) {
      throw new HttpsError(
        "failed-precondition",
        "Password reset is not set up. Ask your administrator to send the reset from the app: Manage Users → your email → Send password reset."
      );
    }
    const result = await sendResetEmailForAddress(email.trim(), apiKey);
    if (result.sent) return { sent: true };
    if (result.reason === "resend_error") {
      throw new HttpsError(
        "internal",
        "Could not send email. Ask your administrator to send the reset from the app (Manage Users → Send password reset)."
      );
    }
    return { sent: false, reason: result.reason };
  }
);

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "Content-Type",
  "Access-Control-Max-Age": "86400",
};

export const sendPasswordResetHttp = onRequest(
  { region: "us-central1", secrets: [resendApiKey] },
  async (req, res) => {
    res.set("Access-Control-Allow-Origin", "*");
    if (req.method === "OPTIONS") {
      res.set("Access-Control-Allow-Methods", "POST, OPTIONS");
      res.set("Access-Control-Allow-Headers", "Content-Type");
      res.status(204).send("");
      return;
    }
    if (req.method !== "POST") {
      res.status(405).set("Access-Control-Allow-Origin", "*").json({ error: "Method not allowed" });
      return;
    }
    let email = null;
    try {
      const body = req.body;
      if (body && typeof body.email === "string") email = body.email;
      if (!email && typeof body === "string") {
        const parsed = JSON.parse(body);
        email = parsed && parsed.email;
      }
    } catch (_) {}
    if (!email || !email.trim()) {
      res.status(400).set("Access-Control-Allow-Origin", "*").json({ sent: false, error: "Email is required" });
      return;
    }
    const apiKey = resendApiKey.value();
    if (!apiKey) {
      res.status(503).set("Access-Control-Allow-Origin", "*").json({ sent: false, error: "Not configured" });
      return;
    }
    const result = await sendResetEmailForAddress(email, apiKey);
    res.set("Access-Control-Allow-Origin", "*").status(200).json(result);
  }
);
