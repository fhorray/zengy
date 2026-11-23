//! TOML Format Adapter Tests (`packages/formats/toml/tests/toml_tests.zig`).
//!
//! Validates `official.format.toml` (`z-toml` adapter): registration as an optional
//! module, parsing `engine.package.toml` manifests, and handling invalid TOML.

const std = @import("std");
const testing = std.testing;
const engine = @import("engine");
const toml_format = @import("toml_format");

test "TomlService parses engine.package.toml manifest via z-toml" {
    var app = engine.App.init(testing.allocator, .{});
    defer app.deinit();

    try app.registerModule(toml_format.module());
    try app.initialize();

    try testing.expect(app.services.hasService("engine.format.toml", 1));

    const manifest_src =
        \\[package]
        \\id = "official.script.lua"
        \\version = "0.1.0"
        \\kind = "native-module"
        \\
        \\[compatibility]
        \\abi_major = 1
    ;

    const manifest = try toml_format.TomlService.parsePackageManifest(testing.allocator, manifest_src);
    defer {
        testing.allocator.free(manifest.id);
        testing.allocator.free(manifest.version);
        testing.allocator.free(manifest.kind);
    }

    try testing.expectEqualStrings("official.script.lua", manifest.id);
    try testing.expectEqualStrings("0.1.0", manifest.version);
    try testing.expectEqualStrings("native-module", manifest.kind);
    try testing.expectEqual(@as(i64, 1), manifest.abi_major);
}
