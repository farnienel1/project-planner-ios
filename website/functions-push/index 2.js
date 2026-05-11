/**
 * FCM/APNs push when a targeted notification is created under an organization.
 * Separate codebase from `functions/` so deploy does not require Secret Manager (RESEND).
 */
import { initializeApp } from "firebase-admin/app";
import { getFirestore } from "firebase-admin/firestore";
import { getMessaging } from "firebase-admin/messaging";
import { onDocumentCreated } from "firebase-functions/v2/firestore";

initializeApp();
const db = getFirestore();

function extractPushTokens(userData) {
  const out = new Set();
  if (typeof userData?.pushToken === "string" && userData.pushToken.trim()) {
    out.add(userData.pushToken.trim());
  }
  if (Array.isArray(userData?.pushTokens)) {
    for (const token of userData.pushTokens) {
      if (typeof token === "string" && token.trim()) {
        out.add(token.trim());
      }
    }
  }
  return [...out];
}

// Same region as Firestore (see firebase-debug: database locationId europe-west2) so Eventarc trigger setup is reliable.
export const sendNotificationPush = onDocumentCreated(
  {
    region: "europe-west2",
    document: "organizations/{organizationId}/notifications/{notificationId}",
  },
  async (event) => {
    const data = event.data?.data();
    if (!data) return;
    const notificationId = event.params.notificationId;
    const organizationId = event.params.organizationId;
    const notificationRef = db
      .collection("organizations")
      .doc(organizationId)
      .collection("notifications")
      .doc(notificationId);

    const targetUserId = typeof data.userId === "string" ? data.userId.trim() : "";
    if (!targetUserId) return;

    const userDoc = await db.collection("users").doc(targetUserId).get();
    if (!userDoc.exists) {
      console.log("Push target user missing:", targetUserId);
      await notificationRef.set(
        {
          pushDelivery: {
            status: "target_user_missing",
            targetUserId,
            attemptedAt: new Date().toISOString(),
          },
        },
        { merge: true }
      );
      return;
    }
    const userData = userDoc.data() || {};
    let tokens = extractPushTokens(userData);
    const normalizedEmail =
      typeof userData.email === "string" ? userData.email.trim().toLowerCase() : "";
    // Tokens are registered under `users/{authUid}` after sign-in; some notification paths still used a legacy
    // invitation document id. Union tokens from every user row with the same email.
    if (!tokens.length && normalizedEmail) {
      const orgUsers = await db
        .collection("users")
        .where("organizationId", "==", event.params.organizationId)
        .limit(300)
        .get();
      const merged = new Set();
      for (const d of orgUsers.docs) {
        const row = d.data() || {};
        const rowEmail = typeof row.email === "string" ? row.email.trim().toLowerCase() : "";
        if (rowEmail !== normalizedEmail) continue;
        for (const t of extractPushTokens(d.data())) {
          merged.add(t);
        }
      }
      tokens = [...merged];
    }
    if (!tokens.length) {
      console.log("No push tokens for user:", targetUserId, normalizedEmail ? `(email ${normalizedEmail})` : "");
      await notificationRef.set(
        {
          pushDelivery: {
            status: "no_tokens",
            targetUserId,
            normalizedEmail,
            attemptedAt: new Date().toISOString(),
          },
        },
        { merge: true }
      );
      return;
    }

    const title = typeof data.title === "string" && data.title.trim() ? data.title : "Project Planner";
    const body =
      typeof data.message === "string" && data.message.trim() ? data.message : "You have a new update.";
    const type = typeof data.type === "string" ? data.type : "general";
    const relatedId = typeof data.relatedId === "string" ? data.relatedId : "";
    console.log("Push trigger received", {
      organizationId,
      notificationId,
      targetUserId,
      type,
      tokenCount: tokens.length,
    });

    const message = {
      tokens,
      notification: { title, body },
      data: {
        notificationId,
        organizationId,
        type,
        userId: targetUserId,
        relatedId,
      },
      apns: {
        headers: {
          "apns-push-type": "alert",
          "apns-priority": "10",
          "apns-topic": "farnie.Project-Planner",
        },
        payload: {
          aps: {
            sound: "default",
            badge: 1,
          },
        },
      },
    };

    const response = await getMessaging().sendEachForMulticast(message);
    console.log("Push send result", {
      targetUserId,
      total: tokens.length,
      success: response.successCount,
      failure: response.failureCount,
    });

    const invalidTokens = [];
    const failureDetails = [];
    response.responses.forEach((r, index) => {
      if (!r.success) {
        const code = r.error?.code || "";
        const msg = r.error?.message || "";
        failureDetails.push({
          tokenIndex: index,
          tokenSuffix: tokens[index]?.slice(-10) || "unknown",
          code,
          message: msg,
        });
        console.log("Push token failure", {
          targetUserId,
          tokenIndex: index,
          tokenSuffix: tokens[index]?.slice(-10) || "unknown",
          code,
          message: msg,
        });
        if (
          code.includes("registration-token-not-registered") ||
          code.includes("invalid-registration-token")
        ) {
          invalidTokens.push(tokens[index]);
        }
      }
    });

    await notificationRef.set(
      {
        pushDelivery: {
          status: response.failureCount > 0 ? "partial_or_failed" : "sent",
          targetUserId,
          tokenCount: tokens.length,
          successCount: response.successCount,
          failureCount: response.failureCount,
          failureDetails,
          attemptedAt: new Date().toISOString(),
        },
      },
      { merge: true }
    );

    if (invalidTokens.length) {
      await db.collection("users").doc(targetUserId).set(
        {
          pushTokens: tokens.filter((t) => !invalidTokens.includes(t)),
        },
        { merge: true }
      );
    }
  }
);
