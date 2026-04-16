# Enable Firebase Cloud Storage for Project Planner

Firebase Storage is now added to the app target in Xcode. To use task file/image uploads, enable Cloud Storage and deploy rules.

## 1. Enable Cloud Storage in Firebase Console

1. Open [Firebase Console](https://console.firebase.google.com/) and select your **Project Planner** project.
2. In the left sidebar, click **Build** → **Storage** (or **Storage** under “Build”).
3. If you see **Get started**, click it to enable Cloud Storage.
4. Choose **Start in production mode** (we use custom rules below). Pick a location if prompted (e.g. same as Firestore).
5. Click **Done**. Your default Storage bucket is now created.

## 2. Deploy Storage rules

The project includes `Project Planner/storage.rules` so only authenticated users can read/write task files.

From the project root (where `firebase.json` or `.firebaserc` lives):

```bash
firebase deploy --only storage
```

If you haven’t linked Firebase CLI to this project:

```bash
firebase login
firebase use <your-project-id>
firebase deploy --only storage
```

## 3. Confirm in the app

- Build and run in Xcode (FirebaseStorage is linked to the app target).
- Add or complete a task and attach an image or file. It should upload to Storage and be visible to users with access to that task.

## Summary

| Step | Action |
|------|--------|
| Xcode | ✅ FirebaseStorage added to app target (already done) |
| Firebase Console | Enable Storage (Build → Storage → Get started) |
| CLI | Run `firebase deploy --only storage` to deploy rules |
