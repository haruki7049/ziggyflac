const std = @import("std");

pub const subframe = @import("./ziggyflac/subframe.zig");
pub const channel = @import("./ziggyflac/channel.zig");
pub const stream = @import("./ziggyflac/stream.zig");
pub const encoder = @import("./ziggyflac/encoder.zig");

test {
    std.testing.refAllDecls(subframe);
    std.testing.refAllDecls(channel);
    std.testing.refAllDecls(stream);
    std.testing.refAllDecls(encoder);
}
