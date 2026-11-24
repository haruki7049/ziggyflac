//! `ziggyflac` is the high-level layer of ziggyflac: it turns the parsed
//! structure of a FLAC stream, as read by the `flacontainer` module, into PCM
//! samples (`stream.decode`), and turns PCM samples into a FLAC stream
//! (`encoder.encode`). It builds on `flacontainer`, which parses and writes
//! the raw container without interpreting the audio.
const std = @import("std");

/// Reconstructs the samples of one subframe: predictors and wasted bits
/// (RFC 9639 Section 9.2).
pub const subframe = @import("./ziggyflac/subframe.zig");
/// Undoes interchannel decorrelation: left/side, right/side, and mid/side
/// (RFC 9639 Section 4.2).
pub const channel = @import("./ziggyflac/channel.zig");
/// Decodes a whole `flacontainer.Stream` into planar PCM samples.
pub const stream = @import("./ziggyflac/stream.zig");
/// Encodes planar PCM samples into a FLAC stream.
pub const encoder = @import("./ziggyflac/encoder.zig");

test {
    std.testing.refAllDecls(subframe);
    std.testing.refAllDecls(channel);
    std.testing.refAllDecls(stream);
    std.testing.refAllDecls(encoder);
}
