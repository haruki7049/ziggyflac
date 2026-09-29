const std = @import("std");

pub const subframe = @import("./ziggyflac/subframe.zig");
pub const channel = @import("./ziggyflac/channel.zig");
pub const stream = @import("./ziggyflac/stream.zig");

test {
    std.testing.refAllDecls(subframe);
    std.testing.refAllDecls(channel);
    std.testing.refAllDecls(stream);
}
