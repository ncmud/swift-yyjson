import Foundation
import Testing
@testable import YYJSON

#if !YYJSON_DISABLE_READER
    struct DeepSerializationTests {
        @Test func embeddedNULSurvivesValuesAndKeys() throws {
            let json = Data(#"{"a\u0000b":"c\u0000d"}"#.utf8)
            let value = try YYJSONValue(data: json)
            let object = try #require(value.object)
            #expect(object.keys == ["a\u{0000}b"])
            #expect(Array(object).first?.key == "a\u{0000}b")
            #expect(value["a\u{0000}b"]?.string == "c\u{0000}d")
            let converted = try #require(YYJSONSerialization.jsonObject(with: json) as? [String: String])
            #expect(converted == ["a\u{0000}b": "c\u{0000}d"])
        }

        @Test func duplicateKeysKeepTheLastValue() throws {
            let json = Data(#"{"a":1,"a":2,"nested":{"b":3,"b":4}}"#.utf8)
            let object = try #require(YYJSONSerialization.jsonObject(with: json) as? [String: Any])
            #expect(object["a"] as? Int == 2)
            #expect((object["nested"] as? [String: Int])?["b"] == 4)
        }

        @Test func deeplyNestedArraysDoNotConsumeTheCallStack() throws {
            let depth = 1000
            let json = String(repeating: "[", count: depth) + "true" + String(repeating: "]", count: depth)
            var value = try YYJSONSerialization.jsonObject(with: Data(json.utf8))
            for _ in 0 ..< depth {
                let array = try #require(value as? NSArray)
                #expect(array.count == 1)
                value = array.object(at: 0)
            }
            #expect((value as? NSNumber)?.boolValue == true)
        }
    }
#endif
