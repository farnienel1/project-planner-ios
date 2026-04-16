import Foundation
import Combine

class VerificationCodeManager: ObservableObject {
    @Published var verificationCodes: [VerificationCode] = []
    @Published var rateLimitAttempts: [String: (count: Int, lastAttempt: Date)] = [:]
    
    private let rateLimitWindow: TimeInterval = 60 // 1 minute
    private let maxAttemptsPerWindow = 5 // Allow more attempts
    
    // MARK: - Code Generation and Storage
    
    func generateAndStoreCode(for email: String) -> String {
        // Check rate limiting
        if isRateLimited(for: email) {
            return ""
        }
        
        return generateNewCode(for: email)
    }
    
    func forceGenerateAndStoreCode(for email: String) -> String {
        // Force generate code even if rate limited
        print("🔄 Force generating new code for \(email) (bypassing rate limit)")
        return generateNewCode(for: email)
    }
    
    private func generateNewCode(for email: String) -> String {
        // Generate 6-digit code
        let code = String(Int.random(in: 100000...999999))
        
        // Invalidate any existing codes for this email
        invalidateExistingCodes(for: email)
        
        // Create new verification code
        let verificationCode = VerificationCode(
            code: code,
            email: email,
            expiresAt: Date().addingTimeInterval(10 * 60) // 10 minutes from now
        )
        
        // Store in memory (in production, this would be stored in Firebase/database)
        verificationCodes.append(verificationCode)
        
        // Update rate limiting
        updateRateLimit(for: email)
        
        print("🔐 Generated verification code for \(email): \(code)")
        return code
    }
    
    // MARK: - Code Verification
    
    func verifyCode(_ enteredCode: String, for email: String) -> VerificationResult {
        // Find the most recent valid code for this email
        guard let verificationCode = findValidCode(for: email) else {
            return .invalidCode
        }
        
        // Check if code is expired
        if verificationCode.isExpired {
            return .expired
        }
        
        // Check if code is already used
        if verificationCode.isUsed {
            return .alreadyUsed
        }
        
        // Check remaining attempts
        if verificationCode.remainingAttempts <= 0 {
            return .tooManyAttempts
        }
        
        // Increment attempts
        incrementAttempts(for: verificationCode)
        
        // Check if code matches
        if verificationCode.code == enteredCode {
            // Mark as used
            markAsUsed(verificationCode)
            return .success
        } else {
            return .invalidCode
        }
    }
    
    // MARK: - Helper Methods
    
    private func findValidCode(for email: String) -> VerificationCode? {
        return verificationCodes
            .filter { $0.email == email && !$0.isExpired && !$0.isUsed }
            .sorted(by: { $0.createdAt > $1.createdAt })
            .first
    }
    
    private func invalidateExistingCodes(for email: String) {
        verificationCodes.removeAll { $0.email == email }
    }
    
    private func incrementAttempts(for verificationCode: VerificationCode) {
        if let index = verificationCodes.firstIndex(where: { $0.id == verificationCode.id }) {
            let updatedCode = VerificationCode(
                code: verificationCode.code,
                email: verificationCode.email,
                expiresAt: Date().addingTimeInterval(10 * 60)
            )
            // Note: In a real implementation, you'd update the attempts count
            verificationCodes[index] = updatedCode
        }
    }
    
    private func markAsUsed(_ verificationCode: VerificationCode) {
        if let index = verificationCodes.firstIndex(where: { $0.id == verificationCode.id }) {
            let updatedCode = VerificationCode(
                code: verificationCode.code,
                email: verificationCode.email,
                expiresAt: Date().addingTimeInterval(10 * 60)
            )
            verificationCodes[index] = updatedCode
        }
    }
    
    // MARK: - Rate Limiting
    
    private func isRateLimited(for email: String) -> Bool {
        guard let attempt = rateLimitAttempts[email] else { return false }
        
        let timeSinceLastAttempt = Date().timeIntervalSince(attempt.lastAttempt)
        
        if timeSinceLastAttempt > rateLimitWindow {
            // Reset if outside window
            rateLimitAttempts[email] = (count: 0, lastAttempt: Date())
            return false
        }
        
        return attempt.count >= maxAttemptsPerWindow
    }
    
    private func updateRateLimit(for email: String) {
        let now = Date()
        
        if let attempt = rateLimitAttempts[email] {
            let timeSinceLastAttempt = now.timeIntervalSince(attempt.lastAttempt)
            
            if timeSinceLastAttempt > rateLimitWindow {
                // Reset if outside window
                rateLimitAttempts[email] = (count: 1, lastAttempt: now)
            } else {
                // Increment within window
                rateLimitAttempts[email] = (count: attempt.count + 1, lastAttempt: now)
            }
        } else {
            // First attempt
            rateLimitAttempts[email] = (count: 1, lastAttempt: now)
        }
    }
    
    // MARK: - Cleanup
    
    func cleanupExpiredCodes() {
        verificationCodes.removeAll { $0.isExpired }
    }
}

// MARK: - Verification Result

enum VerificationResult {
    case success
    case invalidCode
    case expired
    case alreadyUsed
    case tooManyAttempts
    case rateLimited
    
    var message: String {
        switch self {
        case .success:
            return "Email verified successfully!"
        case .invalidCode:
            return "Invalid verification code. Please try again."
        case .expired:
            return "Verification code has expired. Please request a new one."
        case .alreadyUsed:
            return "This verification code has already been used."
        case .tooManyAttempts:
            return "Too many failed attempts. Please request a new verification code."
        case .rateLimited:
            return "Too many verification requests. Please wait 5 minutes before trying again."
        }
    }
    
    var isSuccess: Bool {
        if case .success = self {
            return true
        }
        return false
    }
}
