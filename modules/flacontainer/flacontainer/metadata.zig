const std = @import("std");

/// The metadata block type, stored in the low 7 bits of a metadata block
/// header's first byte (RFC 9639 Section 8.1).
pub const BlockHeader = enum(u7) {
    stream_info,
    padding,
    application,
    seek_table,
    vorbis_comment,
    cue_sheet,
    picture,
};

/// A metadata block header (RFC 9639 Section 8.1): a 1-byte last-block flag
/// and block type, followed by a 24-bit big-endian block length in bytes
/// (not including the header itself).
pub const Header = struct {
    is_last: bool,
    block_type: BlockHeader,
    length: u24,

    /// Errors returned by `read`.
    pub const ReadError = std.Io.Reader.Error || error{
        /// The block type in the header is not one of the values defined by `BlockHeader`.
        InvalidBlockType,
    };

    /// Reads a metadata block header from `reader`.
    pub fn read(reader: *std.Io.Reader) ReadError!Header {
        const first_byte = try reader.takeByte();
        const is_last = (first_byte & 0x80) != 0;
        const type_bits: u7 = @intCast(first_byte & 0x7f);
        const block_type = std.enums.fromInt(BlockHeader, type_bits) orelse return error.InvalidBlockType;
        const length = try reader.takeVarInt(u24, .big, 3);

        return .{
            .is_last = is_last,
            .block_type = block_type,
            .length = length,
        };
    }
};

/// The STREAMINFO metadata block (RFC 9639 Section 8.2): fixed-size stream
/// properties that must be present as the first metadata block in a FLAC
/// stream.
pub const StreamInfo = struct {
    /// Minimum block size (in samples) used in the stream.
    min_block_size: u16,
    /// Maximum block size (in samples) used in the stream.
    max_block_size: u16,
    /// Minimum frame size (in bytes) used in the stream, or 0 if unknown.
    min_frame_size: u24,
    /// Maximum frame size (in bytes) used in the stream, or 0 if unknown.
    max_frame_size: u24,
    /// Sample rate in Hz.
    sample_rate: u20,
    /// Number of audio channels (decoded from the spec's zero-based field).
    channels: u4,
    /// Bits per sample (decoded from the spec's zero-based field).
    bits_per_sample: u6,
    /// Total number of interchannel samples in the stream, or 0 if unknown.
    total_samples: u36,
    /// MD5 signature of the unencoded audio data.
    md5_signature: [16]u8,

    /// Errors returned by `read`.
    pub const ReadError = std.Io.Reader.Error;

    /// Reads a STREAMINFO block body from `reader`. The 34-byte body is
    /// assumed to immediately follow a `Header` with `block_type == .stream_info`.
    pub fn read(reader: *std.Io.Reader) ReadError!StreamInfo {
        const min_block_size = try reader.takeInt(u16, .big);
        const max_block_size = try reader.takeInt(u16, .big);
        const min_frame_size = try reader.takeInt(u24, .big);
        const max_frame_size = try reader.takeInt(u24, .big);

        // Sample rate (20 bits), channels - 1 (3 bits), bits per sample - 1
        // (5 bits), and total samples (36 bits) are packed into 64 bits with
        // no byte alignment between fields.
        const packed_bits = try reader.takeInt(u64, .big);
        const sample_rate: u20 = @truncate(packed_bits >> 44);
        const channels_minus_one: u3 = @truncate(packed_bits >> 41);
        const bits_per_sample_minus_one: u5 = @truncate(packed_bits >> 36);
        const total_samples: u36 = @truncate(packed_bits);

        const md5_signature = (try reader.takeArray(16)).*;

        return .{
            .min_block_size = min_block_size,
            .max_block_size = max_block_size,
            .min_frame_size = min_frame_size,
            .max_frame_size = max_frame_size,
            .sample_rate = sample_rate,
            .channels = @as(u4, channels_minus_one) + 1,
            .bits_per_sample = @as(u6, bits_per_sample_minus_one) + 1,
            .total_samples = total_samples,
            .md5_signature = md5_signature,
        };
    }
};

