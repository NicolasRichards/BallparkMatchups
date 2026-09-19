import Foundation

/// A structural mirror of a JSON document.
///
/// The app decodes GUMBO into `LiveFeedResponse` for display, but `diffPatch`
/// operations address arbitrary positions in the raw tree — including fields the
/// typed model never decodes (pitch spin rates, hot/cold zones, every prior play).
/// Dropping those on decode and then patching would corrupt the tree, so patches
/// apply here and `LiveFeedResponse` is re-decoded from the result.
enum JSONValue: Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])
}

// MARK: - Codable

extension JSONValue: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(Int.self) {
            // Int before Double so player IDs and counts survive a round trip
            // without picking up a decimal point on re-encode.
            self = .int(v)
        } else if let v = try? c.decode(Double.self) {
            self = .double(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode([JSONValue].self) {
            self = .array(v)
        } else if let v = try? c.decode([String: JSONValue].self) {
            self = .object(v)
        } else {
            throw DecodingError.dataCorruptedError(
                in: c,
                debugDescription: "Unrecognized JSON value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }
}

// MARK: - Typed Re-decoding

extension JSONValue {
    /// Re-encodes this subtree and decodes it as `T`.
    ///
    /// Used to hand a patched GUMBO tree back to the existing typed pipeline.
    func decoded<T: Decodable>(as type: T.Type) throws -> T {
        let data = try JSONEncoder().encode(self)
        return try JSONDecoder().decode(type, from: data)
    }

    static func parse(_ data: Data) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: data)
    }
}

// MARK: - JSON Pointer (RFC 6901)

/// A parsed JSON Pointer.
///
/// Splitting on `.` after a slash-to-dot replacement is the common shortcut here,
/// but it breaks on any key containing a literal dot and silently mangles the
/// `~0`/`~1` escapes. This does it properly.
struct JSONPointer: Sendable, Equatable {
    let tokens: [String]

    var isRoot: Bool { tokens.isEmpty }

    init(tokens: [String]) {
        self.tokens = tokens
    }

    init(_ raw: String) throws {
        guard !raw.isEmpty else {
            self.tokens = []
            return
        }
        guard raw.hasPrefix("/") else {
            throw JSONPatchError.malformedPointer(raw)
        }
        // `~1` must be unescaped before `~0`, otherwise a literal `~1` written
        // as `~01` decodes to `/` instead of `~1`.
        self.tokens = raw.dropFirst()
            .components(separatedBy: "/")
            .map {
                $0.replacingOccurrences(of: "~1", with: "/")
                  .replacingOccurrences(of: "~0", with: "~")
            }
    }
}

extension JSONPointer: CustomStringConvertible {
    var description: String {
        "/" + tokens
            .map {
                $0.replacingOccurrences(of: "~", with: "~0")
                  .replacingOccurrences(of: "/", with: "~1")
            }
            .joined(separator: "/")
    }
}

// MARK: - Errors

enum JSONPatchError: LocalizedError, Equatable {
    case malformedPointer(String)
    case emptyPath
    case pathNotFound(String)
    case notTraversable(String)
    case arrayIndexOutOfBounds(path: String, index: Int, count: Int)
    case missingValue(op: String, path: String)
    case missingFrom(op: String, path: String)
    case testFailed(path: String)
    case unsupportedOperation(String)

    var errorDescription: String? {
        switch self {
        case .malformedPointer(let p):
            return "Malformed JSON pointer: \(p)"
        case .emptyPath:
            return "Operation targets the document root"
        case .pathNotFound(let p):
            return "No value at \(p)"
        case .notTraversable(let p):
            return "Cannot descend through \(p)"
        case .arrayIndexOutOfBounds(let path, let index, let count):
            return "Index \(index) out of bounds (count \(count)) at \(path)"
        case .missingValue(let op, let path):
            return "\(op) at \(path) has no value"
        case .missingFrom(let op, let path):
            return "\(op) at \(path) has no from"
        case .testFailed(let p):
            return "test failed at \(p)"
        case .unsupportedOperation(let op):
            return "Unsupported operation: \(op)"
        }
    }
}

// MARK: - Patch Operation (RFC 6902)

struct JSONPatchOperation: Sendable, Equatable {
    enum Kind: String, Sendable, Codable {
        case add, replace, remove, copy, move, test
    }

    let op: Kind
    let path: JSONPointer
    let from: JSONPointer?
    let value: JSONValue?
}

extension JSONPatchOperation: Decodable {
    private enum CodingKeys: String, CodingKey { case op, path, from, value }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawOp = try c.decode(String.self, forKey: .op)
        guard let kind = Kind(rawValue: rawOp) else {
            throw JSONPatchError.unsupportedOperation(rawOp)
        }
        self.op = kind
        self.path = try JSONPointer(c.decode(String.self, forKey: .path))
        self.from = try c.decodeIfPresent(String.self, forKey: .from).map { try JSONPointer($0) }
        // `value` is legitimately absent for remove/move/copy, and legitimately
        // `null` for add/replace — decodeIfPresent collapses those, so read the
        // key's presence directly.
        self.value = c.contains(.value) ? try c.decode(JSONValue.self, forKey: .value) : nil
    }
}

