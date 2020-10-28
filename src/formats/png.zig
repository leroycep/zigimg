const Allocator = std.mem.Allocator;
const File = std.fs.File;
const FormatInterface = @import("../format_interface.zig").FormatInterface;
const ImageFormat = image.ImageFormat;
const ImageInStream = image.ImageInStream;
const ImageInfo = image.ImageInfo;
const ImageSeekStream = image.ImageSeekStream;
const PixelFormat = @import("../pixel_format.zig").PixelFormat;
const color = @import("../color.zig");
const errors = @import("../errors.zig");
const fs = std.fs;
const image = @import("../image.zig");
const io = std.io;
const mem = std.mem;
const path = std.fs.path;
const std = @import("std");
usingnamespace @import("../utils.zig");

const PNG_MAGIC_HEADER = [8]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' };

const ColorType = enum(u8) {
    Grayscale = 0,
    RGB = 2,
    Palette = 3,
    GrayscaleAlpha = 4,
    RGBA = 6,

    pub fn bit_depth_allowed(this: @This(), bit_depth: u8) bool {
        switch (this) {
            .Grayscale => return switch (bit_depth) {
                1, 2, 4, 8, 16 => true,
                else => false,
            },
            .RGB => return switch (bit_depth) {
                8, 16 => true,
                else => false,
            },
            .Palette => return switch (bit_depth) {
                1, 2, 4, 8 => true,
                else => false,
            },
            .GrayscaleAlpha => return switch (bit_depth) {
                8, 16 => true,
                else => false,
            },
            .RGBA => return switch (bit_depth) {
                8, 16 => true,
                else => false,
            },
        }
    }

    pub fn numComponents(this: @This()) usize {
        return switch (this) {
            .Grayscale => 1,
            .RGB => 3,
            .Palette => 1,
            .GrayscaleAlpha => 2,
            .RGBA => 4,
        };
    }
};

const CompressionMethod = enum(u8) {
    Deflate = 0,
};

const FilterMethod = enum(u8) {
    AdaptiveFiltering = 0,
};

const FilterAlgorithm = enum(u8) {
    None = 0,
    Sub = 1,
    Up = 2,
    Average = 3,
    Paeth = 4,

    fn reverse(this: @This(), filtered: []const u8, raw: []const u8, prior_raw: []const u8, current: usize, bpp: usize) u8 {
        std.debug.assert(raw.len == prior_raw.len);
        std.debug.assert(raw.len == filtered.len);

        const prev_byte = if (current >= bpp) raw[current - bpp] else 0;
        const prior_byte = prior_raw[current];
        const prev_prior_byte = if (current >= bpp) prior_raw[current - bpp] else 0;

        return switch (this) {
            .None => filtered[current],
            .Sub => filtered[current] +% prev_byte,
            .Up => filtered[current] +% prior_byte,
            .Average => filtered[current] +% ((prev_byte +% prior_byte) / 2),
            .Paeth => filtered[current] +% paethPredictor(prev_byte, prior_byte, prev_prior_byte),
        };
    }

    fn paethPredictor(a: u8, b: u8, c: u8) u8 {
        const ai = @intCast(i16, a);
        const bi = @intCast(i16, b);
        const ci = @intCast(i16, c);

        const p = ai + bi - ci;
        const pa = std.math.absInt(p - ai) catch unreachable;
        const pb = std.math.absInt(p - bi) catch unreachable;
        const pc = std.math.absInt(p - ci) catch unreachable;

        if (pa <= pb and pa <= pc) {
            return a;
        } else if (pb <= pc) {
            return b;
        } else {
            return c;
        }
    }
};

const InterlaceMethod = enum(u8) {
    None = 0,
    Adam7 = 1,
};

const Header = struct {
    width: u32,
    height: u32,
    bit_depth: u8,
    color_type: ColorType,
    compression_method: CompressionMethod,
    filter_method: FilterMethod,
    interlace_method: InterlaceMethod,

    pub fn fromSlice(slice: []const u8) !@This() {
        if (slice.len != 13) return error.InvalidHeaderLength;

        var inStream = std.io.fixedBufferStream(slice).reader();

        var this: @This() = undefined;
        this.width = try inStream.readIntBig(u32);
        this.height = try inStream.readIntBig(u32);
        this.bit_depth = try inStream.readIntBig(u8);
        this.color_type = try inStream.readEnum(ColorType, .Big);
        this.compression_method = try inStream.readEnum(CompressionMethod, .Big);
        this.filter_method = try inStream.readEnum(FilterMethod, .Big);
        this.interlace_method = try inStream.readEnum(InterlaceMethod, .Big);

        if (!this.color_type.bit_depth_allowed(this.bit_depth)) {
            return error.InvalidBitDepth;
        }

        return this;
    }
};

