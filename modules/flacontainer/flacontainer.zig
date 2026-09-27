const std = @import("std");

pub const constants = struct {
    pub const marker: []const u8 = "fLaC";
};

pub const metadata = @import("./flacontainer/metadata.zig");
pub const audio = @import("./flacontainer/audio.zig");

/// Errors returned by `readMarker`.
pub const ReadMarkerError = std.Io.Reader.Error || error{
    /// The stream did not start with the `fLaC` marker (RFC 9639 Section 8).
    InvalidMarker,
};

/// Reads and validates the leading `fLaC` marker (RFC 9639 Section 8) from `reader`.
pub fn readMarker(reader: *std.Io.Reader) ReadMarkerError!void {
    const bytes = try reader.take(constants.marker.len);
    if (!std.mem.eql(u8, bytes, constants.marker)) return error.InvalidMarker;
}

test {
    std.testing.refAllDecls(metadata);
    std.testing.refAllDecls(audio);
}

test "The marker is just fLaC" {
    try std.testing.expectEqualStrings(constants.marker, "fLaC");
}

test "readMarker accepts a valid fLaC marker" {
    var reader: std.Io.Reader = .fixed("fLaC");
    try readMarker(&reader);
}

test "readMarker rejects an invalid marker" {
    var reader: std.Io.Reader = .fixed("RIFF");
    try std.testing.expectError(error.InvalidMarker, readMarker(&reader));
}

test "readMarker rejects a truncated stream" {
    var reader: std.Io.Reader = .fixed("fLa");
    try std.testing.expectError(error.EndOfStream, readMarker(&reader));
}
