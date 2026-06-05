import Testing
@testable import FoundationChatKit

struct VectorTests {
    @Test func identicalIsOne() { #expect(abs(Vector.cosineSimilarity([1, 2, 3], [1, 2, 3]) - 1) < 1e-5) }
    @Test func orthogonalIsZero() { #expect(abs(Vector.cosineSimilarity([1, 0], [0, 1])) < 1e-5) }
    @Test func emptyIsZero() { #expect(Vector.cosineSimilarity([], []) == 0) }
    @Test func mismatchedLengthIsZero() { #expect(Vector.cosineSimilarity([1, 2], [1, 2, 3]) == 0) }
    @Test func zeroVectorIsZero() { #expect(Vector.cosineSimilarity([0, 0], [1, 1]) == 0) }
}
