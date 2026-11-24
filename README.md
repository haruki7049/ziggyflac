# ziggyflac

A [FLAC](https://xiph.org/flac/) (Free Lossless Audio Codec) library written in Zig, following [RFC 9639](https://www.rfc-editor.org/rfc/rfc9639). It is pure Zig: it has no C dependencies (such as `libFLAC`) and no Zig dependencies.

It is made of two modules, one layered on the other:

- **`flacontainer`**: the low-level container layer. It parses and writes the raw structure of a FLAC stream (the `fLaC` marker, metadata blocks, and audio frames with their subframes) without interpreting the audio.
- **`ziggyflac`**: the high-level sample layer. It turns the parsed structure into PCM samples (decoding) and PCM samples into a FLAC stream (encoding). It builds on `flacontainer`.

The encoder is deliberately minimal: it produces correct streams, not small ones (see [Encoding](#encoding)).

## Requirements

Zig 0.16.0. This is the `minimum_zig_version` in `build.zig.zon`, and the version the tests are run with.

## Installation

Add the package to your `build.zig.zon`:

```sh
zig fetch --save git+https://github.com/haruki7049/ziggyflac
```

Then import the modules in your `build.zig`. Import `flacontainer` as well as `ziggyflac` if your code uses its types, as the examples below do:

```zig
const ziggyflac_dep = b.dependency("ziggyflac", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("flacontainer", ziggyflac_dep.module("flacontainer"));
exe.root_module.addImport("ziggyflac", ziggyflac_dep.module("ziggyflac"));
```

## Usage

### Decoding example

Read a FLAC byte sequence with `flacontainer.Stream.read`, then decode it to planar PCM samples with `ziggyflac.stream.decode`. `Stream.read` accepts any `std.Io.Reader`; this example reads a whole file into memory and reads from that.

```zig
const std = @import("std");
const flacontainer = @import("flacontainer");
const ziggyflac = @import("ziggyflac");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    const flac_bytes = try std.Io.Dir.cwd().readFileAlloc(init.io, "input.flac", allocator, .limited(1 << 28));
    defer allocator.free(flac_bytes);
    var reader: std.Io.Reader = .fixed(flac_bytes);

    // Parse the marker, the metadata blocks, and every frame.
    const stream = try flacontainer.Stream.read(&reader, allocator);
    defer stream.deinit(allocator);

    // Decode to planar PCM: `decoded.samples[channel][index]`.
    const decoded = try ziggyflac.stream.decode(allocator, stream);
    defer decoded.deinit(allocator);

    std.debug.print("{} Hz, {} channels, {} bits per sample, {} samples per channel\n", .{
        decoded.sample_rate,
        decoded.channels,
        decoded.bits_per_sample,
        decoded.samples[0].len,
    });
}
```

### Encoding example

Pass planar PCM samples to `ziggyflac.encoder.encode`, together with any `*std.Io.Writer`. This example writes one second of a stereo sine wave to a file.

```zig
const std = @import("std");
const ziggyflac = @import("ziggyflac");

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const sample_rate = 44100;

    // `samples[channel][index]`, as signed integers of the chosen bit depth.
    const left = try allocator.alloc(i64, sample_rate);
    defer allocator.free(left);
    const right = try allocator.alloc(i64, sample_rate);
    defer allocator.free(right);
    for (left, right, 0..) |*l, *r, i| {
        const seconds = @as(f64, @floatFromInt(i)) / sample_rate;
        const value: i64 = @intFromFloat(@round(@sin(2 * std.math.pi * 440 * seconds) * 20000));
        l.* = value;
        r.* = -value;
    }
    const samples = [_][]const i64{ left, right };

    var file = try std.Io.Dir.cwd().createFile(init.io, "output.flac", .{});
    defer file.close(init.io);
    var buffer: [4096]u8 = undefined;
    var file_writer = file.writer(init.io, &buffer);

    try ziggyflac.encoder.encode(allocator, &file_writer.interface, &samples, .{
        .sample_rate = sample_rate,
        .bits_per_sample = 16,
        .subframe_mode = .fixed0,
        .stream_info_mode = .complete,
    });
    try file_writer.interface.flush();
}
```

## Decoding

What `flacontainer.Stream.read` and `ziggyflac.stream.decode` support:

- **Stream**: native FLAC (`fLaC` marker). A leading ID3v2 tag is skipped if present.
- **Metadata blocks**: STREAMINFO, APPLICATION, SEEKTABLE, VORBIS_COMMENT, CUESHEET, and PICTURE are parsed and exposed on `flacontainer.Stream`. PADDING is skipped.
- **Frames**: fixed and variable block size streams, with all block size and sample rate codes of the frame header, including the uncommon ones. The CRC-8 of every frame header and the CRC-16 of every frame are verified.
- **Subframes**: CONSTANT, VERBATIM, FIXED (orders 0 to 4), and LPC (orders 1 to 32), including wasted bits.
- **Channels**: independent (1 to 8 channels), left/side, right/side, and mid/side. Decorrelation is undone, so the result is always one array per channel.
- **Output**: planar `i64` samples. Bit depths up to 32 are supported; the tests cover 8, 16, 24, and 32 bits per sample.

## Encoding

What `ziggyflac.encoder.encode` writes:

- **Stream**: the `fLaC` marker, a STREAMINFO block, and the audio frames. No other metadata block is written.
- **Subframes**: only VERBATIM and FIXED of order 0, chosen for the whole stream with `Options.subframe_mode`. FIXED order 0 stores the samples themselves, Rice coded with a per-subframe parameter and a single partition. A block containing the sample -2^31 (at 32 bits per sample) falls back to VERBATIM, as RFC 9639 Section 9.2.7.3 requires.
- **Channels**: independent only, 1 to 8 channels. There is no stereo decorrelation.
- **Blocks**: a fixed block size, `Options.block_size` (16 to 65535, 4096 by default), with only the last frame shorter. There is no variable block size.
- **Bit depth**: 4 to 32 bits per sample.
- **STREAMINFO**: `Options.stream_info_mode` chooses between `.complete` (minimum and maximum frame size, total sample count, and MD5 signature filled in) and `.unknown` (the values RFC 9639 defines as "not known": 0, and an all-zero MD5 signature). The block sizes are always set, to `Options.block_size`.
- **Memory**: the whole stream is encoded in memory before anything is written, because STREAMINFO comes first but depends on the frames. The output `*std.Io.Writer` therefore only receives sequential writes.
- **Compression**: not a goal. There are no predictors beyond FIXED order 0.

The output is not guaranteed to be in the FLAC streamable subset (RFC 9639 Section 7). It is only when all of these hold:

- the sample rate is one of 8, 16, 22.05, 24, 32, 44.1, 48, 88.2, 96, 176.4, or 192 kHz,
- the bit depth is one of 8, 12, 16, 20, 24, or 32,
- the block size is at most 16384, and at most 4608 if the sample rate is 48 kHz or lower.

Any other sample rate or bit depth is written as a reference to STREAMINFO instead of a frame header code, and any larger block size exceeds the limits above.

## Known limitations

- Decoding holds everything in memory. `Stream.read` reads from a `std.Io.Reader` as it goes, but keeps every parsed frame until `deinit`, and `stream.decode` then builds all samples at once. There is no streaming decode and no seeking. SEEKTABLE blocks are parsed, but not used.
- The STREAMINFO MD5 signature is not verified when decoding.
- Ogg FLAC is not supported: only native FLAC streams are read.
- Metadata blocks of a reserved type (RFC 9639 Section 8.1) are not skipped; they make `Stream.read` fail with `error.InvalidBlockType`.
- The encoder only writes VERBATIM and FIXED order 0 subframes, with independent channels and a fixed block size, so its output is larger than that of a real FLAC encoder.
- The encoder writes no metadata block other than STREAMINFO.
- The encoder's output is not guaranteed to be in the streamable subset (see [Encoding](#encoding)).

## Development

Zig 0.16.0 is required. A [Nix](https://nixos.org/) development shell with the formatters is defined in `flake.nix`.

```sh
zig build        # builds the ziggyflac and flacontainer static libraries
zig build test   # runs the tests of both modules
treefmt          # formats Zig, Nix, Markdown, GitHub Actions, and shell files
```

## License

Licensed under either of

- Apache License, Version 2.0 ([LICENSE-APACHE](LICENSE-APACHE))
- MIT license ([LICENSE-MIT](LICENSE-MIT))

at your option.