/// One element of a `diffPatch` response.
struct DiffPatchEnvelope: Decodable, Sendable {
    let diff: [JSONPatchOperation]
}

// MARK: - Reading

extension JSONValue {
    func value(at pointer: JSONPointer) -> JSONValue? {
        var node = self
        for token in pointer.tokens {
            switch node {
            case .object(let dict):
                guard let next = dict[token] else { return nil }
                node = next
            case .array(let arr):
                guard let i = Int(token), arr.indices.contains(i) else { return nil }
                node = arr[i]
            default:
                return nil
            }
        }
        return node
    }
}

// MARK: - Patching

extension JSONValue {
    /// Applies `operations` in order, mutating in place.
    ///
    /// Order matters: MLB emits runs of appends to the same array (thirteen
    /// `pitcherHotColdZones` adds in one batch, for example) that are only in
    /// bounds once the preceding ones have landed.
    ///
    /// Throws on the first failed operation, leaving the tree partially patched.
    /// Callers must treat a throw as "this tree is now untrustworthy" and refetch.
    mutating func apply(_ operations: [JSONPatchOperation]) throws {
        for operation in operations {
            try apply(operation)
        }
    }

    mutating func apply(_ operation: JSONPatchOperation) throws {
        switch operation.op {
        case .test:
            let actual = value(at: operation.path)
            guard actual == operation.value else {
                throw JSONPatchError.testFailed(path: operation.path.description)
            }

        case .add, .replace:
            guard let newValue = operation.value else {
                throw JSONPatchError.missingValue(
                    op: operation.op.rawValue,
                    path: operation.path.description
                )
            }
            try set(newValue, at: operation.path, insert: operation.op == .add)

        case .remove:
            try removeValue(at: operation.path)

        case .copy:
            guard let from = operation.from else {
                throw JSONPatchError.missingFrom(
                    op: operation.op.rawValue,
                    path: operation.path.description
                )
            }
            guard let copied = value(at: from) else {
                throw JSONPatchError.pathNotFound(from.description)
            }
            try set(copied, at: operation.path, insert: true)

        case .move:
            guard let from = operation.from else {
                throw JSONPatchError.missingFrom(
                    op: operation.op.rawValue,
                    path: operation.path.description
                )
            }
            guard let moved = value(at: from) else {
                throw JSONPatchError.pathNotFound(from.description)
            }
            try removeValue(at: from)
            try set(moved, at: operation.path, insert: true)
        }
    }

    // MARK: Leaf writes

    private mutating func set(_ newValue: JSONValue, at pointer: JSONPointer, insert: Bool) throws {
        guard !pointer.isRoot else {
            self = newValue
            return
        }
        try withParent(of: pointer) { parent, token in
            switch parent {
            case .array(var arr):
                guard let i = Int(token) else {
                    throw JSONPatchError.notTraversable(pointer.description)
                }
                if insert {
                    // RFC 6902: index may equal count (append) but not exceed it.
                    // Every array add observed in captured MLB traffic is an
                    // append; the insert branch is here for spec conformance.
                    guard i >= 0, i <= arr.count else {
                        throw JSONPatchError.arrayIndexOutOfBounds(
                            path: pointer.description, index: i, count: arr.count
                        )
                    }
                    arr.insert(newValue, at: i)
                } else {
                    guard arr.indices.contains(i) else {
                        throw JSONPatchError.arrayIndexOutOfBounds(
                            path: pointer.description, index: i, count: arr.count
                        )
                    }
                    arr[i] = newValue
                }
                parent = .array(arr)

            case .object(var dict):
                dict[token] = newValue
                parent = .object(dict)

            default:
                throw JSONPatchError.notTraversable(pointer.description)
            }
        }
    }

