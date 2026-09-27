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

/// A fully parsed FLAC stream: the mandatory STREAMINFO metadata block and
/// every audio frame. Metadata blocks other than STREAMINFO are parsed (to
/// validate them and advance the reader correctly) and then discarded, since
/// nothing in this container layer needs to keep them yet.
pub const Stream = struct {
    stream_info: metadata.StreamInfo,
    /// Every frame in the stream, owned by this `Stream` and freed by `deinit`.
    frames: []audio.Frame,

    /// Errors returned by `read`.
    pub const ReadError = ReadMarkerError ||
        metadata.Header.ReadError ||
        metadata.StreamInfo.ReadError ||
        metadata.Application.ReadError ||
        metadata.SeekTable.ReadError ||
        metadata.VorbisComment.ReadError ||
        metadata.CueSheet.ReadError ||
        metadata.Picture.ReadError ||
        audio.Frame.ReadError ||
        error{
            /// The first metadata block was not STREAMINFO (RFC 9639 Section 7 requires it).
            MissingStreamInfo,
        };

    /// Reads the marker, every metadata block, and every audio frame from
    /// `reader`. `allocator` is used to parse and then immediately discard
    /// metadata blocks other than STREAMINFO, and to allocate the returned
    /// `frames`, which the caller frees with `deinit`.
    pub fn read(reader: *std.Io.Reader, allocator: std.mem.Allocator) ReadError!Stream {
        try readMarker(reader);

        var stream_info: ?metadata.StreamInfo = null;
        var is_last = false;
        while (!is_last) {
            const header = try metadata.Header.read(reader);
            is_last = header.is_last;

            switch (header.block_type) {
                .stream_info => stream_info = try metadata.StreamInfo.read(reader),
                .padding => try metadata.Padding.skip(reader, header.length),
                .application => {
                    const application = try metadata.Application.read(reader, allocator, header.length);
                    defer application.deinit(allocator);
                },
                .seek_table => {
                    const seek_table = try metadata.SeekTable.read(reader, allocator, header.length);
                    defer seek_table.deinit(allocator);
                },
                .vorbis_comment => {
                    const comment = try metadata.VorbisComment.read(reader, allocator);
                    defer comment.deinit(allocator);
                },
                .cue_sheet => {
                    const cue_sheet = try metadata.CueSheet.read(reader, allocator);
                    defer cue_sheet.deinit(allocator);
                },
                .picture => {
                    const picture = try metadata.Picture.read(reader, allocator);
                    defer picture.deinit(allocator);
                },
            }

            if (stream_info == null and is_last) return error.MissingStreamInfo;
        }
        const resolved_stream_info = stream_info orelse return error.MissingStreamInfo;

        var frames: std.ArrayList(audio.Frame) = .empty;
        errdefer {
            for (frames.items) |frame| frame.deinit(allocator);
            frames.deinit(allocator);
        }
        while (true) {
            // A clean end of stream is only valid right at a frame boundary;
            // any error.EndOfStream from within Frame.read itself (a
            // truncated frame) still propagates as a real error below.
            _ = reader.peekByte() catch |err| switch (err) {
                error.EndOfStream => break,
                else => |e| return e,
            };
            const frame = try audio.Frame.read(reader, allocator, resolved_stream_info.bits_per_sample);
            try frames.append(allocator, frame);
        }

        return .{
            .stream_info = resolved_stream_info,
            .frames = try frames.toOwnedSlice(allocator),
        };
    }

    pub fn deinit(self: Stream, allocator: std.mem.Allocator) void {
        for (self.frames) |frame| frame.deinit(allocator);
        allocator.free(self.frames);
    }
};

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

