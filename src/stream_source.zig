// SPDX-License-Identifier: MIT
// Copyright (c) 2015-2021 Zig Contributors
// This file is part of [zig](https://ziglang.org/), which is MIT licensed.
// The MIT license requires this copyright notice to be included in all copies
// and substantial portions of the software.
const std = @import("std");
const io = std.io;
const testing = std.testing;

/// Provides `io.Reader`, `io.Writer`, and `io.SeekableStream` for in-memory buffers as
/// well as files.
/// For memory sources, if the supplied byte buffer is const, then `io.Writer` is not available.
/// The error set of the stream functions is the error set of the corresponding file functions.
pub const StreamSource = struct {
    read: fn (self: *StreamSource, dest: []u8) ReadError!usize,
    write: fn (self: *StreamSource, bytes: []const u8) WriteError!usize = writeNotSupported,
    seekTo: fn (self: *StreamSource, pos: u64) SeekError!void,
    seekBy: fn (self: *StreamSource, amt: i64) SeekError!void,
    getEndPos: fn (self: *StreamSource) GetSeekPosError!u64,
    getPos: fn (self: *StreamSource) GetSeekPosError!u64,

    pub const ReadError = std.fs.File.ReadError;
    pub const WriteError = std.fs.File.WriteError;
    pub const SeekError = std.fs.File.SeekError;
    pub const GetSeekPosError = std.fs.File.GetSeekPosError;

    pub const Reader = io.Reader(*StreamSource, ReadError, read);
    pub const Writer = io.Writer(*StreamSource, WriteError, write);
    pub const SeekableStream = io.SeekableStream(
        *StreamSource,
        SeekError,
        GetSeekPosError,
        seekTo,
        seekBy,
        getPos,
        getEndPos,
    );

    pub fn read(self: *StreamSource, dest: []u8) ReadError!usize {
        return self.read(self, dest);
    }

    pub fn write(self: *StreamSource, bytes: []const u8) WriteError!usize {
        return self.write(self, bytes);
    }

    pub fn seekTo(self: *StreamSource, pos: u64) SeekError!void {
        return self.seekTo(self, pos);
    }

    pub fn seekBy(self: *StreamSource, amt: i64) SeekError!void {
        return self.seekBy(self, amt);
    }

    pub fn getEndPos(self: *StreamSource) GetSeekPosError!u64 {
        return self.getEndPos(
            self,
        );
    }

    pub fn getPos(self: *StreamSource) GetSeekPosError!u64 {
        return self.getPos(
            self,
        );
    }

    fn writeNotSupported(self: *StreamSource, bytes: []const u8) WriteError!usize {
        return error.AccessDenied;
    }

    pub fn reader(self: *StreamSource) Reader {
        return .{ .context = self };
    }

    pub fn writer(self: *StreamSource) Writer {
        return .{ .context = self };
    }

    pub fn seekableStream(self: *StreamSource) SeekableStream {
        return .{ .context = self };
    }
};

pub fn FixedBufferStreamSource(comptime Buffer: type) type {
    return struct {
        fbs: io.FixedBufferStream(Buffer),
        stream_source: StreamSource = StreamSource{
            .read = read,
            .write = write,
            .seekTo = seekTo,
            .seekBy = seekBy,
            .getEndPos = getEndPos,
            .getPos = getPos,
        },

        pub const ReadError = StreamSource.ReadError;
        pub const WriteError = StreamSource.WriteError;
        pub const SeekError = StreamSource.SeekError;
        pub const GetSeekPosError = StreamSource.GetSeekPosError;

        pub fn init(this: *@This(), buffer: Buffer) void {
            this.* = .{
                .fbs = io.fixedBufferStream(buffer),
            };
        }

        fn read(stream_source: *StreamSource, dest: []u8) ReadError!usize {
            const this = @fieldParentPtr(@This(), "stream_source", stream_source);
            return this.fbs.read(dest);
        }

        fn write(stream_source: *StreamSource, bytes: []const u8) WriteError!usize {
            const this = @fieldParentPtr(@This(), "stream_source", stream_source);
            switch (Buffer) {
                []u8 => return this.fbs.write(bytes),
                []const u8 => return error.AccessDenied,
                else => @compileError("Type not supported in FixedBufferStreamSource: " ++ @typeName(Buffer)),
            }
        }

        fn seekTo(stream_source: *StreamSource, pos: u64) SeekError!void {
            const this = @fieldParentPtr(@This(), "stream_source", stream_source);
            return this.fbs.seekTo(pos);
        }

        fn seekBy(stream_source: *StreamSource, amt: i64) SeekError!void {
            const this = @fieldParentPtr(@This(), "stream_source", stream_source);
            return this.fbs.seekBy(amt);
        }

        fn getEndPos(stream_source: *StreamSource) GetSeekPosError!u64 {
            const this = @fieldParentPtr(@This(), "stream_source", stream_source);
            return this.fbs.getEndPos();
        }

        fn getPos(stream_source: *StreamSource) GetSeekPosError!u64 {
            const this = @fieldParentPtr(@This(), "stream_source", stream_source);
            return this.fbs.getPos();
        }
    };
}
