//! 3D Math Foundation (`packages/render-3d/src/math3d.zig`).
//!
//! Column-major `Mat4` with right-handed `[0..1]` depth projection (for SDL_GPU
//! Vulkan/D3D12/Metal), `Vec3` helpers, and 6-plane `Frustum` culling.

const std = @import("std");

pub const Vec3 = struct {
    x: f32 = 0.0,
    y: f32 = 0.0,
    z: f32 = 0.0,

    pub fn add(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
    }

    pub fn sub(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
    }

    pub fn dot(a: Vec3, b: Vec3) f32 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }

    pub fn cross(a: Vec3, b: Vec3) Vec3 {
        return .{
            .x = a.y * b.z - a.z * b.y,
            .y = a.z * b.x - a.x * b.z,
            .z = a.x * b.y - a.y * b.x,
        };
    }

    pub fn length(v: Vec3) f32 {
        return @sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
    }

    pub fn normalize(v: Vec3) Vec3 {
        const len = v.length();
        if (len <= 1e-6) return .{ .x = 0, .y = 0, .z = 1 };
        const inv = 1.0 / len;
        return .{ .x = v.x * inv, .y = v.y * inv, .z = v.z * inv };
    }
};

/// Column-major 4x4 matrix (`m[col * 4 + row]`).
pub const Mat4 = struct {
    m: [16]f32,

    pub fn identity() Mat4 {
        return .{ .m = .{
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            0, 0, 0, 1,
        } };
    }

    pub fn mul(a: Mat4, b: Mat4) Mat4 {
        var out: [16]f32 = undefined;
        for (0..4) |col| {
            for (0..4) |row| {
                out[col * 4 + row] =
                    a.m[0 * 4 + row] * b.m[col * 4 + 0] +
                    a.m[1 * 4 + row] * b.m[col * 4 + 1] +
                    a.m[2 * 4 + row] * b.m[col * 4 + 2] +
                    a.m[3 * 4 + row] * b.m[col * 4 + 3];
            }
        }
        return .{ .m = out };
    }

    pub fn translation(x: f32, y: f32, z: f32) Mat4 {
        return .{ .m = .{
            1, 0, 0, 0,
            0, 1, 0, 0,
            0, 0, 1, 0,
            x, y, z, 1,
        } };
    }

    pub fn scale(sx: f32, sy: f32, sz: f32) Mat4 {
        return .{ .m = .{
            sx, 0,  0,  0,
            0,  sy, 0,  0,
            0,  0,  sz, 0,
            0,  0,  0,  1,
        } };
    }

    pub fn rotationY(rad: f32) Mat4 {
        const c = @cos(rad);
        const s = @sin(rad);
        return .{ .m = .{
            c,  0, -s, 0,
            0,  1, 0,  0,
            s,  0, c,  0,
            0,  0, 0,  1,
        } };
    }

    pub fn rotationX(rad: f32) Mat4 {
        const c = @cos(rad);
        const s = @sin(rad);
        return .{ .m = .{
            1, 0, 0,  0,
            0, c, s,  0,
            0, -s, c, 0,
            0, 0, 0,  1,
        } };
    }

    /// Right-handed look-at view matrix.
    pub fn lookAt(eye: Vec3, target: Vec3, up: Vec3) Mat4 {
        const f = Vec3.normalize(Vec3.sub(target, eye));
        const r = Vec3.normalize(Vec3.cross(f, up));
        const u = Vec3.cross(r, f);
        return .{ .m = .{
            r.x,               u.x,               -f.x,             0,
            r.y,               u.y,               -f.y,             0,
            r.z,               u.z,               -f.z,             0,
            -Vec3.dot(r, eye), -Vec3.dot(u, eye), Vec3.dot(f, eye), 1,
        } };
    }

    /// Right-handed perspective projection with `[0..1]` Z depth range (Vulkan / D3D12 / Metal).
    pub fn perspective(fov_rad: f32, aspect: f32, near: f32, far: f32) Mat4 {
        const half_tan = @tan(fov_rad * 0.5);
        const asp = if (aspect > 0.001) aspect else 1.0;
        const f_len = @max(far - near, 0.001);
        const y_scale = 1.0 / half_tan;
        const x_scale = y_scale / asp;
        return .{ .m = .{
            x_scale, 0,       0,                             0,
            0,       y_scale, 0,                             0,
            0,       0,       -far / f_len,                  -1,
            0,       0,       -(far * near) / f_len,         0,
        } };
    }
};

pub const Plane = struct {
    a: f32,
    b: f32,
    c: f32,
    d: f32,

    pub fn normalized(self: Plane) Plane {
        const len = @sqrt(self.a * self.a + self.b * self.b + self.c * self.c);
        if (len <= 1e-6) return self;
        const inv = 1.0 / len;
        return .{ .a = self.a * inv, .b = self.b * inv, .c = self.c * inv, .d = self.d * inv };
    }

    pub fn signedDistance(self: Plane, p: Vec3) f32 {
        return self.a * p.x + self.b * p.y + self.c * p.z + self.d;
    }
};

/// Six-plane view frustum extracted from a column-major View-Projection matrix.
pub const Frustum = struct {
    planes: [6]Plane,

    pub fn fromViewProj(vp: Mat4) Frustum {
        const m = vp.m;
        // Row helpers for column-major m[col*4 + row]:
        const r0 = [4]f32{ m[0], m[4], m[8], m[12] };
        const r1 = [4]f32{ m[1], m[5], m[9], m[13] };
        const r2 = [4]f32{ m[2], m[6], m[10], m[14] };
        const r3 = [4]f32{ m[3], m[7], m[11], m[15] };

        return .{ .planes = .{
            Plane.normalized(.{ .a = r3[0] + r0[0], .b = r3[1] + r0[1], .c = r3[2] + r0[2], .d = r3[3] + r0[3] }), // left
            Plane.normalized(.{ .a = r3[0] - r0[0], .b = r3[1] - r0[1], .c = r3[2] - r0[2], .d = r3[3] - r0[3] }), // right
            Plane.normalized(.{ .a = r3[0] + r1[0], .b = r3[1] + r1[1], .c = r3[2] + r1[2], .d = r3[3] + r1[3] }), // bottom
            Plane.normalized(.{ .a = r3[0] - r1[0], .b = r3[1] - r1[1], .c = r3[2] - r1[2], .d = r3[3] - r1[3] }), // top
            Plane.normalized(.{ .a = r2[0], .b = r2[1], .c = r2[2], .d = r2[3] }), // near (0 <= z)
            Plane.normalized(.{ .a = r3[0] - r2[0], .b = r3[1] - r2[1], .c = r3[2] - r2[2], .d = r3[3] - r2[3] }), // far
        } };
    }

    pub fn intersectsSphere(self: Frustum, center: Vec3, radius: f32) bool {
        for (self.planes) |p| {
            if (p.signedDistance(center) < -radius) return false;
        }
        return true;
    }
};
