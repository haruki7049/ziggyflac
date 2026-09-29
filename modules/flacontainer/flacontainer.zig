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

/// Reads and validates the leading `fLaC` marker (RFC 9639 Section 8) from
/// `reader`, first skipping a leading ID3v2 tag if present. RFC 9639
/// requires the marker to be the very first bytes of the stream, but some
/// real-world files are prefixed with an ID3v2 tag (not spec-compliant, but
/// written by taggers unaware of FLAC's container rules); this tolerates
/// exactly that one case rather than requiring the marker to be literally
/// the first 4 bytes.
pub fn readMarker(reader: *std.Io.Reader) ReadMarkerError!void {
    try skipLeadingId3v2Tag(reader);
    const bytes = try reader.take(constants.marker.len);
    if (!std.mem.eql(u8, bytes, constants.marker)) return error.InvalidMarker;
}

/// Size of an ID3v2 header: "ID3" (3 bytes), major and minor version (1
/// byte each), flags (1 byte), and a 4-byte synchsafe size.
const id3v2_header_len = 10;
/// Size of an ID3v2 footer (ID3v2.4 only, present when the header's
/// footer-present flag is set): a fixed-size mirror of the header.
const id3v2_footer_len = 10;
/// The header flags byte's footer-present bit (ID3v2.4 only).
const id3v2_footer_flag: u8 = 0x10;

/// If `reader` starts with an ID3v2 tag ("ID3" followed by version, flags,
/// and a synchsafe size), discards it entirely - header, body, and footer if
/// present - so a `fLaC` marker following it can still be found. Does
/// nothing if the next bytes are not "ID3".
fn skipLeadingId3v2Tag(reader: *std.Io.Reader) std.Io.Reader.Error!void {
    const prefix = reader.peek(3) catch |err| switch (err) {
        error.EndOfStream => return,
        else => |e| return e,
    };
    if (!std.mem.eql(u8, prefix, "ID3")) return;

    const header = try reader.take(id3v2_header_len);
    const flags = header[5];
    const size_bytes = header[6..10];

    // The size is "synchsafe": 4 bytes, each contributing its low 7 bits,
    // most significant byte first (each byte's own top bit is always 0 in a
    // compliant tag, so masking it off is defensive, not load-bearing).
    var body_len: u32 = 0;
    for (size_bytes) |byte| body_len = (body_len << 7) | (byte & 0x7f);

    const footer_len: u32 = if (flags & id3v2_footer_flag != 0) id3v2_footer_len else 0;
    try reader.discardAll(body_len + footer_len);
}

