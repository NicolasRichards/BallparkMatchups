import XCTest
@testable import PatchCore

/// Encodes what was measured in captured MLB diffPatch traffic. Each assertion
/// corresponds to a check in Tools/diffpatch-verify, which validated the same
/// algorithm against real fixtures and a known-good implementation.
///
/// See Tools/diffpatch-verify/README.md for where the numbers come from.
final class JSONPatchTests: XCTestCase {

    // MARK: Helpers

    private func tree(_ json: String) throws -> JSONValue {
        try JSONValue.parse(Data(json.utf8))
    }

    private func ops(_ json: String) throws -> [JSONPatchOperation] {
        try JSONDecoder().decode([JSONPatchOperation].self, from: Data(json.utf8))
    }

    private func value(_ doc: JSONValue, _ pointer: String) throws -> JSONValue? {
        doc.value(at: try JSONPointer(pointer))
    }

    // MARK: Sequential appends

    /// MLB emits runs of appends to the same array. Each is in bounds only once
    /// its predecessors have landed, so order of application is load-bearing.
    /// Measured against the pre-patch feed instead, these look out-of-bounds.
    func testSequentialAppendsToEmptyArray() throws {
        var doc = try tree(#"{"metaData":{"logicalEvents":[]}}"#)
        try doc.apply(ops(#"""
        [{"op":"add","path":"/metaData/logicalEvents/0","value":"countChange"},
         {"op":"add","path":"/metaData/logicalEvents/1","value":"count12"},
         {"op":"add","path":"/metaData/logicalEvents/2","value":"newLeftHandedHit"}]
        """#))
        XCTAssertEqual(
            try value(doc, "/metaData/logicalEvents"),
            .array([.string("countChange"), .string("count12"), .string("newLeftHandedHit")])
        )
    }

    /// The thirteen-element pitcherHotColdZones batch, in miniature.
    func testLongAppendRunStaysInOrder() throws {
        var doc = try tree(#"{"zones":[]}"#)
        let batch = (0..<13).map { #"{"op":"add","path":"/zones/\#($0)","value":\#($0)}"# }
        try doc.apply(ops("[" + batch.joined(separator: ",") + "]"))
        XCTAssertEqual(try value(doc, "/zones"), .array((0..<13).map { JSONValue.int($0) }))
    }

    // MARK: RFC 6902 operations

    func testReplaceRemoveCopyMove() throws {
        var doc = try tree(#"""
        {"a":{"keep":1,"drop":2},"stats":{"hits":7},"play":{"pitchIndex":[0,1]}}
        """#)
        try doc.apply(ops(#"""
        [{"op":"replace","path":"/a/keep","value":42},
         {"op":"remove","path":"/a/drop"},
         {"op":"copy","path":"/play/pitchIndex/2","from":"/stats/hits"},
         {"op":"move","path":"/a/moved","from":"/stats/hits"}]
        """#))
        XCTAssertEqual(try value(doc, "/a/keep"), .int(42))
        XCTAssertNil(try value(doc, "/a/drop"))
        // copy takes the value at `from`; MLB's differ is value-oriented, so the
        // source is often semantically unrelated to the destination.
        XCTAssertEqual(try value(doc, "/play/pitchIndex/2"), .int(7))
        XCTAssertEqual(try value(doc, "/a/moved"), .int(7))
        XCTAssertNil(try value(doc, "/stats/hits"))
    }

    /// Mid-array insert never appeared in captured traffic, but the spec defines
    /// it and the implementation should follow the spec.
    func testAddInsertsRatherThanOverwrites() throws {
        var doc = try tree(#"{"a":[1,3]}"#)
        try doc.apply(ops(#"[{"op":"add","path":"/a/1","value":2}]"#))
        XCTAssertEqual(try value(doc, "/a"), .array([.int(1), .int(2), .int(3)]))
    }

    // MARK: RFC 6901 pointers

    /// A slash-to-dot path split mangles all three of these.
    func testPointerEscaping() throws {
        var doc = try tree(#"{"a/b":0,"c~d":0,"plain":{"x.y":0}}"#)
        try doc.apply(ops(#"""
        [{"op":"replace","path":"/a~1b","value":99},
         {"op":"replace","path":"/c~0d","value":98},
         {"op":"replace","path":"/plain/x.y","value":97}]
        """#))
        XCTAssertEqual(try value(doc, "/a~1b"), .int(99))
        XCTAssertEqual(try value(doc, "/c~0d"), .int(98))
        XCTAssertEqual(try value(doc, "/plain/x.y"), .int(97))
    }

    // MARK: Vivification

    /// diffPatch paths are not guaranteed to point at anything that exists — a
    /// diff can introduce a whole subtree one leaf at a time. This case is what
    /// the JS harness caught as a bug during development.
    func testBuildsMissingContainersIncludingThroughNewArrays() throws {
        var doc = JSONValue.object([:])
        try doc.apply(ops(#"""
        [{"op":"add","path":"/liveData/plays/allPlays/0/result/rbi","value":2}]
        """#))
        XCTAssertEqual(try value(doc, "/liveData/plays/allPlays/0/result/rbi"), .int(2))
        guard case .array = try XCTUnwrap(try value(doc, "/liveData/plays/allPlays")) else {
            return XCTFail("numeric token should have produced an array")
        }
    }

    // MARK: Failure behaviour

    /// A throw is the signal to refetch. Silently writing a hole would leave the
    /// card showing a plausible wrong number, which is the worst outcome here.
    func testOutOfBoundsAndMissingKeysThrow() throws {
        var a = try tree(#"{"arr":[1,2]}"#)
        let outOfBounds = try ops(#"[{"op":"replace","path":"/arr/7","value":0}]"#)
        XCTAssertThrowsError(try a.apply(outOfBounds))

        var b = try tree(#"{"a":1}"#)
        let absentKey = try ops(#"[{"op":"remove","path":"/missing"}]"#)
        XCTAssertThrowsError(try b.apply(absentKey))

        var c = try tree(#"{"arr":[1]}"#)
        let pastEnd = try ops(#"[{"op":"add","path":"/arr/5","value":0}]"#)
        XCTAssertThrowsError(try c.apply(pastEnd))
    }

    /// LiveFeedStream patches a copy and commits only on success. This is the
    /// value-semantics guarantee that makes that safe.
    func testFailedBatchLeavesTheOriginalUntouched() throws {
        let original = try tree(#"{"a":{"b":1},"arr":[1,2]}"#)
        var working = original
        let halfBad = try ops(#"""
        [{"op":"replace","path":"/a/b","value":2},
         {"op":"replace","path":"/arr/9","value":0}]
        """#)
        XCTAssertThrowsError(try working.apply(halfBad))
        XCTAssertEqual(try value(original, "/a/b"), .int(1), "original must not be mutated")
    }

    // MARK: MLB's loose replace

    /// Captured live, several times a game: MLB sends `replace` at index 0 of
    /// an array we hold empty, where the spec would require `add`. Throwing
    /// cost a full refetch — about 669 KB — each time.
    func testReplaceAtCountAppendsRatherThanThrowing() throws {
        var doc = try tree(#"{"metaData":{"gameEvents":[]}}"#)
        try doc.apply(ops(#"[{"op":"replace","path":"/metaData/gameEvents/0","value":"ball"}]"#))
        XCTAssertEqual(try value(doc, "/metaData/gameEvents"), .array([.string("ball")]))
    }

    /// Only exactly one past the end. Further out is a genuine gap, and
    /// filling it would punch a hole in the array — better to refetch.
    func testReplaceBeyondCountStillThrows() throws {
        var doc = try tree(#"{"a":[1,2]}"#)
        let beyond = try ops(#"[{"op":"replace","path":"/a/7","value":0}]"#)
        XCTAssertThrowsError(try doc.apply(beyond))
        XCTAssertEqual(try value(doc, "/a"), .array([.int(1), .int(2)]))
    }

    /// Removing an element that is not there has already been achieved.
    func testRemovingAnAbsentArrayIndexIsANoOp() throws {
        var doc = try tree(#"{"a":[]}"#)
        try doc.apply(ops(#"[{"op":"remove","path":"/a/0"}]"#))
        XCTAssertEqual(try value(doc, "/a"), .array([]))

        var two = try tree(#"{"a":[1,2]}"#)
        try two.apply(ops(#"[{"op":"remove","path":"/a/9"}]"#))
        XCTAssertEqual(try value(two, "/a"), .array([.int(1), .int(2)]))
    }

    /// A missing object key is still an error — that is a real desync, not
    /// a state we are already in.
    func testRemovingAnAbsentObjectKeyStillThrows() throws {
        var doc = try tree(#"{"a":1}"#)
        let absent = try ops(#"[{"op":"remove","path":"/missing"}]"#)
        XCTAssertThrowsError(try doc.apply(absent))
    }

    // MARK: Round trip

    /// The tree is re-encoded and re-decoded into LiveFeedResponse after every
    /// patch, so numbers must survive the round trip without drifting type.
    func testNumbersRoundTripWithoutBecomingFloats() throws {
        let doc = try tree(#"{"id":666204,"avg":0.274,"neg":-3,"big":1234567890123}"#)
        let again = try JSONValue.parse(try JSONEncoder().encode(doc))
        XCTAssertEqual(again, doc)
        XCTAssertEqual(try value(again, "/id"), .int(666204))
        XCTAssertEqual(try value(again, "/big"), .int(1234567890123))
    }

    func testNullIsPreservedDistinctlyFromAbsent() throws {
        var doc = try tree(#"{"a":null}"#)
        XCTAssertEqual(try value(doc, "/a"), JSONValue.null)
        try doc.apply(ops(#"[{"op":"replace","path":"/a","value":null}]"#))
        XCTAssertEqual(try value(doc, "/a"), JSONValue.null)
    }

    // MARK: Response shape

    /// diffPatch returns an array of envelopes — but sometimes a whole game
    /// object instead, which callers must detect rather than fail on.
    func testEnvelopeDecoding() throws {
        let envelopes = try JSONDecoder().decode([DiffPatchEnvelope].self, from: Data(#"""
        [{"diff":[{"op":"replace","path":"/metaData/timeStamp","value":"20240620_032718"}]}]
        """#.utf8))
        XCTAssertEqual(envelopes.count, 1)
        XCTAssertEqual(envelopes[0].diff.first?.op, .replace)

        let whole = try tree(#"{"metaData":{"timeStamp":"20240620_032718"},"gameData":{}}"#)
        guard case .object = whole else { return XCTFail("expected an object root") }
    }
}