/// The PADDING metadata block (RFC 9639 Section 8.3): `length` bytes of
/// unused space, whose contents carry no meaning.
pub const Padding = struct {
    /// Discards a PADDING block body of `length` bytes from `reader`.
    pub fn skip(reader: *std.Io.Reader, length: u24) std.Io.Reader.Error!void {
        try reader.discardAll(length);
    }
};

/// The APPLICATION metadata block (RFC 9639 Section 8.4): a 4-byte
/// registered application ID followed by application-defined data.
pub const Application = struct {
    id: [4]u8,
    /// Application-defined data, owned by this `Application` and freed by `deinit`.
    data: []u8,

    pub const ReadError = std.Io.Reader.ReadAllocError;

    /// Reads an APPLICATION block body of `length` bytes from `reader`.
    /// The returned value owns `data` and must be freed with `deinit`.
    pub fn read(reader: *std.Io.Reader, allocator: std.mem.Allocator, length: u24) ReadError!Application {
        const id = (try reader.takeArray(4)).*;
        const data = try reader.readAlloc(allocator, length - 4);
        return .{ .id = id, .data = data };
    }

    pub fn deinit(self: Application, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }
};

/// A single entry of a SEEKTABLE metadata block (RFC 9639 Section 8.5).
pub const SeekPoint = struct {
    /// Sample number of the first sample in the target frame, or all-ones
    /// (`std.math.maxInt(u64)`) for a placeholder point.
    sample_number: u64,
    /// Offset in bytes from the first byte of the first frame to the target frame.
    stream_offset: u64,
    /// Number of samples in the target frame.
    frame_samples: u16,

    pub fn read(reader: *std.Io.Reader) std.Io.Reader.Error!SeekPoint {
        return .{
            .sample_number = try reader.takeInt(u64, .big),
            .stream_offset = try reader.takeInt(u64, .big),
            .frame_samples = try reader.takeInt(u16, .big),
        };
    }
};

/// The SEEKTABLE metadata block (RFC 9639 Section 8.5): a table of seek points.
pub const SeekTable = struct {
    /// Seek points, owned by this `SeekTable` and freed by `deinit`.
    points: []SeekPoint,

    /// Size in bytes of a single seek point.
    pub const point_size: u24 = 18;

    pub const ReadError = std.Io.Reader.Error || std.mem.Allocator.Error;

    /// Reads a SEEKTABLE block body of `length` bytes from `reader`.
    /// The returned value owns `points` and must be freed with `deinit`.
    pub fn read(reader: *std.Io.Reader, allocator: std.mem.Allocator, length: u24) ReadError!SeekTable {
        const count = length / point_size;
        const points = try allocator.alloc(SeekPoint, count);
        errdefer allocator.free(points);
        for (points) |*point| point.* = try SeekPoint.read(reader);
        return .{ .points = points };
    }

    pub fn deinit(self: SeekTable, allocator: std.mem.Allocator) void {
        allocator.free(self.points);
    }
};