/// Reads a metadata block value of type `T` (via `T.read(reader, allocator)`)
/// and immediately frees it (via `.deinit(allocator)`), for block types this
/// container layer parses only to validate and advance past.
fn parseAndDiscard(comptime T: type, reader: *std.Io.Reader, allocator: std.mem.Allocator) T.ReadError!void {
    const value = try T.read(reader, allocator);
    value.deinit(allocator);
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
                .vorbis_comment => try parseAndDiscard(metadata.VorbisComment, reader, allocator),
                .cue_sheet => try parseAndDiscard(metadata.CueSheet, reader, allocator),
                .picture => try parseAndDiscard(metadata.Picture, reader, allocator),
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

test "readMarker rejects Ogg FLAC (an Ogg-encapsulated stream)" {
    // Ogg FLAC wraps FLAC packets in an Ogg container instead of using the
    // native marker/metadata/frame structure this reader implements; there
    // is no Ogg-page support anywhere in this repo. An Ogg page starts with
    // the "OggS" capture pattern, which readMarker rejects the same way as
    // any other non-"fLaC" prefix.
    var reader: std.Io.Reader = .fixed("OggS");
    try std.testing.expectError(error.InvalidMarker, readMarker(&reader));
}

test "readMarker skips a leading ID3v2 tag with no body" {
    // Some real-world files prepend an ID3v2 tag before the "fLaC" marker
    // (not RFC 9639-compliant, but written by taggers unaware of FLAC's
    // container rules); readMarker tolerates exactly this case. Header:
    // "ID3", version 4.0, flags 0x00 (no footer), synchsafe size 0.
    const id3_header = "ID3" ++ [_]u8{ 0x04, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 };
    var reader: std.Io.Reader = .fixed(id3_header ++ "fLaC");
    try readMarker(&reader);
}

test "readMarker skips a leading ID3v2 tag with a body and footer" {
    // Same as above, but with a 5-byte body (synchsafe size 5, encoded as
    // 0x00,0x00,0x00,0x05) and the footer-present flag set (ID3v2.4 only,
    // flags 0x10), so the reader must also skip the 10-byte footer after the
    // body before finding the marker.
    const id3_header = "ID3" ++ [_]u8{ 0x04, 0x00, 0x10, 0x00, 0x00, 0x00, 0x05 };
    const body = [_]u8{ 'T', 'I', 'T', '2', 0xff };
    const footer = "3DI" ++ [_]u8{ 0x04, 0x00, 0x10, 0x00, 0x00, 0x00, 0x05 };
    var reader: std.Io.Reader = .fixed(id3_header ++ body ++ footer ++ "fLaC");
    try readMarker(&reader);
}

test "readMarker rejects a stream that only looks like it might have an ID3v2 tag" {
    // A 4-byte prefix that happens to start with "ID3" but isn't "fLaC"
    // either, and isn't long enough to even hold a full ID3v2 header.
    var reader: std.Io.Reader = .fixed("ID3!");
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

test "Stream.read parses a variable-blocksize stream, including a multi-byte coded sample number" {
    // STREAMINFO body: 8000 Hz, 1 channel, 16 bits per sample, 384 total
    // samples (two 192-sample frames), block size fixed at 192 for both.
    const stream_info_body = [_]u8{
        0x00, 0xc0, 0x00, 0xc0,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x01, 0xf4,
        0x00, 0xf0, 0x00, 0x00,
        0x01, 0x80, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00,
    };
    // Metadata block header: last, STREAMINFO, length 34.
    const stream_info_header = [_]u8{ 0x80, 0x00, 0x00, 0x22 };

    // Frame 0 header: variable blocksize, 192 samples (code 1), sample rate
    // from STREAMINFO, 1 independent channel, 16 bits per sample, coded
    // sample number 0 (single byte).
    const frame0_header_body = [_]u8{ 0xff, 0xf9, 0x10, 0x08, 0x00 };
    const frame0_header_crc = audio.HeaderCrc.hash(&frame0_header_body);
    // One CONSTANT subframe, value 100.
    const frame0_subframe_bytes = [_]u8{ 0x00, 0x00, 0x64 };
    const frame0_body = frame0_header_body ++ [_]u8{frame0_header_crc} ++ frame0_subframe_bytes;
    const frame0_footer_crc = audio.FooterCrc.hash(&frame0_body);

    // Frame 1 header: same as frame 0, but its coded sample number is 192
    // (the correct starting sample after frame 0's 192 samples, not a
    // sequential frame index) - encoded as a 2-byte coded number (RFC 9639
    // Section 9.1.5: 5 bits in the first byte, 6 in the continuation byte;
    // 192 = 0b000_11000000 -> first byte top 5 bits 0b00011, continuation
    // low 6 bits 0b000000).
    const frame1_header_body = [_]u8{ 0xff, 0xf9, 0x10, 0x08, 0xc3, 0x80 };
    const frame1_header_crc = audio.HeaderCrc.hash(&frame1_header_body);
    // One CONSTANT subframe, value -50.
    const frame1_subframe_bytes = [_]u8{ 0x00, 0xff, 0xce };
    const frame1_body = frame1_header_body ++ [_]u8{frame1_header_crc} ++ frame1_subframe_bytes;
    const frame1_footer_crc = audio.FooterCrc.hash(&frame1_body);

    const marker_bytes = [_]u8{ 'f', 'L', 'a', 'C' };
    var reader: std.Io.Reader = .fixed(&(marker_bytes ++
        stream_info_header ++ stream_info_body ++
        frame0_body ++ [_]u8{
        @intCast(frame0_footer_crc >> 8),
        @intCast(frame0_footer_crc & 0xff),
    } ++ frame1_body ++ [_]u8{
        @intCast(frame1_footer_crc >> 8),
        @intCast(frame1_footer_crc & 0xff),
    }));

    const stream = try Stream.read(&reader, std.testing.allocator);
    defer stream.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), stream.frames.len);

    try std.testing.expectEqual(audio.BlockingStrategy.variable, stream.frames[0].header.blocking_strategy);
    try std.testing.expectEqual(@as(u36, 0), stream.frames[0].header.coded_number);
    try std.testing.expectEqual(@as(i64, 100), stream.frames[0].subframes[0].body.constant);

    try std.testing.expectEqual(audio.BlockingStrategy.variable, stream.frames[1].header.blocking_strategy);
    try std.testing.expectEqual(@as(u36, 192), stream.frames[1].header.coded_number);
    try std.testing.expectEqual(@as(i64, -50), stream.frames[1].subframes[0].body.constant);
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

test "Stream.read parses a real stereo FLAC file with channel decorrelation" {
    // 100 samples, 8 kHz, 2 channels, 16-bit, two different sine tones so the
    // encoder is free to pick any stereo decorrelation mode per frame.
    const bytes = @embedFile("testdata/stereo.flac");
    var reader: std.Io.Reader = .fixed(bytes);

    const stream = try Stream.read(&reader, std.testing.allocator);
    defer stream.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u4, 2), stream.stream_info.channels);
    try std.testing.expectEqual(@as(usize, 1), stream.frames.len);
    try std.testing.expectEqual(@as(u4, 2), stream.frames[0].header.channel_assignment.channelCount());
    try std.testing.expectEqual(@as(usize, 2), stream.frames[0].subframes.len);
}