pub const Chunk = struct {
    allocator: *Allocator,
    len: u32,
    chunkType: ChunkType,
    data: []u8,
    crc: u32,

    pub fn readFromStream(allocator: *Allocator, inStream: ImageInStream) !@This() {
        var this: @This() = undefined;

        this.allocator = allocator;

        this.len = try inStream.readIntBig(u32);
        this.chunkType = try ChunkType.readFromStream(inStream);

        this.data = try allocator.alloc(u8, this.len);
        errdefer this.allocator.free(this.data);
        if ((try inStream.read(this.data[0..])) != this.data.len) {
            return error.UnexpctedEOF;
        }

        this.crc = try inStream.readIntBig(u32);

        return this;
    }

    pub fn deinit(this: @This()) void {
        this.allocator.free(this.data);
    }
};

pub const ChunkType = enum(u32) {
    IHDR = std.mem.readIntLittle(u32, "IHDR"),
    IDAT = std.mem.readIntLittle(u32, "IDAT"),
    IEND = std.mem.readIntLittle(u32, "IEND"),
    _,

    pub fn readFromStream(inStream: ImageInStream) !@This() {
        return @intToEnum(ChunkType, try inStream.readIntLittle(u32));
    }

    pub fn fromBytes(bytes: [4]u8) @This() {
        const typeInt = std.mem.readIntLittle(u32, &bytes);
        return @intToEnum(ChunkType, typeInt);
    }

    pub fn isCritical(this: @This()) bool {
        const code = @enumToInt(this);
        const is_critical_bit = 1 << 21;
        return code & is_critical_bit == is_critical_bit;
    }

    pub fn format(this: @This(), comptime fmt: []const u8, options: std.fmt.FormatOptions, writer: anytype) !void {
        const bytes = std.mem.toBytes(@enumToInt(this));
        return std.fmt.format(writer, "{}", .{bytes});
    }
};

