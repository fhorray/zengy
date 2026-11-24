//! JSON Format Adapter Tests (`packages/formats/json/tests/json_tests.zig`).
//!
//! Validates `official.format.json`: parity between `std.json` and `yyjson`
//! on valid JSON documents and rejection of malformed JSON.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const json_format = @import("json_format");

test "JsonService std.json and yyjson produce identical structural stats" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();

    try app.registerModule(json_format.module());
    try app.initialize();
    try testing.expect(app.services.hasService("engine.format.json", 1));

    const sample =
        \\{"name":"zengy","version":1,"items":[10,20,30]}
    ;

    const s1 = try json_format.JsonService.inspectStdJson(testing.allocator, sample);
    const s2 = try json_format.JsonService.inspectYyjson(sample);

    try testing.expectEqual(s1.root_type, s2.root_type);
    try testing.expectEqual(s1.child_count, s2.child_count);
    try testing.expectEqual(@as(usize, 3), s2.child_count);

    try testing.expectError(error.InvalidJson, json_format.JsonService.inspectYyjson("{bad json"));
}