test "Stream.read walks multiple frames" {
    // The same 100-sample sine wave as the mono fixture, but encoded with a
    // blocksize of 32 samples so it spans several frames instead of one.
    const bytes = @embedFile("testdata/multiframe.flac");
    var reader: std.Io.Reader = .fixed(bytes);

    const stream = try Stream.read(&reader, std.testing.allocator);
    defer stream.deinit(std.testing.allocator);

    try std.testing.expect(stream.frames.len > 1);

    var total_samples: usize = 0;
    for (stream.frames) |frame| total_samples += frame.header.block_size;
    try std.testing.expectEqual(@as(usize, @intCast(stream.stream_info.total_samples)), total_samples);
}

test "Stream.read parses real CONSTANT subframes from silence" {
    // 50 samples of digital silence: the encoder should use a CONSTANT
    // subframe, previously only exercised with hand-crafted bytes.
    const bytes = @embedFile("testdata/silence.flac");
    var reader: std.Io.Reader = .fixed(bytes);

    const stream = try Stream.read(&reader, std.testing.allocator);
    defer stream.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), stream.frames.len);
    try std.testing.expectEqual(audio.SubframeType.constant, stream.frames[0].subframes[0].header.subframe_type);
    try std.testing.expectEqual(@as(i64, 0), stream.frames[0].subframes[0].body.constant);
}

test "Stream.read parses a real SEEKTABLE metadata block" {
    // Same as the mono fixture, but encoded with the default seek table
    // (one seek point) instead of stripping it.
    const bytes = @embedFile("testdata/seektable.flac");
    var reader: std.Io.Reader = .fixed(bytes);

    const stream = try Stream.read(&reader, std.testing.allocator);
    defer stream.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 8_000), stream.stream_info.sample_rate);
    try std.testing.expectEqual(@as(usize, 1), stream.frames.len);
}

test "Stream.read parses a real PICTURE metadata block" {
    // Same as the mono fixture, plus a PICTURE block (a 1x1 PNG) added via
    // the reference flac 1.5.0 encoder's `--picture=` (run ad hoc via
    // `nix run nixpkgs#flac --`, not added as a project dependency).
    // `metadata.Picture.read` itself is already unit-tested with
    // hand-crafted bytes; this confirms `Stream.read` walks past a real
    // PICTURE block (previously only SEEKTABLE and VORBIS_COMMENT had a
    // real-encoder fixture exercising them end-to-end).
    const bytes = @embedFile("testdata/picture.flac");
    var reader: std.Io.Reader = .fixed(bytes);

    const stream = try Stream.read(&reader, std.testing.allocator);
    defer stream.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 8_000), stream.stream_info.sample_rate);
    try std.testing.expectEqual(@as(usize, 1), stream.frames.len);
}

