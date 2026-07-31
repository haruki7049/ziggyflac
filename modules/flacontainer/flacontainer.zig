const std = @import("std");

pub const metadata = @import("./flacontainer/metadata.zig");
pub const audio = @import("./flacontainer/audio.zig");

test {
    std.testing.refAllDecls(metadata);
    std.testing.refAllDecls(audio);
}
