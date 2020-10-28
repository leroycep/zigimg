const ImageInStream = zigimg.ImageInStream;
const ImageSeekStream = zigimg.ImageSeekStream;
const PixelFormat = zigimg.PixelFormat;
const assert = std.debug.assert;
const png = zigimg.png;
const color = zigimg.color;
const errors = zigimg.errors;
const std = @import("std");
const testing = std.testing;
const zigimg = @import("zigimg");
usingnamespace @import("helpers.zig");

test "Minimal one red pixel PNG" {
    const file = try testOpenFile(zigimg_test_allocator, "tests/fixtures/png/one_pixel_minimal.png");
    defer file.close();

    var thePng = png.PNG{};

    var stream_source = std.io.StreamSource{ .file = file };

    var pixelsOpt: ?color.ColorStorage = null;
    try thePng.read(zigimg_test_allocator, stream_source.inStream(), stream_source.seekableStream(), &pixelsOpt);

    defer {
        if (pixelsOpt) |pixels| {
            pixels.deinit(zigimg_test_allocator);
        }
    }

    expectEq(thePng.width(), 1);
    expectEq(thePng.height(), 1);

    testing.expect(pixelsOpt != null);
    testing.expect(pixelsOpt.? == .Rgb24);

    expectEq(pixelsOpt.?.Rgb24[0], color.Rgb24.initRGB(255, 0, 0));
}

test "tiles PNG" {
    const file = try testOpenFile(zigimg_test_allocator, "tests/fixtures/png/tiles.png");
    defer file.close();

    var thePng = png.PNG{};

    var stream_source = std.io.StreamSource{ .file = file };

    var pixelsOpt: ?color.ColorStorage = null;
    try thePng.read(zigimg_test_allocator, stream_source.inStream(), stream_source.seekableStream(), &pixelsOpt);

    defer {
        if (pixelsOpt) |pixels| {
            pixels.deinit(zigimg_test_allocator);
        }
    }

    expectEq(thePng.width(), 96);
    expectEq(thePng.height(), 64);

    testing.expect(pixelsOpt != null);
    testing.expect(pixelsOpt.? == .Rgba32);

    expectEq(pixelsOpt.?.Rgba32[0], color.Rgba32.initRGBA(0, 0, 0, 0));
    expectEq(pixelsOpt.?.Rgba32[96 * 24 + 16], color.Rgba32.initRGBA(255, 255, 255, 255));
}

//test "Read simple 8bpc RGB PNG" {
fn fdsajf() !void {
    const file = try testOpenFile(zigimg_test_allocator, "tests/fixtures/png/simple_8bpc_rgb.png");
    defer file.close();

    var thePng = png.PNG{};

    var stream_source = std.io.StreamSource{ .file = file };

    var pixelsOpt: ?color.ColorStorage = null;
    try thePng.read(zigimg_test_allocator, stream_source.inStream(), stream_source.seekableStream(), &pixelsOpt);

    defer {
        if (pixelsOpt) |pixels| {
            pixels.deinit(zigimg_test_allocator);
        }
    }

    expectEq(thePng.width(), 8);
    expectEq(thePng.height(), 1);

    testing.expect(pixelsOpt != null);
}