test "Stream.read parses a real CUESHEET metadata block" {
    // 588 samples (1 CD-DA sector, the minimum flac's cuesheet import
    // accepts), 44100 Hz, 2 channels, 16-bit, plus a CUESHEET block (one
    // track, one index point) added via the reference flac 1.5.0 encoder's
    // `--cuesheet=`. `metadata.CueSheet.read` itself is already unit-tested
    // with hand-crafted bytes; this confirms `Stream.read` walks past a real
    // CUESHEET block.
    const bytes = @embedFile("testdata/cuesheet.flac");
    var reader: std.Io.Reader = .fixed(bytes);

    const stream = try Stream.read(&reader, std.testing.allocator);
    defer stream.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 44_100), stream.stream_info.sample_rate);
    try std.testing.expectEqual(@as(usize, 1), stream.frames.len);
}

test "Stream.read parses a frame-header sample rate requiring the 8-bit kHz escape" {
    // 20 samples, 37000 Hz (a multiple of 1000 not in the direct sample-rate
    // table), mono, 16-bit, encoded by the reference flac 1.5.0 encoder (run
    // ad hoc via `nix run nixpkgs#flac --`, not added as a project
    // dependency). RFC 9639 Section 9.1.3's sample-rate code has 11 direct
    // entries; 37000 matches none, so the encoder must use the 8-bit-kHz
    // escape (code 12) to represent it in the frame header at all.
    const bytes = @embedFile("testdata/rate37000.flac");
    var reader: std.Io.Reader = .fixed(bytes);

    const stream = try Stream.read(&reader, std.testing.allocator);
    defer stream.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 37_000), stream.stream_info.sample_rate);
    try std.testing.expectEqual(@as(?u32, 37_000), stream.frames[0].header.sample_rate);
}

test "Stream.read parses a frame-header sample rate requiring the direct 16-bit Hz escape" {
    // 20 samples, 11025 Hz (not a multiple of 1000 or 10, so neither the
    // 8-bit-kHz nor tenths-of-Hz escape can represent it exactly), mono,
    // 16-bit, encoded by the reference flac 1.5.0 encoder. The encoder must
    // use the direct 16-bit Hz escape (code 13).
    const bytes = @embedFile("testdata/rate11025.flac");
    var reader: std.Io.Reader = .fixed(bytes);

    const stream = try Stream.read(&reader, std.testing.allocator);
    defer stream.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 11_025), stream.stream_info.sample_rate);
    try std.testing.expectEqual(@as(?u32, 11_025), stream.frames[0].header.sample_rate);
}

test "Stream.read parses a frame-header sample rate requiring the tenths-of-Hz escape" {
    // 20 samples, 12340 Hz (a multiple of 10 but not of 1000, and not a
    // direct-Hz-representable... it is, but the encoder prefers the more
    // compact tenths-of-Hz form when a rate is a multiple of 10), mono,
    // 16-bit, encoded by the reference flac 1.5.0 encoder. The encoder must
    // use the tenths-of-Hz escape (code 14) to represent it most compactly.
    const bytes = @embedFile("testdata/rate12340.flac");
    var reader: std.Io.Reader = .fixed(bytes);

    const stream = try Stream.read(&reader, std.testing.allocator);
    defer stream.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 12_340), stream.stream_info.sample_rate);
    try std.testing.expectEqual(@as(?u32, 12_340), stream.frames[0].header.sample_rate);
}

