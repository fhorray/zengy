//! Thick-line expansion for gizmos: turns line segments into screen-space quads (two triangles each).
//!
//! Portable replacement for wide hardware lines, which backends do not guarantee. Output vertices are in
//! normalized device coordinates, so they are drawn with an identity view-projection.

const std = @import("std");
const gizmos = @import("gizmos");

/// Expands `lines` (pairs of vertices, world space) into quads in NDC. Segments behind the near plane are
/// clipped; degenerate (sub-pixel) segments are dropped.
pub fn appendExpandedGizmoQuads(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(gizmos.GizmoVertex),
    lines: []const gizmos.GizmoVertex,
    vp: [16]f32,
    tex_w: u32,
    tex_h: u32,
    line_width: f32,
    depth_bias: f32,
) !void {
    const fw: f32 = @floatFromInt(@max(tex_w, 1));
    const fh: f32 = @floatFromInt(@max(tex_h, 1));
    const half_px = line_width * 0.5;
    var i: usize = 0;
    while (i + 1 < lines.len) : (i += 2) {
        const a = lines[i];
        const b = lines[i + 1];
        var ca = [4]f32{
            vp[0] * a.pos[0] + vp[4] * a.pos[1] + vp[8] * a.pos[2] + vp[12],
            vp[1] * a.pos[0] + vp[5] * a.pos[1] + vp[9] * a.pos[2] + vp[13],
            vp[2] * a.pos[0] + vp[6] * a.pos[1] + vp[10] * a.pos[2] + vp[14],
            vp[3] * a.pos[0] + vp[7] * a.pos[1] + vp[11] * a.pos[2] + vp[15],
        };
        var cb = [4]f32{
            vp[0] * b.pos[0] + vp[4] * b.pos[1] + vp[8] * b.pos[2] + vp[12],
            vp[1] * b.pos[0] + vp[5] * b.pos[1] + vp[9] * b.pos[2] + vp[13],
            vp[2] * b.pos[0] + vp[6] * b.pos[1] + vp[10] * b.pos[2] + vp[14],
            vp[3] * b.pos[0] + vp[7] * b.pos[1] + vp[11] * b.pos[2] + vp[15],
        };
        const w_min: f32 = 0.05;
        if (ca[3] <= w_min and cb[3] <= w_min) continue;
        // Clip line segment to the near w-plane instead of dropping lines that cross behind the camera.
        if (ca[3] < w_min) {
            const t = (w_min - ca[3]) / (cb[3] - ca[3]);
            inline for (0..4) |k| ca[k] = ca[k] + (cb[k] - ca[k]) * t;
        } else if (cb[3] < w_min) {
            const t = (w_min - cb[3]) / (ca[3] - cb[3]);
            inline for (0..4) |k| cb[k] = cb[k] + (ca[k] - cb[k]) * t;
        }
        const na = [3]f32{ ca[0] / ca[3], ca[1] / ca[3], ca[2] / ca[3] + depth_bias * 0.002 };
        const nb = [3]f32{ cb[0] / cb[3], cb[1] / cb[3], cb[2] / cb[3] + depth_bias * 0.002 };
        const dx_px = (nb[0] - na[0]) * fw * 0.5;
        const dy_px = (nb[1] - na[1]) * fh * 0.5;
        const len_px = @sqrt(dx_px * dx_px + dy_px * dy_px);
        if (len_px < 1e-3) continue;
        const nx_ndc = (-dy_px / len_px) * (half_px * 2.0 / fw);
        const ny_ndc = (dx_px / len_px) * (half_px * 2.0 / fh);

        const v0 = gizmos.GizmoVertex{ .pos = .{ na[0] + nx_ndc, na[1] + ny_ndc, na[2] }, .color = a.color };
        const v1 = gizmos.GizmoVertex{ .pos = .{ na[0] - nx_ndc, na[1] - ny_ndc, na[2] }, .color = a.color };
        const v2 = gizmos.GizmoVertex{ .pos = .{ nb[0] + nx_ndc, nb[1] + ny_ndc, nb[2] }, .color = b.color };
        const v3 = gizmos.GizmoVertex{ .pos = .{ nb[0] - nx_ndc, nb[1] - ny_ndc, nb[2] }, .color = b.color };
        try out.appendSlice(allocator, &.{ v0, v1, v2, v2, v1, v3 });
    }
}
