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

/// A minimally parsed FLAC stream: the mandatory STREAMINFO metadata block
/// and the header of the first audio frame. Every other metadata block is
/// parsed (to validate it and advance the reader correctly) and then
/// discarded, since nothing in this container layer needs to keep it yet.
pub const Stream = struct {
    stream_info: metadata.StreamInfo,
    first_frame_header: audio.FrameHeader,

    /// Errors returned by `read`.
    pub const ReadError = ReadMarkerError ||
        metadata.Header.ReadError ||
        metadata.StreamInfo.ReadError ||
        metadata.Application.ReadError ||
        metadata.SeekTable.ReadError ||
        metadata.VorbisComment.ReadError ||
        metadata.CueSheet.ReadError ||
        metadata.Picture.ReadError ||
        audio.FrameHeader.ReadError ||
        error{
            /// The first metadata block was not STREAMINFO (RFC 9639 Section 7 requires it).
            MissingStreamInfo,
        };

    /// Reads the marker, every metadata block, and the first frame header
    /// from `reader`. `allocator` is used only transiently, to parse and
    /// then immediately discard metadata blocks other than STREAMINFO.
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

        const first_frame_header = try audio.FrameHeader.read(reader);

        return .{
            .stream_info = stream_info orelse return error.MissingStreamInfo,
            .first_frame_header = first_frame_header,
        };
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

    const marker_bytes = [_]u8{ 'f', 'L', 'a', 'C' };
    var reader: std.Io.Reader = .fixed(&(marker_bytes ++
        stream_info_header ++ stream_info_body ++
        padding_header ++ padding_body ++
        frame_header_body ++ [_]u8{frame_header_crc}));

    const stream = try Stream.read(&reader, std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 44_100), stream.stream_info.sample_rate);
    try std.testing.expectEqual(@as(u4, 2), stream.stream_info.channels);
    try std.testing.expectEqual(@as(u6, 16), stream.stream_info.bits_per_sample);
    try std.testing.expectEqual(@as(u16, 2304), stream.first_frame_header.block_size);
    try std.testing.expectEqual(@as(?u32, 44_100), stream.first_frame_header.sample_rate);
}

test "Stream.read rejects a stream whose first block is not STREAMINFO" {
    // Metadata block header: last, PADDING, length 0.
    const padding_header = [_]u8{ 0x81, 0x00, 0x00, 0x00 };
    const marker_bytes = [_]u8{ 'f', 'L', 'a', 'C' };
    var reader: std.Io.Reader = .fixed(&(marker_bytes ++ padding_header));
    try std.testing.expectError(error.MissingStreamInfo, Stream.read(&reader, std.testing.allocator));
}