test "Stream.read parses a small sample FLAC stream end-to-end" {
    // STREAMINFO body: 44100 Hz, 2 channels, 16 bits per sample.
    const stream_info_body = [_]u8{
        0x10, 0x00, 0x10, 0x00,
        0x00, 0x03, 0xe8, 0x00,
        0x07, 0xd0, 0x0a, 0xc4,
        0x42, 0xf0, 0x00, 0x0f,
        0x42, 0x40, 0x00, 0x01,
        0x02, 0x03, 0x04, 0x05,
        0x06, 0x07, 0x08, 0x09,
        0x0a, 0x0b, 0x0c, 0x0d,
        0x0e, 0x0f,
    };
    // Metadata block header: not last, STREAMINFO, length 34.
    const stream_info_header = [_]u8{ 0x00, 0x00, 0x00, 0x22 };

    const padding_body = [_]u8{ 0x00, 0x00, 0x00, 0x00 };
    // Metadata block header: last, PADDING, length 4.
    const padding_header = [_]u8{ 0x81, 0x00, 0x00, 0x04 };

    // Frame header: fixed blocksize, 2304 samples, 44100 Hz, 2 independent
    // channels, 16 bits per sample, frame number 0.
    const frame_header_body = [_]u8{ 0xff, 0xf8, 0x49, 0x18, 0x00 };
    const frame_header_crc = audio.HeaderCrc.hash(&frame_header_body);
    // Two CONSTANT subframes (one per channel), value 0: header byte (pad=0,
    // type=constant, no wasted bits) + a 16-bit zero sample, each.
    const subframe_bytes = [_]u8{ 0x00, 0x00, 0x00 } ++ [_]u8{ 0x00, 0x00, 0x00 };
    const frame_body = frame_header_body ++ [_]u8{frame_header_crc} ++ subframe_bytes;
    const frame_footer_crc = audio.FooterCrc.hash(&frame_body);

    const marker_bytes = [_]u8{ 'f', 'L', 'a', 'C' };
    var reader: std.Io.Reader = .fixed(&(marker_bytes ++
        stream_info_header ++ stream_info_body ++
        padding_header ++ padding_body ++
        frame_body ++ [_]u8{
        @intCast(frame_footer_crc >> 8),
        @intCast(frame_footer_crc & 0xff),
    }));

    const stream = try Stream.read(&reader, std.testing.allocator);
    defer stream.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 44_100), stream.stream_info.sample_rate);
    try std.testing.expectEqual(@as(u4, 2), stream.stream_info.channels);
    try std.testing.expectEqual(@as(u6, 16), stream.stream_info.bits_per_sample);
    try std.testing.expectEqual(@as(usize, 1), stream.frames.len);
    try std.testing.expectEqual(@as(u16, 2304), stream.frames[0].header.block_size);
    try std.testing.expectEqual(@as(?u32, 44_100), stream.frames[0].header.sample_rate);
    try std.testing.expectEqual(@as(usize, 2), stream.frames[0].subframes.len);
    try std.testing.expectEqual(@as(i64, 0), stream.frames[0].subframes[0].body.constant);
}

test "Stream.read parses a real encoder-generated FLAC file" {
    // A 100-sample, 8 kHz, mono, 16-bit sine wave encoded by `flac` 1.5.0
    // (reference libFLAC), with the seek table and padding stripped to keep
    // the fixture minimal. Exercises real STREAMINFO, VORBIS_COMMENT, a
    // FIXED or LPC subframe, and both CRCs, none of which are hand-crafted.
    const bytes = @embedFile("testdata/tiny.flac");
    var reader: std.Io.Reader = .fixed(bytes);

    const stream = try Stream.read(&reader, std.testing.allocator);
    defer stream.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 8_000), stream.stream_info.sample_rate);
    try std.testing.expectEqual(@as(u4, 1), stream.stream_info.channels);
    try std.testing.expectEqual(@as(u6, 16), stream.stream_info.bits_per_sample);
    try std.testing.expectEqual(@as(u36, 100), stream.stream_info.total_samples);
    try std.testing.expectEqual(@as(usize, 1), stream.frames.len);
    try std.testing.expectEqual(@as(u16, 100), stream.frames[0].header.block_size);
    try std.testing.expectEqual(@as(usize, 1), stream.frames[0].subframes.len);
}

test "Stream.read rejects a stream whose first block is not STREAMINFO" {
    // Metadata block header: last, PADDING, length 0.
    const padding_header = [_]u8{ 0x81, 0x00, 0x00, 0x00 };
    const marker_bytes = [_]u8{ 'f', 'L', 'a', 'C' };
    var reader: std.Io.Reader = .fixed(&(marker_bytes ++ padding_header));
    try std.testing.expectError(error.MissingStreamInfo, Stream.read(&reader, std.testing.allocator));
}
