const std = @import("std");

pub const subframe = @import("./ziggyflac/subframe.zig");
pub const channel = @import("./ziggyflac/channel.zig");

test {
    std.testing.refAllDecls(subframe);
    std.testing.refAllDecls(channel);
}
