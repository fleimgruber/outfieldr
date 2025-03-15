const std = @import("std");

const Allocator = std.mem.Allocator;
const File = std.fs.File;
const Dir = std.fs.Dir;

pub fn extractPages(allocator: Allocator, appdata: Dir, fd: File) !void {
    try fd.seekTo(0);

    var decompressed_data = std.ArrayList(u8).init(allocator);
    defer decompressed_data.deinit();

    try std.compress.gzip.decompress(fd.reader(), decompressed_data.writer());

    var tar_stream = std.io.fixedBufferStream(decompressed_data.items);
    const tar_reader = tar_stream.reader();

    try std.tar.pipeToFileSystem(appdata, tar_reader, .{ .mode_mode = .ignore });
}
