const std = @import("std");
const flacontainer = @import("flacontainer");
const audio = flacontainer.audio;

/// Errors returned by `decode`.
pub const DecodeError = std.mem.Allocator.Error || error{
    /// The subframe requests a predictor order that ziggyflac does not
    /// support, or an LPC subframe carries a negative `qlp_shift` (the
    /// format reserves negative shifts and never produces them).
    UnsupportedSubframeType,
    /// The body does not hold exactly `block_size` samples (VERBATIM), or
    /// warmup plus residual values (FIXED, LPC).
    SampleCountMismatch,
    /// Reconstructing a sample, or undoing the wasted-bits shift, overflowed
    /// an `i64` sample.
    Overflow,
};

/// Reconstructs the `block_size` samples of `sub` (RFC 9639 Section 9.2),
/// including undoing the wasted-bits shift (RFC 9639 Section 9.2.2), which
/// `flacontainer` deliberately leaves un-applied.
///
/// Supports CONSTANT (RFC 9639 Section 9.2.3), VERBATIM
/// (RFC 9639 Section 9.2.4), FIXED (RFC 9639 Section 9.2.5), and LPC
/// (RFC 9639 Section 9.2.6) subframes.
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
        .fixed => |fixed| try restoreFixed(samples, fixed.warmup, fixed.residual.values),
        .lpc => |lpc| try restoreLpc(samples, lpc.warmup, lpc.coefficients, lpc.qlp_shift, lpc.residual.values),
    }

    const shift = sub.header.wasted_bits;
    if (shift != 0) {
        for (samples) |*sample| sample.* = try std.math.shlExact(i64, sample.*, shift);
    }

    return samples;
}

/// Coefficients of the fixed predictors of orders 0 through 4
/// (RFC 9639 Section 9.2.5), applied to `s[i-1], s[i-2], ...` in that order.
const fixed_coefficients = [_][]const i64{
    &.{},
    &.{1},
    &.{ 2, -1 },
    &.{ 3, -3, 1 },
    &.{ 4, -6, 4, -1 },
};

/// Fills `samples` with the `warmup` samples followed by each residual value
/// plus the fixed-predictor prediction from the preceding samples.
fn restoreFixed(samples: []i64, warmup: []const i64, residual: []const i32) DecodeError!void {
    // flacontainer only produces orders 0-4; anything else is malformed.
    if (warmup.len >= fixed_coefficients.len) return error.UnsupportedSubframeType;
    if (warmup.len + residual.len != samples.len) return error.SampleCountMismatch;

    const coefficients = fixed_coefficients[warmup.len];
    @memcpy(samples[0..warmup.len], warmup);
    for (residual, warmup.len..) |value, i| {
        var sample: i64 = value;
        for (coefficients, 1..) |coefficient, lag| {
            sample = try std.math.add(i64, sample, try std.math.mul(i64, coefficient, samples[i - lag]));
        }
        samples[i] = sample;
    }
}