/// A single field of a VORBIS_COMMENT metadata block, in `NAME=VALUE` form.
pub const VorbisComment = struct {
    /// Vendor string, owned by this `VorbisComment` and freed by `deinit`.
    vendor: []u8,
    /// `NAME=VALUE` comment strings, owned by this `VorbisComment` and freed by `deinit`.
    comments: [][]u8,

    pub const ReadError = std.Io.Reader.ReadAllocError;

    /// Reads a VORBIS_COMMENT block body from `reader` (RFC 9639 Section 8.6).
    /// Unlike every other part of the FLAC container, all integers in this
    /// block are little-endian. The returned value owns `vendor` and
    /// `comments` and must be freed with `deinit`.
    pub fn read(reader: *std.Io.Reader, allocator: std.mem.Allocator) ReadError!VorbisComment {
        const vendor_length = try reader.takeInt(u32, .little);
        const vendor = try reader.readAlloc(allocator, vendor_length);
        errdefer allocator.free(vendor);

        const comment_count = try reader.takeInt(u32, .little);
        const comments = try allocator.alloc([]u8, comment_count);
        errdefer allocator.free(comments);

        var filled: usize = 0;
        errdefer for (comments[0..filled]) |comment| allocator.free(comment);
        while (filled < comment_count) : (filled += 1) {
            const comment_length = try reader.takeInt(u32, .little);
            comments[filled] = try reader.readAlloc(allocator, comment_length);
        }

        return .{ .vendor = vendor, .comments = comments };
    }

    pub fn deinit(self: VorbisComment, allocator: std.mem.Allocator) void {
        allocator.free(self.vendor);
        for (self.comments) |comment| allocator.free(comment);
        allocator.free(self.comments);
    }
};

/// A single index point of a CUESHEET track (RFC 9639 Section 8.7).
pub const CueSheetIndex = struct {
    offset: u64,
    number: u8,

    pub fn read(reader: *std.Io.Reader) std.Io.Reader.Error!CueSheetIndex {
        const offset = try reader.takeInt(u64, .big);
        const number = try reader.takeByte();
        try reader.discardAll(3); // reserved
        return .{ .offset = offset, .number = number };
    }
};

/// A single track of a CUESHEET metadata block (RFC 9639 Section 8.7).
pub const CueSheetTrack = struct {
    offset: u64,
    number: u8,
    isrc: [12]u8,
    is_audio: bool,
    pre_emphasis: bool,
    /// Index points, owned by this `CueSheetTrack` and freed by `deinit`.
    indices: []CueSheetIndex,

    pub const ReadError = std.Io.Reader.Error || std.mem.Allocator.Error;

    pub fn read(reader: *std.Io.Reader, allocator: std.mem.Allocator) ReadError!CueSheetTrack {
        const offset = try reader.takeInt(u64, .big);
        const number = try reader.takeByte();
        const isrc = (try reader.takeArray(12)).*;
        const flags = try reader.takeByte();
        try reader.discardAll(13); // reserved
        const index_count = try reader.takeByte();

        const indices = try allocator.alloc(CueSheetIndex, index_count);
        errdefer allocator.free(indices);
        for (indices) |*index| index.* = try CueSheetIndex.read(reader);

        return .{
            .offset = offset,
            .number = number,
            .isrc = isrc,
            .is_audio = (flags & 0x80) == 0,
            .pre_emphasis = (flags & 0x40) != 0,
            .indices = indices,
        };
    }

    pub fn deinit(self: CueSheetTrack, allocator: std.mem.Allocator) void {
        allocator.free(self.indices);
    }
};

/// The CUESHEET metadata block (RFC 9639 Section 8.7): cue sheet data akin to
/// a CD-DA table of contents.
pub const CueSheet = struct {
    media_catalog_number: [128]u8,
    lead_in_samples: u64,
    is_cd: bool,
    /// Tracks, owned by this `CueSheet` and freed by `deinit`.
    tracks: []CueSheetTrack,

    pub const ReadError = std.Io.Reader.Error || std.mem.Allocator.Error;

    /// Reads a CUESHEET block body from `reader`.
    /// The returned value owns `tracks` (and each track's index points) and
    /// must be freed with `deinit`.
    pub fn read(reader: *std.Io.Reader, allocator: std.mem.Allocator) ReadError!CueSheet {
        const media_catalog_number = (try reader.takeArray(128)).*;
        const lead_in_samples = try reader.takeInt(u64, .big);
        const flags = try reader.takeByte();
        try reader.discardAll(258); // reserved
        const track_count = try reader.takeByte();

        const tracks = try allocator.alloc(CueSheetTrack, track_count);
        var filled: usize = 0;
        errdefer {
            for (tracks[0..filled]) |track| track.deinit(allocator);
            allocator.free(tracks);
        }
        while (filled < track_count) : (filled += 1) {
            tracks[filled] = try CueSheetTrack.read(reader, allocator);
        }

        return .{
            .media_catalog_number = media_catalog_number,
            .lead_in_samples = lead_in_samples,
            .is_cd = (flags & 0x80) != 0,
            .tracks = tracks,
        };
    }

    pub fn deinit(self: CueSheet, allocator: std.mem.Allocator) void {
        for (self.tracks) |track| track.deinit(allocator);
        allocator.free(self.tracks);
    }
};

