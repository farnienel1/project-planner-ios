import { initializeApp } from 'https://www.gstatic.com/firebasejs/10.7.1/firebase-app.js';
import { getAuth, onAuthStateChanged } from 'https://www.gstatic.com/firebasejs/10.7.1/firebase-auth.js';
import { getFirestore, doc, getDoc } from 'https://www.gstatic.com/firebasejs/10.7.1/firebase-firestore.js';

const firebaseConfig = {
    apiKey: "AIzaSyCPafzxnt3q2Q_xQ4N6BYrhNyUOJSiL1Yc",
    authDomain: "project-planner-f986c.firebaseapp.com",
    projectId: "project-planner-f986c",
    storageBucket: "project-planner-f986c.appspot.com",
    messagingSenderId: "980527300983",
    appId: "1:980527300983:web:89bd0c7a69881d1b1be172"
};

const app = initializeApp(firebaseConfig);
const auth = getAuth(app);
const db = getFirestore(app);

let currentUser = null;
let userData = null;
let organizationData = null;

onAuthStateChanged(auth, async (user) => {
    if (!user) {
        window.location.href = 'login.html';
        return;
    }
    
    currentUser = user;
    await loadUserData();
    await loadOrganizationData();
    renderSettings();
});

async function loadUserData() {
    try {
        const userDoc = await getDoc(doc(db, 'users', currentUser.uid));
        if (userDoc.exists()) {
            userData = userDoc.data();
            return userData;
        }
    } catch (error) {
        console.error('Error loading user data:', error);
    }
    return null;
}

async function loadOrganizationData() {
    try {
        if (!userData || !userData.organizationId) return;
        const orgDoc = await getDoc(doc(db, 'organizations', userData.organizationId));
        if (orgDoc.exists()) {
            organizationData = orgDoc.data();
            return organizationData;
        }
    } catch (error) {
        console.error('Error loading organization data:', error);
    }
    return null;
}

function renderSettings() {
    const container = document.getElementById('settingsContent');
    
    if (!userData || !organizationData) {
        container.innerHTML = '<div class="error">Failed to load account information.</div>';
        return;
    }
    
    const firstName = userData.firstName || '';
    const surname = userData.surname || '';
    const fullName = `${firstName} ${surname}`.trim() || 'Not set';
    const email = userData.email || currentUser.email || 'Not available';
    const orgName = organizationData.name || 'Not available';
    const role = userData.isSuperAdmin ? 'Super Admin' : (userData.role || 'User');
    
    container.innerHTML = `
        <div class="settings-section">
            <h3 style="font-size: 18px; margin-bottom: 16px; color: #1d1d1f;">Personal Information</h3>
            
            <div style="margin-bottom: 24px;">
                <label style="display: block; font-size: 14px; color: #666; margin-bottom: 8px;">Name</label>
                <div style="padding: 12px; background: #f5f5f7; border-radius: 8px; font-size: 16px;">
                    ${fullName}
                </div>
            </div>
            
            <div style="margin-bottom: 24px;">
                <label style="display: block; font-size: 14px; color: #666; margin-bottom: 8px;">Email</label>
                <div style="padding: 12px; background: #f5f5f7; border-radius: 8px; font-size: 16px;">
                    ${email}
                </div>
            </div>
            
            <div style="margin-bottom: 24px;">
                <label style="display: block; font-size: 14px; color: #666; margin-bottom: 8px;">Role</label>
                <div style="padding: 12px; background: #f5f5f7; border-radius: 8px; font-size: 16px;">
                    ${role}
                </div>
            </div>
        </div>
        
        <div class="settings-section" style="margin-top: 32px; padding-top: 32px; border-top: 1px solid #e5e5e7;">
            <h3 style="font-size: 18px; margin-bottom: 16px; color: #1d1d1f;">Organization</h3>
            
            <div style="margin-bottom: 24px;">
                <label style="display: block; font-size: 14px; color: #666; margin-bottom: 8px;">Organization Name</label>
                <div style="padding: 12px; background: #f5f5f7; border-radius: 8px; font-size: 16px;">
                    ${orgName}
                </div>
            </div>
        </div>
        
        <div class="settings-section" style="margin-top: 32px; padding-top: 32px; border-top: 1px solid #e5e5e7;">
            <h3 style="font-size: 18px; margin-bottom: 16px; color: #1d1d1f;">Security</h3>
            
            <a href="reset-password.html" style="display: block; padding: 16px; background: #007AFF; color: white; text-align: center; border-radius: 8px; text-decoration: none; font-weight: 600; margin-top: 8px;">
                Change Password
            </a>
        </div>
        
        <div class="settings-section" style="margin-top: 32px; padding-top: 32px; border-top: 1px solid #e5e5e7;">
            <h3 style="font-size: 18px; margin-bottom: 16px; color: #1d1d1f;">Permissions</h3>
            
            <div style="display: flex; flex-direction: column; gap: 12px;">
                <div style="padding: 12px; background: ${userData.adminAccess || userData.isSuperAdmin ? '#e8f5e9' : '#fff3e0'}; border-radius: 8px;">
                    <div style="font-weight: 600; margin-bottom: 4px;">Admin Access</div>
                    <div style="font-size: 14px; color: #666;">
                        ${userData.adminAccess || userData.isSuperAdmin ? '✓ Enabled' : '✗ Disabled'}
                    </div>
                </div>
                
                <div style="padding: 12px; background: ${userData.operatives || userData.isSuperAdmin ? '#e8f5e9' : '#fff3e0'}; border-radius: 8px;">
                    <div style="font-weight: 600; margin-bottom: 4px;">Operatives</div>
                    <div style="font-size: 14px; color: #666;">
                        ${userData.operatives || userData.isSuperAdmin ? '✓ Enabled' : '✗ Disabled'}
                    </div>
                </div>
                
                <div style="padding: 12px; background: ${userData.skills || userData.isSuperAdmin ? '#e8f5e9' : '#fff3e0'}; border-radius: 8px;">
                    <div style="font-weight: 600; margin-bottom: 4px;">Skills</div>
                    <div style="font-size: 14px; color: #666;">
                        ${userData.skills || userData.isSuperAdmin ? '✓ Enabled' : '✗ Disabled'}
                    </div>
                </div>
                
                <div style="padding: 12px; background: ${userData.qualifications || userData.isSuperAdmin ? '#e8f5e9' : '#fff3e0'}; border-radius: 8px;">
                    <div style="font-weight: 600; margin-bottom: 4px;">Qualifications</div>
                    <div style="font-size: 14px; color: #666;">
                        ${userData.qualifications || userData.isSuperAdmin ? '✓ Enabled' : '✗ Disabled'}
                    </div>
                </div>
            </div>
        </div>
    `;
}

