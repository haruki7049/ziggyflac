const std = @import("std");
const flacontainer = @import("flacontainer");
const audio = flacontainer.audio;

/// Errors returned by `decode`.
pub const DecodeError = std.mem.Allocator.Error || error{
    /// `subframes` did not hold exactly the channel count `assignment`
    /// requires, or two subframes that should pair up (left/side,
    /// right/side, mid/side) have different lengths.
    SampleCountMismatch,
    /// Recovering left/right from a side or mid channel overflowed an
    /// `i64` sample.
    Overflow,
};

/// Undoes the frame's channel decorrelation (RFC 9639 Section 9.2), turning
/// `subframes` - each subframe's already-reconstructed samples (see
/// `subframe.decode`), in the order `flacontainer` read them - into the true
/// per-channel sample arrays, in left-to-right channel order.
///
/// Each returned slice, and the outer slice itself, is newly allocated and
/// owned by the caller, who must free both with `allocator`.
pub fn decode(
    allocator: std.mem.Allocator,
    assignment: audio.ChannelAssignment,
    subframes: []const []const i64,
) DecodeError![][]i64 {
    if (subframes.len != assignment.channelCount()) return error.SampleCountMismatch;

    const channels = try allocator.alloc([]i64, subframes.len);
    var filled: usize = 0;
    errdefer {
        for (channels[0..filled]) |channel| allocator.free(channel);
        allocator.free(channels);
    }

    switch (assignment) {
        .independent => {
            for (subframes) |subframe| {
                channels[filled] = try allocator.dupe(i64, subframe);
                filled += 1;
            }
        },
        .left_side => {
            const left = subframes[0];
            const side = subframes[1];
            if (left.len != side.len) return error.SampleCountMismatch;

            channels[filled] = try allocator.dupe(i64, left);
            filled += 1;

            const right = try allocator.alloc(i64, side.len);
            channels[filled] = right;
            filled += 1;
            for (left, side, right) |l, s, *r| r.* = try std.math.sub(i64, l, s);
        },
        .right_side => {
            const side = subframes[0];
            const right = subframes[1];
            if (side.len != right.len) return error.SampleCountMismatch;

            const left = try allocator.alloc(i64, side.len);
            channels[filled] = left;
            filled += 1;
            for (right, side, left) |r, s, *l| l.* = try std.math.add(i64, r, s);

            channels[filled] = try allocator.dupe(i64, right);
            filled += 1;
        },
        .mid_side => {
            const mid = subframes[0];
            const side = subframes[1];
            if (mid.len != side.len) return error.SampleCountMismatch;

            const left = try allocator.alloc(i64, mid.len);
            channels[filled] = left;
            filled += 1;

            const right = try allocator.alloc(i64, mid.len);
            channels[filled] = right;
            filled += 1;

            // The encoder drops mid's least-significant bit; side's parity
            // matches the dropped bit, since left+right and left-right always
            // have the same parity.
            for (mid, side, left, right) |m, s, *l, *r| {
                const doubled_mid = (try std.math.shlExact(i64, m, 1)) | (s & 1);
                l.* = (try std.math.add(i64, doubled_mid, s)) >> 1;
                r.* = (try std.math.sub(i64, doubled_mid, s)) >> 1;
            }
        },
    }

    return channels;
}

fn freeChannels(allocator: std.mem.Allocator, channels: [][]i64) void {
    for (channels) |channel| allocator.free(channel);
    allocator.free(channels);
}

test "decode duplicates each subframe unchanged for independent channels" {
    var ch0 = [_]i64{ 1, 2, 3 };
    var ch1 = [_]i64{ -1, -2, -3 };
    const subframes = [_][]const i64{ &ch0, &ch1 };

    const channels = try decode(std.testing.allocator, .{ .independent = 2 }, &subframes);
    defer freeChannels(std.testing.allocator, channels);

    try std.testing.expectEqualSlices(i64, &ch0, channels[0]);
    try std.testing.expectEqualSlices(i64, &ch1, channels[1]);
}

test "decode recovers right from left/side" {
    var left = [_]i64{ 10, 20 };
    var side = [_]i64{ 3, 5 };
    const subframes = [_][]const i64{ &left, &side };

    const channels = try decode(std.testing.allocator, .left_side, &subframes);
    defer freeChannels(std.testing.allocator, channels);

    try std.testing.expectEqualSlices(i64, &.{ 10, 20 }, channels[0]);
    try std.testing.expectEqualSlices(i64, &.{ 7, 15 }, channels[1]);
}

test "decode recovers left from right/side" {
    var side = [_]i64{ 3, 5 };
    var right = [_]i64{ 7, 15 };
    const subframes = [_][]const i64{ &side, &right };

    const channels = try decode(std.testing.allocator, .right_side, &subframes);
    defer freeChannels(std.testing.allocator, channels);

    try std.testing.expectEqualSlices(i64, &.{ 10, 20 }, channels[0]);
    try std.testing.expectEqualSlices(i64, &.{ 7, 15 }, channels[1]);
}

test "decode recovers left and right from mid/side, including the dropped LSB" {
    // (left, right) = (5, 3) -> (mid, side) = (4, 2); an even sum.
    // (left, right) = (5, 2) -> (mid, side) = (3, 3); an odd sum, whose
    // dropped LSB must be recovered from side's parity.
    var mid = [_]i64{ 4, 3 };
    var side = [_]i64{ 2, 3 };
    const subframes = [_][]const i64{ &mid, &side };

    const channels = try decode(std.testing.allocator, .mid_side, &subframes);
    defer freeChannels(std.testing.allocator, channels);

    try std.testing.expectEqualSlices(i64, &.{ 5, 5 }, channels[0]);
    try std.testing.expectEqualSlices(i64, &.{ 3, 2 }, channels[1]);
}

test "decode rejects a subframe count that does not match the channel assignment" {
    var only = [_]i64{1};
    const subframes = [_][]const i64{&only};

    try std.testing.expectError(
        error.SampleCountMismatch,
        decode(std.testing.allocator, .left_side, &subframes),
    );
}

test "decode rejects a left/side pair with mismatched lengths" {
    var left = [_]i64{ 1, 2 };
    var side = [_]i64{1};
    const subframes = [_][]const i64{ &left, &side };

    try std.testing.expectError(
        error.SampleCountMismatch,
        decode(std.testing.allocator, .left_side, &subframes),
    );
}

test "decode reports mid/side overflow as an error" {
    var mid = [_]i64{std.math.maxInt(i64)};
    var side = [_]i64{0};
    const subframes = [_][]const i64{ &mid, &side };

    try std.testing.expectError(
        error.Overflow,
        decode(std.testing.allocator, .mid_side, &subframes),
    );
}
