const std = @import("std");

pub const BlockHeader = enum(u7) {
    stream_info,
    padding,
    application,
    seek_table,
    vorbis_comment,
    cue_sheet,
    picture,
};

test "each BlockHeader has u7 value" {
    try std.testing.expectEqual(@intFromEnum(BlockHeader.stream_info), 0);
    try std.testing.expectEqual(@intFromEnum(BlockHeader.padding), 1);
    try std.testing.expectEqual(@intFromEnum(BlockHeader.application), 2);
    try std.testing.expectEqual(@intFromEnum(BlockHeader.seek_table), 3);
    try std.testing.expectEqual(@intFromEnum(BlockHeader.vorbis_comment), 4);
    try std.testing.expectEqual(@intFromEnum(BlockHeader.cue_sheet), 5);
    try std.testing.expectEqual(@intFromEnum(BlockHeader.picture), 6);
}
