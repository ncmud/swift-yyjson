import Cyyjson
import Foundation

/// Locale used to parse and format JSON numbers as `Decimal`.
/// JSON numbers always use `.` as the decimal separator,
/// so we pin to POSIX to avoid mis-handling under locales that use `,`.
let yyPOSIXLocale = Locale(identifier: "en_US_POSIX")

/// The object size above which keyed containers stop scanning every key on each access.
let yyLinearObjectLimit = 64

#if !YYJSON_DISABLE_WRITER

    /// Writes a key to an encoded object, replacing any earlier value for that key.
    ///
    /// - Note: Objects above ``yyLinearObjectLimit`` may temporarily hold duplicate keys.
    ///   ``collapseDuplicateKeys(_:)`` must run before the document is written.
    @inline(__always)
    func yyObjSet(
        _ obj: UnsafeMutablePointer<yyjson_mut_val>,
        _ key: UnsafeMutablePointer<yyjson_mut_val>?,
        _ val: UnsafeMutablePointer<yyjson_mut_val>?
    ) {
        if unsafe_yyjson_get_len(obj) < yyLinearObjectLimit {
            _ = yyjson_mut_obj_put(obj, key, val)
        } else {
            _ = yyjson_mut_obj_add(obj, key, val)
        }
    }

    /// Removes duplicate keys from every object in a value tree.
    ///
    /// Each surviving key keeps its first position and its last written value,
    /// matching the result of `yyjson_mut_obj_put`.
    func collapseDuplicateKeys(_ root: UnsafeMutablePointer<yyjson_mut_val>) {
        var pending = [root]
        while let val = pending.popLast() {
            if yyjson_mut_is_obj(val) {
                if unsafe_yyjson_get_len(val) > yyLinearObjectLimit {
                    collapseObjectDuplicates(val)
                }
                var iter = yyjson_mut_obj_iter()
                guard yyjson_mut_obj_iter_init(val, &iter) else { continue }
                while let key = yyjson_mut_obj_iter_next(&iter) {
                    if let child = yyjson_mut_obj_iter_get_val(key), yyjson_mut_is_ctn(child) {
                        pending.append(child)
                    }
                }
            } else if yyjson_mut_is_arr(val) {
                var iter = yyjson_mut_arr_iter()
                guard yyjson_mut_arr_iter_init(val, &iter) else { continue }
                while let child = yyjson_mut_arr_iter_next(&iter) {
                    if yyjson_mut_is_ctn(child) {
                        pending.append(child)
                    }
                }
            }
        }
    }

    private struct KeyBytes: Hashable {
        let bytes: UnsafeRawBufferPointer

        init(_ key: UnsafeMutablePointer<yyjson_mut_val>) {
            bytes = UnsafeRawBufferPointer(start: unsafe_yyjson_get_str(key), count: unsafe_yyjson_get_len(key))
        }

        static func == (lhs: KeyBytes, rhs: KeyBytes) -> Bool {
            lhs.bytes.elementsEqual(rhs.bytes)
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(bytes: bytes)
        }
    }

    private func collapseObjectDuplicates(_ obj: UnsafeMutablePointer<yyjson_mut_val>) {
        typealias Pair = (key: UnsafeMutablePointer<yyjson_mut_val>, val: UnsafeMutablePointer<yyjson_mut_val>?)
        let count = unsafe_yyjson_get_len(obj)
        var pairs: [Pair] = []
        pairs.reserveCapacity(count)
        var slots: [KeyBytes: Int] = [:]
        slots.reserveCapacity(count)

        var iter = yyjson_mut_obj_iter()
        guard yyjson_mut_obj_iter_init(obj, &iter) else { return }
        while let key = yyjson_mut_obj_iter_next(&iter) {
            let val = yyjson_mut_obj_iter_get_val(key)
            let bytes = KeyBytes(key)
            if let slot = slots[bytes] {
                pairs[slot].val = val
            } else {
                slots[bytes] = pairs.count
                pairs.append((key, val))
            }
        }

        guard pairs.count < count, yyjson_mut_obj_clear(obj) else { return }
        for pair in pairs {
            _ = yyjson_mut_obj_add(obj, pair.key, pair.val)
        }
    }

    /// Recursively sort object keys in-place using UTF-8 lexicographical comparison (strcmp).
    /// This matches Apple's JSONEncoder behavior for typical keys, but embedded null bytes
    /// may compare differently due to C string semantics.
    ///
    /// - Note: Uses direct C string comparison via `strcmp` for optimal performance,
    ///   avoiding Swift String allocations during sorting.
    func sortObjectKeys(_ val: UnsafeMutablePointer<yyjson_mut_val>) throws {
        typealias MutVal = UnsafeMutablePointer<yyjson_mut_val>

        if yyjson_mut_is_obj(val) {
            var pairs: [(keyVal: MutVal, val: MutVal, keyStr: UnsafePointer<CChar>)] = []
            pairs.reserveCapacity(Int(yyjson_mut_obj_size(val)))

            var iter = yyjson_mut_obj_iter()
            guard yyjson_mut_obj_iter_init(val, &iter) else {
                throw YYJSONError.invalidData("Failed to initialize object iterator during key sorting")
            }

            while let keyPtr = yyjson_mut_obj_iter_next(&iter) {
                guard let valPtr = yyjson_mut_obj_iter_get_val(keyPtr) else {
                    throw YYJSONError.invalidData("Object key has no associated value during key sorting")
                }
                guard let keyStr = yyjson_mut_get_str(keyPtr) else {
                    throw YYJSONError.invalidData("Object key is not a string during key sorting")
                }
                pairs.append((keyPtr, valPtr, keyStr))
            }

            pairs.sort { pair1, pair2 in
                return strcmp(pair1.keyStr, pair2.keyStr) < 0
            }

            guard yyjson_mut_obj_clear(val) else {
                throw YYJSONError.invalidData("Failed to clear object during key sorting")
            }

            for pair in pairs {
                try sortObjectKeys(pair.val)
                guard yyjson_mut_obj_add(val, pair.keyVal, pair.val) else {
                    throw YYJSONError.invalidData("Failed to add key back to object during key sorting")
                }
            }
        } else if yyjson_mut_is_arr(val) {
            var iter = yyjson_mut_arr_iter()
            guard yyjson_mut_arr_iter_init(val, &iter) else {
                throw YYJSONError.invalidData("Failed to initialize array iterator during key sorting")
            }
            while let elem = yyjson_mut_arr_iter_next(&iter) {
                try sortObjectKeys(elem)
            }
        }
    }
#endif  // !YYJSON_DISABLE_WRITER
