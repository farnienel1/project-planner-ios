import { initializeApp } from 'https://www.gstatic.com/firebasejs/10.7.1/firebase-app.js';
import { getAuth, onAuthStateChanged } from 'https://www.gstatic.com/firebasejs/10.7.1/firebase-auth.js';
import { getFirestore, collection, getDocs, doc, getDoc } from 'https://www.gstatic.com/firebasejs/10.7.1/firebase-firestore.js';

const firebaseConfig = {
    apiKey: "AIzaSyCPafzxnt3q2Q_xQ4N6BYrhNyUOJSiL1Yc",
    authDomain: "project-planner-f986c.firebaseapp.com",
    projectId: "project-planner-f986c",
    storageBucket: "project-planner-f986c.appspot.com",
    messagingSenderId: "980527300983",
    appId: "1:980527300983:web:project-planner"
};

const app = initializeApp(firebaseConfig);
const auth = getAuth(app);
const db = getFirestore(app);

let userData = null;

onAuthStateChanged(auth, async (user) => {
    if (!user) {
        window.location.href = 'login.html';
        return;
    }
    
    await loadUserData();
    checkPermissionsAndLoad();
});

async function loadUserData() {
    try {
        const userDoc = await getDoc(doc(db, 'users', auth.currentUser.uid));
        if (userDoc.exists()) {
            userData = userDoc.data();
        }
    } catch (error) {
        console.error('Error loading user data:', error);
    }
}

function checkPermissionsAndLoad() {
    const hasAdminAccess = userData?.adminAccess === true || userData?.isSuperAdmin === true;
    
    if (!hasAdminAccess) {
        document.getElementById('managersList').innerHTML = 
            '<div class="empty-state"><p>You do not have permission to view managers.</p></div>';
        return;
    }
    
    loadManagers();
}

async function loadManagers() {
    const container = document.getElementById('managersList');
    
    try {
        if (!userData || !userData.organizationId) {
            container.innerHTML = '<div class="empty-state"><p>No organization found.</p></div>';
            return;
        }
        
        const managersRef = collection(db, 'organizations', userData.organizationId, 'managers');
        const managersSnapshot = await getDocs(managersRef);
        
        const managers = [];
        managersSnapshot.forEach((doc) => {
            const data = doc.data();
            if (data.isActive !== false) {
                managers.push({ id: doc.id, ...data });
            }
        });
        
        if (managers.length === 0) {
            container.innerHTML = '<div class="empty-state"><p>No managers found.</p></div>';
            return;
        }
        
        container.innerHTML = managers.map(manager => {
            const firstName = manager.firstName || '';
            const lastName = manager.lastName || '';
            const fullName = `${firstName} ${lastName}`.trim() || 'Unnamed Manager';
            
            return `
                <div class="list-item">
                    <h3>${fullName}</h3>
                    <p style="margin-top: 8px; color: #666;">
                        ${manager.email ? `<strong>Email:</strong> ${manager.email}<br>` : ''}
                        ${manager.mobileNumber ? `<strong>Mobile:</strong> ${manager.mobileNumber}<br>` : ''}
                        ${manager.department ? `<strong>Department:</strong> ${manager.department}` : ''}
                    </p>
                </div>
            `;
        }).join('');
        
    } catch (error) {
        console.error('Error loading managers:', error);
        container.innerHTML = '<div class="empty-state"><p>Failed to load managers.</p></div>';
    }
}