    private mutating func removeValue(at pointer: JSONPointer) throws {
        guard !pointer.isRoot else {
            self = .null
            return
        }
        try withParent(of: pointer) { parent, token in
            switch parent {
            case .array(var arr):
                guard let i = Int(token), arr.indices.contains(i) else {
                    throw JSONPatchError.arrayIndexOutOfBounds(
                        path: pointer.description,
                        index: Int(token) ?? -1,
                        count: arr.count
                    )
                }
                arr.remove(at: i)
                parent = .array(arr)

            case .object(var dict):
                guard dict.removeValue(forKey: token) != nil else {
                    throw JSONPatchError.pathNotFound(pointer.description)
                }
                parent = .object(dict)

            default:
                throw JSONPatchError.notTraversable(pointer.description)
            }
        }
    }

    // MARK: Navigation

    /// Walks to the container holding `pointer`'s last token and hands it to `body`.
    ///
    /// Missing intermediate containers are created, because MLB's paths are not
    /// guaranteed to point at anything that already exists — a diff can introduce
    /// a whole subtree one leaf at a time. The token that follows decides the
    /// shape: numeric means array, anything else means object.
    private mutating func withParent(
        of pointer: JSONPointer,
        _ body: (inout JSONValue, String) throws -> Void
    ) throws {
        guard let leaf = pointer.tokens.last else {
            throw JSONPatchError.emptyPath
        }
        let path = pointer.tokens.dropLast()
        try Self.descend(
            &self,
            path: path,
            nextTokenAfterPath: leaf,
            fullPath: pointer.description
        ) { container in
            try body(&container, leaf)
        }
    }

    private static func descend(
        _ node: inout JSONValue,
        path: ArraySlice<String>,
        nextTokenAfterPath: String,
        fullPath: String,
        _ body: (inout JSONValue) throws -> Void
    ) throws {
        guard let token = path.first else {
            try body(&node)
            return
        }
        let rest = path.dropFirst()
        let childShapeHint = rest.first ?? nextTokenAfterPath

        switch node {
        case .object(var dict):
            var child = dict[token] ?? emptyContainer(for: childShapeHint)
            try descend(
                &child,
                path: rest,
                nextTokenAfterPath: nextTokenAfterPath,
                fullPath: fullPath,
                body
            )
            dict[token] = child
            node = .object(dict)

        case .array(var arr):
            // An index one past the end is a container this diff is building:
            // MLB introduces a subtree one leaf at a time, so the element we
            // need to descend into may not exist yet. Anything beyond that is a
            // real gap — throw, and let the caller refetch rather than write a
            // hole into the tree.
            guard let i = Int(token), i >= 0, i <= arr.count else {
                throw JSONPatchError.arrayIndexOutOfBounds(
                    path: fullPath,
                    index: Int(token) ?? -1,
                    count: arr.count
                )
            }
            if i == arr.count {
                arr.append(emptyContainer(for: childShapeHint))
            }
            var child = arr[i]
            try descend(
                &child,
                path: rest,
                nextTokenAfterPath: nextTokenAfterPath,
                fullPath: fullPath,
                body
            )
            arr[i] = child
            node = .array(arr)

        case .null:
            // A null placeholder stands in for an absent container.
            var replacement = emptyContainer(for: token)
            try descend(
                &replacement,
                path: path,
                nextTokenAfterPath: nextTokenAfterPath,
                fullPath: fullPath,
                body
            )
            node = replacement

        default:
            throw JSONPatchError.notTraversable(fullPath)
        }
    }

    private static func emptyContainer(for nextToken: String) -> JSONValue {
        Int(nextToken) != nil ? .array([]) : .object([:])
    }
}