/// Fills `samples` with the `warmup` samples followed by each residual value
/// plus the LPC prediction from the preceding samples, using `coefficients`
/// and `qlp_shift` (RFC 9639 Section 9.2.6).
fn restoreLpc(samples: []i64, warmup: []const i64, coefficients: []const i64, qlp_shift: i6, residual: []const i32) DecodeError!void {
    if (warmup.len != coefficients.len) return error.SampleCountMismatch;
    if (warmup.len + residual.len != samples.len) return error.SampleCountMismatch;
    // The format reserves negative shifts and defines the field as signed
    // only for historic reasons; a real stream never sets one.
    if (qlp_shift < 0) return error.UnsupportedSubframeType;
    const shift: u6 = @intCast(qlp_shift);

    @memcpy(samples[0..warmup.len], warmup);
    for (residual, warmup.len..) |value, i| {
        var prediction: i64 = 0;
        for (coefficients, 1..) |coefficient, lag| {
            prediction = try std.math.add(i64, prediction, try std.math.mul(i64, coefficient, samples[i - lag]));
        }
        samples[i] = try std.math.add(i64, value, prediction >> shift);
    }
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

/// Builds a FIXED subframe whose order is `warmup.len` and whose residual
/// values are backed by `residual`, for tests only.
fn testFixedSubframe(warmup: []i64, residual: []i32, wasted_bits: u6) audio.Subframe {
    return .{
        .header = .{ .subframe_type = .{ .fixed = @intCast(warmup.len) }, .wasted_bits = wasted_bits },
        .body = .{ .fixed = .{ .warmup = warmup, .residual = .{ .values = residual } } },
    };
}

test "decode reconstructs FIXED subframes of every order" {
    // The sequence s[i] = i*i + 1 has a constant second difference, so every
    // order >= 3 predicts it exactly (zero residual), and lower orders need
    // the differences of the corresponding order as residual.
    const expected = [_]i64{ 1, 2, 5, 10, 17, 26, 37 };
    const residuals = [_][]const i32{
        &.{ 1, 2, 5, 10, 17, 26, 37 },
        &.{ 1, 3, 5, 7, 9, 11 },
        &.{ 2, 2, 2, 2, 2 },
        &.{ 0, 0, 0, 0 },
        &.{ 0, 0, 0 },
    };
    for (residuals, 0..) |residual, order| {
        var warmup: [4]i64 = undefined;
        @memcpy(warmup[0..order], expected[0..order]);
        var values: [7]i32 = undefined;
        @memcpy(values[0..residual.len], residual);

        const sub = testFixedSubframe(warmup[0..order], values[0..residual.len], 0);
        const samples = try decode(std.testing.allocator, sub, expected.len);
        defer std.testing.allocator.free(samples);
        try std.testing.expectEqualSlices(i64, &expected, samples);
    }
}

test "decode applies the wasted-bits shift after FIXED prediction" {
    var warmup = [_]i64{-1};
    var residual = [_]i32{ -1, 3 };
    const samples = try decode(std.testing.allocator, testFixedSubframe(&warmup, &residual, 1), 3);
    defer std.testing.allocator.free(samples);
    try std.testing.expectEqualSlices(i64, &.{ -2, -4, 2 }, samples);
}

test "decode rejects a FIXED body whose length differs from block_size" {
    var warmup = [_]i64{0};
    var residual = [_]i32{ 1, 2 };
    try std.testing.expectError(
        error.SampleCountMismatch,
        decode(std.testing.allocator, testFixedSubframe(&warmup, &residual, 0), 4),
    );
}

test "decode reports FIXED prediction overflow as an error" {
    var warmup = [_]i64{ 0, std.math.maxInt(i64) };
    var residual = [_]i32{0};
    try std.testing.expectError(
        error.Overflow,
        decode(std.testing.allocator, testFixedSubframe(&warmup, &residual, 0), 3),
    );
}

/// Builds an LPC subframe whose order is `warmup.len`, for tests only.
fn testLpcSubframe(warmup: []i64, coefficients: []i64, qlp_shift: i6, residual: []i32, wasted_bits: u6) audio.Subframe {
    return .{
        .header = .{ .subframe_type = .{ .lpc = @intCast(warmup.len) }, .wasted_bits = wasted_bits },
        .body = .{ .lpc = .{
            .warmup = warmup,
            .qlp_shift = qlp_shift,
            .coefficients = coefficients,
            .residual = .{ .values = residual },
        } },
    };
}

test "decode reconstructs an LPC subframe with zero shift" {
    // s[i] = 3*s[i-1] - s[i-2], applied exactly (zero residual) except where
    // a residual value nudges the sequence off that recurrence.
    var warmup = [_]i64{ 1, 2 };
    var coefficients = [_]i64{ 3, -1 };
    var residual = [_]i32{ 0, 2, -5 };
    const sub = testLpcSubframe(&warmup, &coefficients, 0, &residual, 0);

    const samples = try decode(std.testing.allocator, sub, 5);
    defer std.testing.allocator.free(samples);
    try std.testing.expectEqualSlices(i64, &.{ 1, 2, 5, 15, 35 }, samples);
}

test "decode applies qlp_shift to the LPC prediction" {
    // prediction = 2*prev >> 1 == prev, so each sample is the previous one
    // plus its residual value.
    var warmup = [_]i64{10};
    var coefficients = [_]i64{2};
    var residual = [_]i32{ 3, -4, 7 };
    const sub = testLpcSubframe(&warmup, &coefficients, 1, &residual, 0);

    const samples = try decode(std.testing.allocator, sub, 4);
    defer std.testing.allocator.free(samples);
    try std.testing.expectEqualSlices(i64, &.{ 10, 13, 9, 16 }, samples);
}

test "decode applies the wasted-bits shift after LPC prediction" {
    var warmup = [_]i64{1};
    var coefficients = [_]i64{2};
    var residual = [_]i32{ 0, 1 };
    const sub = testLpcSubframe(&warmup, &coefficients, 0, &residual, 2);

    const samples = try decode(std.testing.allocator, sub, 3);
    defer std.testing.allocator.free(samples);
    try std.testing.expectEqualSlices(i64, &.{ 4, 8, 20 }, samples);
}

test "decode rejects an LPC body whose length differs from block_size" {
    var warmup = [_]i64{0};
    var coefficients = [_]i64{1};
    var residual = [_]i32{ 1, 2 };
    try std.testing.expectError(
        error.SampleCountMismatch,
        decode(std.testing.allocator, testLpcSubframe(&warmup, &coefficients, 0, &residual, 0), 4),
    );
}

test "decode reports LPC prediction overflow as an error" {
    var warmup = [_]i64{std.math.maxInt(i64)};
    var coefficients = [_]i64{2};
    var residual = [_]i32{0};
    try std.testing.expectError(
        error.Overflow,
        decode(std.testing.allocator, testLpcSubframe(&warmup, &coefficients, 0, &residual, 0), 2),
    );
}

test "decode rejects an LPC subframe with a negative qlp_shift" {
    var warmup = [_]i64{1};
    var coefficients = [_]i64{1};
    var residual = [_]i32{0};
    try std.testing.expectError(
        error.UnsupportedSubframeType,
        decode(std.testing.allocator, testLpcSubframe(&warmup, &coefficients, -1, &residual, 0), 2),
    );
}