pub const PNG = struct {
    header: Header = undefined,

    const Self = @This();

    pub fn formatInterface() FormatInterface {
        return FormatInterface{
            .format = @ptrCast(FormatInterface.FormatFn, format),
            .formatDetect = @ptrCast(FormatInterface.FormatDetectFn, formatDetect),
            .readForImage = @ptrCast(FormatInterface.ReadForImageFn, readForImage),
        };
    }

    pub fn format() ImageFormat {
        return ImageFormat.Png;
    }

    pub fn formatDetect(inStream: ImageInStream, seekStream: ImageSeekStream) !bool {
        var magicNumberBuffer: [PNG_MAGIC_HEADER.len]u8 = undefined;
        _ = try inStream.read(magicNumberBuffer[0..]);

        if (mem.eql(u8, magicNumberBuffer[0..], PNG_MAGIC_HEADER[0..])) {
            return true;
        }

        return false;
    }

    pub fn readForImage(allocator: *Allocator, inStream: ImageInStream, seekStream: ImageSeekStream, pixels: *?color.ColorStorage) !ImageInfo {
        var png = Self{};

        try png.read(allocator, inStream, seekStream, pixels);

        var imageInfo = ImageInfo{};
        imageInfo.width = @intCast(usize, png.width());
        imageInfo.height = @intCast(usize, png.height());
        // TODO: set the pixel format of image info
        //imageInfo.pixel_format = png.pixel_format;
        return imageInfo;
    }

    pub fn width(self: Self) i32 {
        return @intCast(i32, self.header.width);
    }

    pub fn height(self: Self) i32 {
        return @intCast(i32, self.header.height);
    }

    pub fn read(self: *Self, allocator: *Allocator, inStream: ImageInStream, seekStream: ImageSeekStream, pixelsOpt: *?color.ColorStorage) !void {
        // Read magic number
        var magicNumberBuffer: [PNG_MAGIC_HEADER.len]u8 = undefined;
        const bytes_read = try inStream.read(magicNumberBuffer[0..]);

        if (bytes_read != PNG_MAGIC_HEADER.len) {
            // Should be UnexpctedEOF instead?
            return errors.ImageError.InvalidMagicHeader;
        }

        if (!mem.eql(u8, magicNumberBuffer[0..], PNG_MAGIC_HEADER[0..])) {
            return errors.ImageError.InvalidMagicHeader;
        }

        var compressedData = std.ArrayList(u8).init(allocator);
        defer compressedData.deinit();

        var first = true;
        while (true) {
            defer first = false;

            const chunk = try Chunk.readFromStream(allocator, inStream);
            defer chunk.deinit();

            if (first and chunk.chunkType != .IHDR) return error.InvalidFormat;
            if (!first and chunk.chunkType == .IHDR) return error.InvalidFormat;

            switch (chunk.chunkType) {
                .IHDR => self.header = try Header.fromSlice(chunk.data),
                .IDAT => try compressedData.appendSlice(chunk.data),
                .IEND => break,
                else => |unknown| if (unknown.isCritical()) {
                    return error.UnknownChunkType;
                } else {
                    std.log.warn("Unknown chunk type: {}", .{unknown});
                },
            }
        }

        const pixel_format = try getPixelFormat(self.header.bit_depth, self.header.color_type);
        var pixel_storage = try color.ColorStorage.init(allocator, pixel_format, @intCast(usize, self.header.width * self.header.height));
        errdefer pixel_storage.deinit(allocator);

        // Ensure that the data uses the DEFLATE compression method
        std.debug.assert(self.header.compression_method == .Deflate);
        std.debug.assert(self.header.filter_method == .AdaptiveFiltering);

        // Decompress the data; this gives us the data that has been filtered per scanline
        var compressedDataStream = std.io.fixedBufferStream(compressedData.items);
        var zlib_stream = try std.compress.zlib.zlibStream(allocator, compressedDataStream.reader());
        defer zlib_stream.deinit();

        // TODO: base max size on width/height/pixelformat of data
        const filteredData = try zlib_stream.reader().readAllAlloc(allocator, 10000000000);
        defer allocator.free(filteredData);

        const scanline_len = self.header.width * self.header.color_type.numComponents() + 1;

        // Stuff we need to reverse the filtering
        var bytes_per_pixel = try getBytesPerPixel(self.header.bit_depth, self.header.color_type);

        var raw_data = try allocator.alloc(u8, scanline_len - 1);
        defer allocator.free(raw_data);

        var prior_raw_data = try allocator.alloc(u8, scanline_len - 1);
        defer allocator.free(prior_raw_data);
        std.mem.set(u8, prior_raw_data, 0);

        var line: usize = 0;
        while (line < self.header.height) : (line += 1) {
            const line_idx = scanline_len * line;

            const filter_algorithm = @intToEnum(FilterAlgorithm, filteredData[line_idx]);
            const scanline = filteredData[line_idx + 1 .. line_idx + scanline_len];

            for (raw_data) |*byte, idx| {
                byte.* = filter_algorithm.reverse(scanline, raw_data, prior_raw_data, idx, bytes_per_pixel);
            }

            var col: usize = 0;
            while (col < self.header.width) : (col += 1) {
                const pixel_idx = (line * self.header.width) + col;
                switch (pixel_storage) {
                    .Rgb24 => |rgb24| {
                        const r = raw_data[col * 3 + 0];
                        const g = raw_data[col * 3 + 1];
                        const b = raw_data[col * 3 + 2];
                        rgb24[pixel_idx] = color.Rgb24.initRGB(r, g, b);
                    },
                    .Rgba32 => |rgb32| {
                        const r = raw_data[col * 4 + 0];
                        const g = raw_data[col * 4 + 1];
                        const b = raw_data[col * 4 + 2];
                        const a = raw_data[col * 4 + 2];

                        rgb32[pixel_idx] = color.Rgba32.initRGBA(r, g, b, a);
                    },
                    else => {
                        return errors.ImageError.UnsupportedPixelFormat;
                    },
                }
            }

            // Make the current data the prior data
            var tmp = prior_raw_data;
            prior_raw_data = raw_data;
            raw_data = tmp;
        }

        pixelsOpt.* = pixel_storage;
    }

    fn getPixelFormat(bitDepth: u8, colorType: ColorType) !PixelFormat {
        if (bitDepth == 8 and colorType == .RGB) {
            return PixelFormat.Rgb24;
        } else if (bitDepth == 8 and colorType == .RGBA) {
            return PixelFormat.Rgba32;
        } else {
            std.log.debug("unsupported pixel format; bit depth {}, color type {}", .{ bitDepth, colorType });
            return errors.ImageError.UnsupportedPixelFormat;
        }
    }

    fn getBytesPerPixel(bitDepth: u8, colorType: ColorType) !usize {
        if (bitDepth == 8 and colorType == .RGB) {
            return 3;
        } else if (bitDepth == 8 and colorType == .RGBA) {
            return 4;
        } else {
            return errors.ImageError.UnsupportedPixelFormat;
        }
    }
};
