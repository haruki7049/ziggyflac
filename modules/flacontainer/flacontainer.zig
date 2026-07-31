const std = @import("std");

pub const constants = struct {
    pub const marker: []const u8 = "fLaC";
};

pub const metadata = @import("./flacontainer/metadata.zig");
pub const audio = @import("./flacontainer/audio.zig");

test {
    std.testing.refAllDecls(metadata);
    std.testing.refAllDecls(audio);
}

test "The marker is just fLaC" {
    try std.testing.expectEqualStrings(constants.marker, "fLaC");
}
