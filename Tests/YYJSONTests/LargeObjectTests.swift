import Foundation
import Testing
@testable import YYJSON

#if !YYJSON_DISABLE_READER && !YYJSON_DISABLE_WRITER
    private struct Key: CodingKey {
        let stringValue: String
        let intValue: Int? = nil
        init(_ stringValue: String) { self.stringValue = stringValue }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// Writes `filler` distinct keys, then runs `extra` on a fresh keyed container.
    private struct LargeObject: Encodable {
        let filler: Int
        let extra: (inout KeyedEncodingContainer<Key>) throws -> Void

        func encode(to encoder: Encoder) throws {
            var first = encoder.container(keyedBy: Key.self)
            try first.encode(-1, forKey: Key("early"))
            for index in 0 ..< filler {
                try first.encode(index, forKey: Key("k\(index)"))
            }
            var second = encoder.container(keyedBy: Key.self)
            try extra(&second)
        }
    }

    private func keysAndObject(_ value: some Encodable) throws -> (keys: [String], object: [String: Any]) {
        let data = try YYJSONEncoder().encode(value)
        let parsed = try YYJSONValue(data: data)
        let keys = Array(try #require(parsed.object)).map(\.key)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return (keys, object)
    }

    struct LargeObjectTests {
        @Test func dictionaryRoundTrips() throws {
            let source = Dictionary(uniqueKeysWithValues: (0 ..< 20000).map { ("room-\($0)", $0) })
            let data = try YYJSONEncoder().encode(source)
            #expect(try YYJSONDecoder().decode([String: Int].self, from: data) == source)
        }

        @Test func nestedDictionaryRoundTrips() throws {
            let source = Dictionary(uniqueKeysWithValues: (0 ..< 2000).map { ("zone-\($0)", ["a": $0, "b": $0 + 1]) })
            let data = try YYJSONEncoder().encode(source)
            #expect(try YYJSONDecoder().decode([String: [String: Int]].self, from: data) == source)
        }

        @Test func repeatedKeyKeepsFirstPositionAndLastValue() throws {
            for filler in [10, 500] {
                let value = LargeObject(filler: filler) { container in
                    try container.encode(1, forKey: Key("early"))
                    try container.encode(2, forKey: Key("late"))
                    try container.encode(3, forKey: Key("late"))
                }
                let (keys, object) = try keysAndObject(value)
                #expect(keys.count == filler + 2)
                #expect(keys.first == "early")
                #expect(keys.last == "late")
                #expect(object["early"] as? Int == 1)
                #expect(object["late"] as? Int == 3)
            }
        }

        @Test func repeatedKeyCollapsesInsideNestedValues() throws {
            let inner = LargeObject(filler: 200) { try $0.encode(9, forKey: Key("early")) }
            let (_, object) = try keysAndObject(["list": [inner]])
            let list = try #require(object["list"] as? [[String: Any]])
            #expect(list[0].count == 201)
            #expect(list[0]["early"] as? Int == 9)
        }

        @Test func replacedNestedContainerDoesNotSurvive() throws {
            let value = LargeObject(filler: 200) { container in
                var nested = container.nestedContainer(keyedBy: Key.self, forKey: Key("early"))
                try nested.encode(5, forKey: Key("inner"))
            }
            let (keys, object) = try keysAndObject(value)
            #expect(keys.count == 201)
            #expect((object["early"] as? [String: Int])?["inner"] == 5)
        }

        @Test func repeatedKeyCollapsesBeforeSorting() throws {
            let value = LargeObject(filler: 200) { try $0.encode(7, forKey: Key("early")) }
            var encoder = YYJSONEncoder()
            encoder.writeOptions = .sortedKeys
            let data = try encoder.encode(value)
            let keys = Array(try #require(try YYJSONValue(data: data).object)).map(\.key)
            #expect(keys.count == 201)
            #expect(keys == keys.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) })
        }

        @Test func canonicallyEquivalentKeysStayDistinct() throws {
            let value = LargeObject(filler: 200) { container in
                try container.encode(1, forKey: Key("caf\u{E9}"))
                try container.encode(2, forKey: Key("cafe\u{301}"))
            }
            let (keys, _) = try keysAndObject(value)
            #expect(keys.count == 203)
        }

        private struct Reader: Decodable {
            let reversed: [Int]
            let missing: Int?
            let null: Int?
            let containedFirst: Bool
            let repeated: [Int]

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: Key.self)
                reversed = try (0 ..< 200).reversed().map { try container.decode(Int.self, forKey: Key("k\($0)")) }
                missing = try container.decodeIfPresent(Int.self, forKey: Key("absent"))
                null = try container.decodeIfPresent(Int.self, forKey: Key("null"))
                containedFirst = container.contains(Key("k5"))
                repeated = try (0 ..< 3).map { _ in try container.decode(Int.self, forKey: Key("k5")) }
            }
        }

        @Test func lookupsWorkInAnyOrder() throws {
            var fields = (0 ..< 200).map { "\"k\($0)\":\($0)" }
            fields.append("\"null\":null")
            let reader = try YYJSONDecoder().decode(Reader.self, from: Data("{\(fields.joined(separator: ","))}".utf8))
            #expect(reader.reversed == Array((0 ..< 200).reversed()))
            #expect(reader.missing == nil)
            #expect(reader.null == nil)
            #expect(reader.containedFirst)
            #expect(reader.repeated == [5, 5, 5])
        }

        @Test func missingRequiredKeyStillThrows() throws {
            let fields = (0 ..< 200).map { "\"k\($0)\":\($0)" }.joined(separator: ",")
            struct Needs: Decodable {
                init(from decoder: Decoder) throws {
                    _ = try decoder.container(keyedBy: Key.self).decode(Int.self, forKey: Key("absent"))
                }
            }
            #expect(throws: (any Error).self) {
                _ = try YYJSONDecoder().decode(Needs.self, from: Data("{\(fields)}".utf8))
            }
        }

        @Test func largeFoundationDictionarySerializes() throws {
            let source = Dictionary(uniqueKeysWithValues: (0 ..< 5000).map { ("k\($0)", $0) })
            let data = try YYJSONSerialization.data(withJSONObject: source)
            #expect(try YYJSONSerialization.jsonObject(with: data) as? [String: Int] == source)
        }
    }
#endif
