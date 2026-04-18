import XCTest
@testable import SSHConfig

final class PatternTests: XCTestCase {
    func test_exactMatch() {
        XCTAssertTrue(Pattern.glob(pattern: "example.com", candidate: "example.com"))
        XCTAssertFalse(Pattern.glob(pattern: "example.com", candidate: "example.org"))
    }

    func test_starMatchesAnything() {
        XCTAssertTrue(Pattern.glob(pattern: "*", candidate: "anything"))
        XCTAssertTrue(Pattern.glob(pattern: "*", candidate: ""))
        XCTAssertTrue(Pattern.glob(pattern: "**", candidate: "abc"))
    }

    func test_starPrefixRequiresNonEmptyPrefix() {
        XCTAssertTrue(Pattern.glob(pattern: "*.example.com", candidate: "foo.example.com"))
        XCTAssertFalse(Pattern.glob(pattern: "*.example.com", candidate: "example.com"))
        XCTAssertTrue(Pattern.glob(pattern: "*.example.com", candidate: "a.b.example.com"))
    }

    func test_starInMiddle() {
        XCTAssertTrue(Pattern.glob(pattern: "a*c", candidate: "abbbc"))
        XCTAssertTrue(Pattern.glob(pattern: "a*c", candidate: "ac"))
        XCTAssertFalse(Pattern.glob(pattern: "a*c", candidate: "abbbd"))
    }

    func test_questionMark() {
        XCTAssertTrue(Pattern.glob(pattern: "a?c", candidate: "abc"))
        XCTAssertFalse(Pattern.glob(pattern: "a?c", candidate: "ac"))
        XCTAssertFalse(Pattern.glob(pattern: "a?c", candidate: "abbc"))
    }

    func test_multipleStars() {
        XCTAssertTrue(Pattern.glob(pattern: "*a*b*c*", candidate: "xaxbxcx"))
        XCTAssertFalse(Pattern.glob(pattern: "*a*b*c*", candidate: "xaxcx"))
    }

    func test_patternLongerThanCandidate() {
        XCTAssertFalse(Pattern.glob(pattern: "abc", candidate: "ab"))
    }

    func test_hostPatternNegationParsing() {
        XCTAssertFalse(HostPattern("foo").negated)
        XCTAssertTrue(HostPattern("!foo").negated)
        XCTAssertEqual(HostPattern("!foo").pattern, "foo")
    }

    func test_matchListNegation() {
        let patterns = [HostPattern("*.example.com"), HostPattern("!bad.example.com")]
        XCTAssertTrue(Pattern.matchList(patterns, against: "good.example.com"))
        XCTAssertFalse(Pattern.matchList(patterns, against: "bad.example.com"))
        XCTAssertFalse(Pattern.matchList(patterns, against: "other.com"))
    }

    func test_matchListAllNegatedNeverMatches() {
        // Per OpenSSH: a list of only negations never matches, because at
        // least one non-negated pattern must match.
        let patterns = [HostPattern("!foo"), HostPattern("!bar")]
        XCTAssertFalse(Pattern.matchList(patterns, against: "foo"))
        XCTAssertFalse(Pattern.matchList(patterns, against: "baz"))
    }

    func test_splitList() {
        let items = Pattern.splitList("a, b,  !c")
        XCTAssertEqual(items.map(\.pattern), ["a", "b", "c"])
        XCTAssertEqual(items.map(\.negated), [false, false, true])
    }

    func test_caseInsensitiveHostMatch() {
        let pattern = HostPattern("Example.COM")
        XCTAssertTrue(pattern.matches("example.com"))
        XCTAssertTrue(pattern.matches("EXAMPLE.com"))
    }
}