/// The picture type of a PICTURE metadata block (RFC 9639 Section 8.8, Table 14).
pub const PictureType = enum(u32) {
    other,
    file_icon,
    other_file_icon,
    front_cover,
    back_cover,
    leaflet_page,
    media,
    lead_artist,
    artist,
    conductor,
    band,
    composer,
    lyricist,
    recording_location,
    during_recording,
    during_performance,
    video_screen_capture,
    fish,
    illustration,
    band_logotype,
    publisher_logotype,
    _,
};

/// The PICTURE metadata block (RFC 9639 Section 8.8): an image associated
/// with the stream.
pub const Picture = struct {
    picture_type: PictureType,
    /// MIME type string, owned by this `Picture` and freed by `deinit`.
    mime_type: []u8,
    /// UTF-8 description, owned by this `Picture` and freed by `deinit`.
    description: []u8,
    width: u32,
    height: u32,
    depth: u32,
    colors: u32,
    /// Picture file data, owned by this `Picture` and freed by `deinit`.
    data: []u8,

    pub const ReadError = std.Io.Reader.ReadAllocError;

    /// Reads a PICTURE block body from `reader`.
    /// The returned value owns `mime_type`, `description`, and `data`, and
    /// must be freed with `deinit`.
    pub fn read(reader: *std.Io.Reader, allocator: std.mem.Allocator) ReadError!Picture {
        const picture_type: PictureType = @enumFromInt(try reader.takeInt(u32, .big));

        const mime_length = try reader.takeInt(u32, .big);
        const mime_type = try reader.readAlloc(allocator, mime_length);
        errdefer allocator.free(mime_type);

        const description_length = try reader.takeInt(u32, .big);
        const description = try reader.readAlloc(allocator, description_length);
        errdefer allocator.free(description);

        const width = try reader.takeInt(u32, .big);
        const height = try reader.takeInt(u32, .big);
        const depth = try reader.takeInt(u32, .big);
        const colors = try reader.takeInt(u32, .big);

        const data_length = try reader.takeInt(u32, .big);
        const data = try reader.readAlloc(allocator, data_length);

        return .{
            .picture_type = picture_type,
            .mime_type = mime_type,
            .description = description,
            .width = width,
            .height = height,
            .depth = depth,
            .colors = colors,
            .data = data,
        };
    }

    pub fn deinit(self: Picture, allocator: std.mem.Allocator) void {
        allocator.free(self.mime_type);
        allocator.free(self.description);
        allocator.free(self.data);
    }
};

test "each BlockHeader has u7 value" {
    try std.testing.expectEqual(@intFromEnum(BlockHeader.stream_info), 0);
    try std.testing.expectEqual(@intFromEnum(BlockHeader.padding), 1);
    try std.testing.expectEqual(@intFromEnum(BlockHeader.application), 2);
    try std.testing.expectEqual(@intFromEnum(BlockHeader.seek_table), 3);
    try std.testing.expectEqual(@intFromEnum(BlockHeader.vorbis_comment), 4);
    try std.testing.expectEqual(@intFromEnum(BlockHeader.cue_sheet), 5);
    try std.testing.expectEqual(@intFromEnum(BlockHeader.picture), 6);
}

