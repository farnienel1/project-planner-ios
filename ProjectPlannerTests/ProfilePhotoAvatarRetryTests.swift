import XCTest
@testable import Project_Planner

/// RULEBOOK §12: the avatar refreshes on `profilePhotoUpdatedAt`, and a failed load is retried (display only).
final class ProfilePhotoAvatarRetryTests: XCTestCase {
    private let urlA = "https://firebasestorage.googleapis.com/v0/b/demo.appspot.com/o/organizations%2Forg-a%2FuserProfiles%2Fu1%2Fprofile.jpg?alt=media&token=aaa"

    func testNewUploadTimeIsANewCacheKeyForTheSameURL() {
        let before = ProfilePhotoAvatarRetry.cacheKey(url: urlA, updatedAt: Date(timeIntervalSince1970: 1))
        let after = ProfilePhotoAvatarRetry.cacheKey(url: urlA, updatedAt: Date(timeIntervalSince1970: 2))
        XCTAssertNotEqual(before, after)
    }

    func testNewTokenIsANewCacheKey() {
        let other = urlA.replacingOccurrences(of: "token=aaa", with: "token=bbb")
        XCTAssertNotEqual(
            ProfilePhotoAvatarRetry.cacheKey(url: urlA, updatedAt: nil),
            ProfilePhotoAvatarRetry.cacheKey(url: other, updatedAt: nil)
        )
    }

    func testCacheKeyIgnoresSurroundingSpaces() {
        XCTAssertEqual(
            ProfilePhotoAvatarRetry.cacheKey(url: "  \(urlA) ", updatedAt: nil),
            ProfilePhotoAvatarRetry.cacheKey(url: urlA, updatedAt: nil)
        )
    }

    func testStoragePathFromDownloadURL() {
        XCTAssertEqual(
            ProfilePhotoAvatarRetry.storagePath(fromDownloadURL: urlA),
            "organizations/org-a/userProfiles/u1/profile.jpg"
        )
        XCTAssertNil(ProfilePhotoAvatarRetry.storagePath(fromDownloadURL: "https://example.com/p.jpg"))
    }

    func testRetriesBackOffThenStop() {
        XCTAssertNil(ProfilePhotoAvatarRetry.delay(afterFailures: 0))
        XCTAssertEqual(ProfilePhotoAvatarRetry.delay(afterFailures: 1), 5)
        XCTAssertEqual(ProfilePhotoAvatarRetry.delay(afterFailures: 3), 120)
        XCTAssertNil(ProfilePhotoAvatarRetry.delay(afterFailures: 4))
    }
}
