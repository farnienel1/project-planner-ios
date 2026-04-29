import { initializeApp } from 'https://www.gstatic.com/firebasejs/10.7.1/firebase-app.js';
import { getAuth, onAuthStateChanged } from 'https://www.gstatic.com/firebasejs/10.7.1/firebase-auth.js';
import { getFirestore, collection, query, where, getDocs, doc, getDoc } from 'https://www.gstatic.com/firebasejs/10.7.1/firebase-firestore.js';

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

let userData = null;

onAuthStateChanged(auth, async (user) => {
    if (!user) {
        window.location.href = 'login.html';
        return;
    }
    
    await loadUserData();
    await loadProjects();
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

async function loadProjects() {
    const container = document.getElementById('projectsList');
    
    try {
        if (!userData || !userData.organizationId) {
            container.innerHTML = '<div class="empty-state"><p>No organization found.</p></div>';
            return;
        }
        
        const projectsRef = collection(db, 'organizations', userData.organizationId, 'projects');
        const projectsSnapshot = await getDocs(projectsRef);
        
        const projects = [];
        projectsSnapshot.forEach((doc) => {
            const data = doc.data();
            if (data.isLive === true) {
                projects.push({ id: doc.id, ...data });
            }
        });
        
        if (projects.length === 0) {
            container.innerHTML = '<div class="empty-state"><p>No live projects found.</p></div>';
            return;
        }
        
        container.innerHTML = projects.map(project => {
            const siteAddress = project.addressLine1 
                ? `${project.addressLine1}${project.addressLine2 ? ', ' + project.addressLine2 : ''}, ${project.townCity || ''} ${project.postcode || ''}`.trim()
                : (project.siteAddress || 'Address not set');
            
            const startDate = project.startDate?.toDate ? new Date(project.startDate.toDate()) : new Date();
            const endDate = project.endDate?.toDate ? new Date(project.endDate.toDate()) : new Date();
            
            return `
                <div class="list-item">
                    <h3>${project.siteName || 'Unnamed Project'}</h3>
                    <p style="margin-top: 8px; color: #666;">
                        <strong>Job Number:</strong> ${project.jobNumber || 'N/A'}<br>
                        <strong>Address:</strong> ${siteAddress}<br>
                        <strong>Dates:</strong> ${startDate.toLocaleDateString()} - ${endDate.toLocaleDateString()}
                    </p>
                </div>
            `;
        }).join('');
        
    } catch (error) {
        console.error('Error loading projects:', error);
        container.innerHTML = '<div class="empty-state"><p>Failed to load projects.</p></div>';
    }
}