test "Header.read parses a non-last STREAMINFO header" {
    var reader: std.Io.Reader = .fixed(&.{ 0x00, 0x00, 0x00, 0x22 });
    const header = try Header.read(&reader);
    try std.testing.expectEqual(false, header.is_last);
    try std.testing.expectEqual(BlockHeader.stream_info, header.block_type);
    try std.testing.expectEqual(@as(u24, 0x22), header.length);
}

test "Header.read parses the last-block flag" {
    var reader: std.Io.Reader = .fixed(&.{ 0x84, 0x00, 0x00, 0x10 });
    const header = try Header.read(&reader);
    try std.testing.expectEqual(true, header.is_last);
    try std.testing.expectEqual(BlockHeader.vorbis_comment, header.block_type);
    try std.testing.expectEqual(@as(u24, 0x10), header.length);
}

test "Header.read rejects an unknown block type" {
    var reader: std.Io.Reader = .fixed(&.{ 0x7f, 0x00, 0x00, 0x00 });
    try std.testing.expectError(error.InvalidBlockType, Header.read(&reader));
}

test "Header.read rejects a truncated stream" {
    var reader: std.Io.Reader = .fixed(&.{0x00});
    try std.testing.expectError(error.EndOfStream, Header.read(&reader));
}

test "StreamInfo.read parses a valid STREAMINFO body" {
    var reader: std.Io.Reader = .fixed(&.{
        0x10, 0x00, 0x10, 0x00,
        0x00, 0x03, 0xe8, 0x00,
        0x07, 0xd0, 0x0a, 0xc4,
        0x42, 0xf0, 0x00, 0x0f,
        0x42, 0x40, 0x00, 0x01,
        0x02, 0x03, 0x04, 0x05,
        0x06, 0x07, 0x08, 0x09,
        0x0a, 0x0b, 0x0c, 0x0d,
        0x0e, 0x0f,
    });
    const stream_info = try StreamInfo.read(&reader);

    try std.testing.expectEqual(@as(u16, 4096), stream_info.min_block_size);
    try std.testing.expectEqual(@as(u16, 4096), stream_info.max_block_size);
    try std.testing.expectEqual(@as(u24, 1000), stream_info.min_frame_size);
    try std.testing.expectEqual(@as(u24, 2000), stream_info.max_frame_size);
    try std.testing.expectEqual(@as(u20, 44100), stream_info.sample_rate);
    try std.testing.expectEqual(@as(u4, 2), stream_info.channels);
    try std.testing.expectEqual(@as(u6, 16), stream_info.bits_per_sample);
    try std.testing.expectEqual(@as(u36, 1_000_000), stream_info.total_samples);
    try std.testing.expectEqualSlices(u8, &.{
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
    }, &stream_info.md5_signature);
}

test "StreamInfo.read rejects a truncated stream" {
    var reader: std.Io.Reader = .fixed(&([_]u8{0x00} ** 10));
    try std.testing.expectError(error.EndOfStream, StreamInfo.read(&reader));
}

test "Padding.skip discards the block body" {
    var reader: std.Io.Reader = .fixed(&([_]u8{0xff} ** 5 ++ [_]u8{'X'}));
    try Padding.skip(&reader, 5);
    try std.testing.expectEqual(@as(u8, 'X'), try reader.takeByte());
}

test "Application.read parses the id and owns the data" {
    var reader: std.Io.Reader = .fixed(&.{ 'a', 'b', 'c', 'd', 0x01, 0x02, 0x03 });
    const app = try Application.read(&reader, std.testing.allocator, 7);
    defer app.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("abcd", &app.id);
    try std.testing.expectEqualSlices(u8, &.{ 0x01, 0x02, 0x03 }, app.data);
}

