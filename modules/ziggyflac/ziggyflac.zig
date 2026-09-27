const std = @import("std");

pub const subframe = @import("./ziggyflac/subframe.zig");

test {
    std.testing.refAllDecls(subframe);
}
