import { initializeApp } from 'https://www.gstatic.com/firebasejs/10.7.1/firebase-app.js';
import { getAuth, signOut, onAuthStateChanged } from 'https://www.gstatic.com/firebasejs/10.7.1/firebase-auth.js';
import { getFirestore, doc, getDoc, collection, query, where, getDocs } from 'https://www.gstatic.com/firebasejs/10.7.1/firebase-firestore.js';

// Firebase config
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

let currentUser = null;
let userData = null;
let organizationData = null;

// Check authentication
onAuthStateChanged(auth, async (user) => {
    if (!user) {
        window.location.href = 'login.html';
        return;
    }
    
    currentUser = user;
    sessionStorage.setItem('userId', user.uid);
    
    await loadUserData();
    await loadOrganizationData();
    updateDashboard();
});

async function loadUserData() {
    try {
        const userId = currentUser.uid;
        const userDoc = await getDoc(doc(db, 'users', userId));
        
        if (userDoc.exists()) {
            userData = userDoc.data();
            return userData;
        } else {
            console.error('User document not found');
            return null;
        }
    } catch (error) {
        console.error('Error loading user data:', error);
        return null;
    }
}

async function loadOrganizationData() {
    try {
        if (!userData || !userData.organizationId) {
            return;
        }
        
        const orgDoc = await getDoc(doc(db, 'organizations', userData.organizationId));
        
        if (orgDoc.exists()) {
            organizationData = orgDoc.data();
            return organizationData;
        } else {
            console.error('Organization document not found');
            return null;
        }
    } catch (error) {
        console.error('Error loading organization data:', error);
        return null;
    }
}

async function loadProjects() {
    try {
        if (!userData || !userData.organizationId) {
            return 0;
        }
        
        const projectsRef = collection(db, 'organizations', userData.organizationId, 'projects');
        const projectsSnapshot = await getDocs(projectsRef);
        
        let liveCount = 0;
        projectsSnapshot.forEach((doc) => {
            const data = doc.data();
            if (data.isLive === true) {
                liveCount++;
            }
        });
        
        return liveCount;
    } catch (error) {
        console.error('Error loading projects:', error);
        return 0;
    }
}

async function loadManagers() {
    try {
        if (!userData || !userData.organizationId) {
            return 0;
        }
        
        const managersRef = collection(db, 'organizations', userData.organizationId, 'managers');
        const managersSnapshot = await getDocs(managersRef);
        
        return managersSnapshot.size;
    } catch (error) {
        console.error('Error loading managers:', error);
        return 0;
    }
}

async function loadOperatives() {
    try {
        if (!userData || !userData.organizationId) {
            return 0;
        }
        
        const operativesRef = collection(db, 'organizations', userData.organizationId, 'operatives');
        const operativesSnapshot = await getDocs(operativesRef);
        
        return operativesSnapshot.size;
    } catch (error) {
        console.error('Error loading operatives:', error);
        return 0;
    }
}

function updateDashboard() {
    if (!userData || !organizationData) {
        document.getElementById('welcomeText').textContent = 'Loading...';
        document.getElementById('orgName').textContent = 'Loading organization...';
        return;
    }
    
    // Welcome message
    const firstName = userData.firstName || '';
    const welcomeName = firstName ? firstName : userData.email.split('@')[0];
    document.getElementById('welcomeText').textContent = `Welcome back, ${welcomeName}`;
    document.getElementById('orgName').textContent = organizationData.name || 'Organization';
    
    // Check permissions and show/hide cards
    const hasOperativesAccess = userData.operatives === true || userData.isSuperAdmin === true;
    const hasAdminAccess = userData.adminAccess === true || userData.isSuperAdmin === true;
    
    if (hasOperativesAccess || hasAdminAccess) {
        document.getElementById('operativesCard').style.display = 'block';
        loadOperatives().then(count => {
            document.getElementById('operativesCount').textContent = `${count} operative${count !== 1 ? 's' : ''}`;
        });
    }
    
    if (hasAdminAccess) {
        document.getElementById('managersCard').style.display = 'block';
        loadManagers().then(count => {
            document.getElementById('managersCount').textContent = `${count} manager${count !== 1 ? 's' : ''}`;
        });
    }
    
    // Always show projects
    loadProjects().then(count => {
        document.getElementById('projectsCount').textContent = `${count} live project${count !== 1 ? 's' : ''}`;
    });
}

function navigateTo(page) {
    window.location.href = `${page}.html`;
}

function showAccountMenu() {
    document.getElementById('accountMenu').style.display = 'block';
}

function hideAccountMenu() {
    document.getElementById('accountMenu').style.display = 'none';
}

async function logout() {
    try {
        await signOut(auth);
        sessionStorage.removeItem('userId');
        window.location.href = 'login.html';
    } catch (error) {
        console.error('Error signing out:', error);
        alert('Failed to sign out. Please try again.');
    }
}

// Make functions globally available
window.navigateTo = navigateTo;
window.showAccountMenu = showAccountMenu;
window.hideAccountMenu = hideAccountMenu;
window.logout = logout;