test "Stream.read parses a frame whose bits-per-sample is inherited from STREAMINFO" {
    // Every fixture elsewhere in this test suite (and every real-encoder
    // fixture inspected while working through #73/#85) codes bits-per-sample
    // explicitly in the frame header; no available encoder (SoX, reference
    // flac) was found to ever emit sample-size code 0 (RFC 9639 Section
    // 9.1.3's "get bits-per-sample from STREAMINFO" case), so this is a
    // hand-crafted stream instead of a real-encoder fixture.
    //
    // STREAMINFO body: 8000 Hz, 1 channel, 16 bits per sample, 192 total
    // samples.
    const stream_info_body = [_]u8{
        0x00, 0xc0, 0x00, 0xc0,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x01, 0xf4,
        0x00, 0xf0, 0x00, 0x00,
        0x00, 0xc0, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x00, 0x00,
    };
    // Metadata block header: last, STREAMINFO, length 34.
    const stream_info_header = [_]u8{ 0x80, 0x00, 0x00, 0x22 };

    // Frame header: fixed blocksize, 192 samples (code 1), sample rate from
    // STREAMINFO, 1 independent channel, sample size code 0 (from
    // STREAMINFO), frame number 0.
    const frame_header_body = [_]u8{ 0xff, 0xf8, 0x10, 0x00, 0x00 };
    const frame_header_crc = audio.HeaderCrc.hash(&frame_header_body);
    // One CONSTANT subframe, value 42, at the inherited 16-bit width.
    const subframe_bytes = [_]u8{ 0x00, 0x00, 0x2a };
    const frame_body = frame_header_body ++ [_]u8{frame_header_crc} ++ subframe_bytes;
    const frame_footer_crc = audio.FooterCrc.hash(&frame_body);

    const marker_bytes = [_]u8{ 'f', 'L', 'a', 'C' };
    var reader: std.Io.Reader = .fixed(&(marker_bytes ++
        stream_info_header ++ stream_info_body ++
        frame_body ++ [_]u8{
        @intCast(frame_footer_crc >> 8),
        @intCast(frame_footer_crc & 0xff),
    }));

    const stream = try Stream.read(&reader, std.testing.allocator);
    defer stream.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(?u6, null), stream.frames[0].header.bits_per_sample);
    try std.testing.expectEqual(@as(i64, 42), stream.frames[0].subframes[0].body.constant);
}

test "Stream.read parses a stream with an APPLICATION metadata block" {
    // No mainstream encoder was found to write an APPLICATION block (SoX and
    // the reference flac encoder have no option for it), so this is a
    // hand-crafted stream instead of a real-encoder fixture.
    // `metadata.Application.read` itself is already unit-tested with
    // hand-crafted bytes; this confirms `Stream.read` walks past a full
    // APPLICATION block end-to-end.
    //
    // Same STREAMINFO/frame bytes as "Stream.read parses a small sample FLAC
    // stream end-to-end", but with the PADDING block replaced by an
    // APPLICATION block (id "test", 3 bytes of data).
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

    // Metadata block header: last, APPLICATION, length 7 (4-byte id + 3
    // bytes of data).
    const application_header = [_]u8{ 0x82, 0x00, 0x00, 0x07 };
    const application_body = [_]u8{ 't', 'e', 's', 't', 0x01, 0x02, 0x03 };

    // Frame header: fixed blocksize, 2304 samples, 44100 Hz, 2 independent
    // channels, 16 bits per sample, frame number 0.
    const frame_header_body = [_]u8{ 0xff, 0xf8, 0x49, 0x18, 0x00 };
    const frame_header_crc = audio.HeaderCrc.hash(&frame_header_body);
    // Two CONSTANT subframes (one per channel), value 0.
    const subframe_bytes = [_]u8{ 0x00, 0x00, 0x00 } ++ [_]u8{ 0x00, 0x00, 0x00 };
    const frame_body = frame_header_body ++ [_]u8{frame_header_crc} ++ subframe_bytes;
    const frame_footer_crc = audio.FooterCrc.hash(&frame_body);

    const marker_bytes = [_]u8{ 'f', 'L', 'a', 'C' };
    var reader: std.Io.Reader = .fixed(&(marker_bytes ++
        stream_info_header ++ stream_info_body ++
        application_header ++ application_body ++
        frame_body ++ [_]u8{
        @intCast(frame_footer_crc >> 8),
        @intCast(frame_footer_crc & 0xff),
    }));

    const stream = try Stream.read(&reader, std.testing.allocator);
    defer stream.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u32, 44_100), stream.stream_info.sample_rate);
    try std.testing.expectEqual(@as(usize, 1), stream.frames.len);
    try std.testing.expectEqual(@as(i64, 0), stream.frames[0].subframes[0].body.constant);
}

test "Stream.read rejects a stream whose first block is not STREAMINFO" {
    // Metadata block header: last, PADDING, length 0.
    const padding_header = [_]u8{ 0x81, 0x00, 0x00, 0x00 };
    const marker_bytes = [_]u8{ 'f', 'L', 'a', 'C' };
    var reader: std.Io.Reader = .fixed(&(marker_bytes ++ padding_header));
    try std.testing.expectError(error.MissingStreamInfo, Stream.read(&reader, std.testing.allocator));
}
