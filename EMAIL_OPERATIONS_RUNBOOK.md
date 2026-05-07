# Email Operations Runbook

This runbook keeps email delivery stable without app updates.

## Architecture (Production)

- App sends email via Firebase Function: `sendProjectPlannerEmail`
- Firebase Function uses Secret Manager key: `RESEND_API_KEY`
- App-side direct Resend calls are DEBUG fallback only

## Initial One-Time Setup

1. Create a dedicated production API key in Resend:
   - Name: `resend-prod-functions`
   - Scope: send-only, minimum permissions
2. Set key in Firebase secrets:
   - `npx firebase-tools functions:secrets:set RESEND_API_KEY --project project-planner-f986c`
3. Set health-check recipient:
   - `npx firebase-tools functions:params:set EMAIL_HEALTHCHECK_TO="ops@yourdomain.com" --project project-planner-f986c`
4. Deploy:
   - `npx firebase-tools deploy --only functions --project project-planner-f986c`

## Monitoring and Alerts

## Failure telemetry in Firestore

Function failures are written to `emailDeliveryFailures` with:

- `channel`
- `to`
- `status`
- `errorText`
- `category` (`auth_or_rate_limit` or `delivery_error`)
- `createdAt`

### Recommended alert rules

1. Cloud Logging alert:
   - match: `sendProjectPlannerEmail Resend error`
   - threshold: >= 1 in 5 minutes
2. Firestore/BigQuery dashboard:
   - track `emailDeliveryFailures` daily count and status buckets
3. Resend alert:
   - monitor spikes in 401, 403, 429

## Key Rotation (Monthly or Quarterly)

1. Create new Resend key (`resend-prod-functions-<date>`)
2. Update secret:
   - `npx firebase-tools functions:secrets:set RESEND_API_KEY --project project-planner-f986c`
3. Redeploy functions:
   - `npx firebase-tools deploy --only functions --project project-planner-f986c`
4. Verify:
   - invite email
   - password reset email
   - material order email
   - quote email
5. Revoke old key in Resend

## Daily Health Check

- Function `sendDailyEmailHealthCheck` runs daily at 08:00 Europe/London
- Sends test mail to `EMAIL_HEALTHCHECK_TO`
- Logs failures to `emailDeliveryFailures`

## Fallback Sender Domain

Keep at least one verified sender/domain active in Resend at all times:

- primary: `info@projectplanner.us`
- fallback: another verified sender/domain in same account

## Incident Playbook

If emails fail:

1. Check function logs:
   - `npx firebase-tools functions:log --project project-planner-f986c`
2. Check Resend logs for matching timestamps
3. Rotate key if 401/403
4. Retry and verify four core flows
