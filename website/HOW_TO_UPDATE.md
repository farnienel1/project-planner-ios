# How to Update Your Website on Netlify

After your website is initially deployed, here's how to update it when you make changes.

## Method 1: Drag and Drop (Simplest)

1. Make your changes to the website files on your Mac
2. Create a new ZIP file with all your website files
3. Go to app.netlify.com
4. Click on your deployed site
5. Go to the Deploys tab
6. Drag and drop your new ZIP file
7. Wait for deployment to complete (shows "Published" when done)

## Method 2: Deploy Manually Button

1. Make your changes to the website files on your Mac
2. Create a new ZIP file with all your website files
3. Go to app.netlify.com
4. Click on your deployed site
5. Go to the Deploys tab
6. Click "Deploy manually" button
7. Click "Browse" and select your ZIP file
8. Wait for deployment to complete

## What Happens When You Update

- Netlify automatically replaces all your old files with the new ones
- Your website URL stays the same
- The update usually takes 30-60 seconds
- You'll see "Published" status when it's done
- Your changes are live immediately

## Important Notes

- You must include ALL files in your ZIP, not just the ones you changed
- The ZIP structure should be the same as before (HTML files in the root)
- If you only change one file, still upload all files together
- Your website URL does not change when you update

## Example: Updating Firebase Config

1. Edit setup-password.html, reset-password.html, and reset-password-complete.html with new Firebase config
2. Save all files
3. Select all files in website folder (Cmd+A)
4. Create ZIP file
5. Upload to Netlify via drag and drop
6. Wait for deployment
7. Test your website to verify changes

## Viewing Deployment History

1. In Netlify, click on your site
2. Go to Deploys tab
3. You'll see a list of all deployments with timestamps
4. Each deployment shows when it was published
5. You can click on any deployment to see details

## Rolling Back to Previous Version

If something goes wrong with an update:

1. Go to Deploys tab in Netlify
2. Find the previous deployment that was working
3. Click on that deployment
4. Click "Publish deploy" button
5. This will restore your site to that previous version







