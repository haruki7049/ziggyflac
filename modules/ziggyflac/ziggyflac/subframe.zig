const std = @import("std");
const flacontainer = @import("flacontainer");
const audio = flacontainer.audio;

/// Errors returned by `decode`.
pub const DecodeError = std.mem.Allocator.Error || error{
    /// The subframe uses a predictor (FIXED or LPC) that is not supported yet.
    UnsupportedSubframeType,
    /// The VERBATIM body does not hold exactly `block_size` samples.
    SampleCountMismatch,
    /// Undoing the wasted-bits shift overflowed an `i64` sample.
    Overflow,
};

/// Reconstructs the `block_size` samples of `sub` (RFC 9639 Section 9.2),
/// including undoing the wasted-bits shift (RFC 9639 Section 9.2.2), which
/// `flacontainer` deliberately leaves un-applied.
///
/// Currently supports CONSTANT (RFC 9639 Section 9.2.3) and VERBATIM
/// (RFC 9639 Section 9.2.4) subframes; FIXED and LPC return
/// `error.UnsupportedSubframeType`.
///
/// The returned slice is owned by the caller and must be freed with `allocator`.
pub fn decode(allocator: std.mem.Allocator, sub: audio.Subframe, block_size: u16) DecodeError![]i64 {
    const samples = try allocator.alloc(i64, block_size);
    errdefer allocator.free(samples);

    switch (sub.body) {
        .constant => |value| @memset(samples, value),
        .verbatim => |raw| {
            if (raw.len != block_size) return error.SampleCountMismatch;
            @memcpy(samples, raw);
        },
        .fixed, .lpc => return error.UnsupportedSubframeType,
    }

    const shift = sub.header.wasted_bits;
    if (shift != 0) {
        for (samples) |*sample| sample.* = try std.math.shlExact(i64, sample.*, shift);
    }

    return samples;
}

test "decode repeats a CONSTANT subframe's value block_size times" {
    const sub: audio.Subframe = .{
        .header = .{ .subframe_type = .constant, .wasted_bits = 0 },
        .body = .{ .constant = -7 },
    };
    const samples = try decode(std.testing.allocator, sub, 4);
    defer std.testing.allocator.free(samples);

    try std.testing.expectEqualSlices(i64, &.{ -7, -7, -7, -7 }, samples);
}

test "decode copies a VERBATIM subframe's samples" {
    var raw = [_]i64{ 1, -2, 3 };
    const sub: audio.Subframe = .{
        .header = .{ .subframe_type = .verbatim, .wasted_bits = 0 },
        .body = .{ .verbatim = &raw },
    };
    const samples = try decode(std.testing.allocator, sub, 3);
    defer std.testing.allocator.free(samples);

    try std.testing.expectEqualSlices(i64, &.{ 1, -2, 3 }, samples);
}

test "decode applies the wasted-bits shift" {
    var raw = [_]i64{ 1, -3 };
    const verbatim: audio.Subframe = .{
        .header = .{ .subframe_type = .verbatim, .wasted_bits = 2 },
        .body = .{ .verbatim = &raw },
    };
    const verbatim_samples = try decode(std.testing.allocator, verbatim, 2);
    defer std.testing.allocator.free(verbatim_samples);
    try std.testing.expectEqualSlices(i64, &.{ 4, -12 }, verbatim_samples);

    const constant: audio.Subframe = .{
        .header = .{ .subframe_type = .constant, .wasted_bits = 3 },
        .body = .{ .constant = -1 },
    };
    const constant_samples = try decode(std.testing.allocator, constant, 2);
    defer std.testing.allocator.free(constant_samples);
    try std.testing.expectEqualSlices(i64, &.{ -8, -8 }, constant_samples);
}

test "decode rejects a VERBATIM body whose length differs from block_size" {
    var raw = [_]i64{ 1, 2 };
    const sub: audio.Subframe = .{
        .header = .{ .subframe_type = .verbatim, .wasted_bits = 0 },
        .body = .{ .verbatim = &raw },
    };
    try std.testing.expectError(error.SampleCountMismatch, decode(std.testing.allocator, sub, 3));
}

test "decode rejects FIXED subframes as unsupported for now" {
    const sub: audio.Subframe = .{
        .header = .{ .subframe_type = .{ .fixed = 0 }, .wasted_bits = 0 },
        .body = .{ .fixed = .{ .warmup = &.{}, .residual = undefined } },
    };
    try std.testing.expectError(error.UnsupportedSubframeType, decode(std.testing.allocator, sub, 1));
}
