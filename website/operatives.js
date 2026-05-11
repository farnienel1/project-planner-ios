import { initializeApp } from 'https://www.gstatic.com/firebasejs/10.7.1/firebase-app.js';
import { getAuth, onAuthStateChanged } from 'https://www.gstatic.com/firebasejs/10.7.1/firebase-auth.js';
import { getFirestore, collection, getDocs, doc, getDoc } from 'https://www.gstatic.com/firebasejs/10.7.1/firebase-firestore.js';

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
    const hasOperativesAccess = userData?.operatives === true || userData?.isSuperAdmin === true;
    
    if (!hasOperativesAccess) {
        document.getElementById('operativesList').innerHTML = 
            '<div class="empty-state"><p>You do not have permission to view operatives.</p></div>';
        return;
    }
    
    loadOperatives();
}

async function loadOperatives() {
    const container = document.getElementById('operativesList');
    
    try {
        if (!userData || !userData.organizationId) {
            container.innerHTML = '<div class="empty-state"><p>No organization found.</p></div>';
            return;
        }
        
        const operativesRef = collection(db, 'organizations', userData.organizationId, 'operatives');
        const operativesSnapshot = await getDocs(operativesRef);
        
        const operatives = [];
        operativesSnapshot.forEach((doc) => {
            const data = doc.data();
            if (data.isActive !== false) {
                operatives.push({ id: doc.id, ...data });
            }
        });
        
        if (operatives.length === 0) {
            container.innerHTML = '<div class="empty-state"><p>No operatives found.</p></div>';
            return;
        }
        
        container.innerHTML = operatives.map(operative => {
            const name = operative.name || 'Unnamed Operative';
            const skills = operative.skills && Array.isArray(operative.skills) 
                ? operative.skills.join(', ') 
                : 'No skills listed';
            const hourlyRate = operative.hourlyRate ? `£${operative.hourlyRate}/hr` : 'Rate not set';
            
            return `
                <div class="list-item">
                    <h3>${name}</h3>
                    <p style="margin-top: 8px; color: #666;">
                        ${operative.email ? `<strong>Email:</strong> ${operative.email}<br>` : ''}
                        ${operative.phone ? `<strong>Phone:</strong> ${operative.phone}<br>` : ''}
                        <strong>Skills:</strong> ${skills}<br>
                        <strong>Hourly Rate:</strong> ${hourlyRate}
                    </p>
                </div>
            `;
        }).join('');
        
    } catch (error) {
        console.error('Error loading operatives:', error);
        container.innerHTML = '<div class="empty-state"><p>Failed to load operatives.</p></div>';
    }
}