test "SeekTable.read parses seek points" {
    var reader: std.Io.Reader = .fixed(&([_]u8{0x00} ** 7 ++ [_]u8{0x01} ++ // sample_number = 1
        [_]u8{0x00} ** 7 ++ [_]u8{0x02} ++ // stream_offset = 2
        [_]u8{ 0x10, 0x00 } // frame_samples = 4096
    ));
    const table = try SeekTable.read(&reader, std.testing.allocator, SeekTable.point_size);
    defer table.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), table.points.len);
    try std.testing.expectEqual(@as(u64, 1), table.points[0].sample_number);
    try std.testing.expectEqual(@as(u64, 2), table.points[0].stream_offset);
    try std.testing.expectEqual(@as(u16, 4096), table.points[0].frame_samples);
}

test "VorbisComment.read parses the vendor string and comments" {
    var reader: std.Io.Reader = .fixed(&[_]u8{
        4, 0, 0, 0, 't', 'e', 's', 't', // vendor
        1,   0,   0,   0, // comment count
        7,   0,   0,   0,
        'T', 'I', 'T', 'L',
        'E', '=', 'x', // comment
    });
    const comment = try VorbisComment.read(&reader, std.testing.allocator);
    defer comment.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("test", comment.vendor);
    try std.testing.expectEqual(@as(usize, 1), comment.comments.len);
    try std.testing.expectEqualStrings("TITLE=x", comment.comments[0]);
}

test "CueSheet.read parses a track with one index point" {
    var reader: std.Io.Reader = .fixed(&([_]u8{0} ** 128 ++ // media catalog number
        [_]u8{0} ** 7 ++ [_]u8{0} ++ // lead-in samples
        [_]u8{0x80} ++ // flags: is_cd
        [_]u8{0} ** 258 ++ // reserved
        [_]u8{1} ++ // track count
        // track
        [_]u8{0} ** 7 ++ [_]u8{0} ++ // track offset
        [_]u8{1} ++ // track number
        [_]u8{0} ** 12 ++ // ISRC
        [_]u8{0x00} ++ // flags: audio, no pre-emphasis
        [_]u8{0} ** 13 ++ // reserved
        [_]u8{1} ++ // index point count
        [_]u8{0} ** 7 ++ [_]u8{0} ++ // index offset
        [_]u8{1} ++ // index number
        [_]u8{0} ** 3 // reserved
    ));
    const cue_sheet = try CueSheet.read(&reader, std.testing.allocator);
    defer cue_sheet.deinit(std.testing.allocator);

    try std.testing.expectEqual(true, cue_sheet.is_cd);
    try std.testing.expectEqual(@as(usize, 1), cue_sheet.tracks.len);
    try std.testing.expectEqual(@as(u8, 1), cue_sheet.tracks[0].number);
    try std.testing.expectEqual(true, cue_sheet.tracks[0].is_audio);
    try std.testing.expectEqual(false, cue_sheet.tracks[0].pre_emphasis);
    try std.testing.expectEqual(@as(usize, 1), cue_sheet.tracks[0].indices.len);
    try std.testing.expectEqual(@as(u8, 1), cue_sheet.tracks[0].indices[0].number);
}

test "Picture.read parses metadata and owns its buffers" {
    var reader: std.Io.Reader = .fixed(&[_]u8{
        0, 0, 0, 3, // picture_type = front_cover
        0, 0, 0, 4, 'p', 'n', 'g', '/', // mime type
        0, 0, 0, 0, // description (empty)
        0, 0, 0, 1, // width
        0, 0, 0, 1, // height
        0, 0, 0, 8, // depth
        0, 0, 0, 0, // colors
        0, 0, 0, 2, 0xaa, 0xbb, // data
    });
    const picture = try Picture.read(&reader, std.testing.allocator);
    defer picture.deinit(std.testing.allocator);

    try std.testing.expectEqual(PictureType.front_cover, picture.picture_type);
    try std.testing.expectEqualStrings("png/", picture.mime_type);
    try std.testing.expectEqualStrings("", picture.description);
    try std.testing.expectEqual(@as(u32, 1), picture.width);
    try std.testing.expectEqual(@as(u32, 8), picture.depth);
    try std.testing.expectEqualSlices(u8, &.{ 0xaa, 0xbb }, picture.data);
}
