//! Centralized Prism Shader Catalog & Interface Validation (`packages/render/prism/src/resources/shader_catalog.zig`).
//!
//! Lists canonical shader interfaces (stage, entry point, uniform sizes, sampler/storage counts)
//! so CPU/GPU layout drift is caught at compile time and in CI tests.

const std = @import("std");
const manifest = @import("manifest.zig");

/// Canonical shader catalog entry with entry point and binding metadata.
pub const ShaderCatalogEntry = struct {
    interface: manifest.ShaderInterfaceDesc,
    entry_point: []const u8 = "main",
    requires_compute: bool = false,
};

/// Canonical Prism Forward+ & Gizmo shader catalog.
pub const CANONICAL_SHADERS = [_]ShaderCatalogEntry{
    .{ .interface = .{ .name = "pbr.vert", .stage = .vertex, .version = 1, .uniform_bytes = 128, .vertex_stride = 32 } },
    .{ .interface = .{ .name = "pbr.frag", .stage = .fragment, .version = 1, .uniform_bytes = 256, .sampler_count = 10, .storage_buffer_count = 3 } },
    .{ .interface = .{ .name = "sky.vert", .stage = .vertex, .version = 1 } },
    .{ .interface = .{ .name = "sky.frag", .stage = .fragment, .version = 1, .sampler_count = 1 } },
    .{ .interface = .{ .name = "shadow.vert", .stage = .vertex, .version = 1, .uniform_bytes = 64, .vertex_stride = 32 } },
    .{ .interface = .{ .name = "shadow.frag", .stage = .fragment, .version = 1 } },
    .{ .interface = .{ .name = "ssao.frag", .stage = .fragment, .version = 1, .sampler_count = 2 } },
    .{ .interface = .{ .name = "ssao_blur.frag", .stage = .fragment, .version = 1, .sampler_count = 2 } },
    .{ .interface = .{ .name = "volumetric_fog.frag", .stage = .fragment, .version = 1, .sampler_count = 4 } },
    .{ .interface = .{ .name = "volumetric_composite.frag", .stage = .fragment, .version = 1, .sampler_count = 2 } },
    .{ .interface = .{ .name = "bloom_downsample.frag", .stage = .fragment, .version = 1, .uniform_bytes = 16, .sampler_count = 1 } },
    .{ .interface = .{ .name = "bloom_upsample.frag", .stage = .fragment, .version = 1, .uniform_bytes = 16, .sampler_count = 1 } },
    .{ .interface = .{ .name = "postfx.frag", .stage = .fragment, .version = 1, .sampler_count = 2 } },
    .{ .interface = .{ .name = "gizmo.vert", .stage = .vertex, .version = 1, .uniform_bytes = 64, .vertex_stride = 28 } },
    .{ .interface = .{ .name = "gizmo.frag", .stage = .fragment, .version = 1 } },
};

/// Looks up a shader entry by name in `CANONICAL_SHADERS`.
pub fn findShader(name: []const u8) ?ShaderCatalogEntry {
    for (CANONICAL_SHADERS) |entry| {
        if (std.mem.eql(u8, entry.interface.name, name)) return entry;
    }
    return null;
}

/// Validates that all catalog shader names are unique and non-empty.
pub fn validateCatalog() bool {
    for (CANONICAL_SHADERS, 0..) |a, i| {
        if (a.interface.name.len == 0 or a.entry_point.len == 0) return false;
        for (CANONICAL_SHADERS[i + 1 ..]) |b| {
            if (std.mem.eql(u8, a.interface.name, b.interface.name)) return false;
        }
    }
    return true;
}
