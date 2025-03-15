const std = @import("std");
const http = std.http;
const net = std.net;
const tls = std.crypto.tls;
const ArrayList = std.ArrayList;

const File = std.fs.File;
const Allocator = std.mem.Allocator;

const headers_max_size = 4096;

pub fn downloadPagesArchive(allocator: Allocator, fd: File, url: []const u8) !usize {
    const uri = try std.Uri.parse(url);

    var client = http.Client{ .allocator = allocator };
    defer client.deinit();

    var server_header_buffer: [8192]u8 = undefined;

    var connection = try client.open(.GET, uri, .{
        .server_header_buffer = &server_header_buffer,
    });
    defer connection.deinit();

    try connection.send();
    try connection.wait();
    try connection.finish();

    const response = connection.response;
    if (response.status != .ok) {
        std.debug.print("Unexpected status: {}\n", .{response.status});
        return error.UnexpectedStatus;
    }

    const body_stream = connection.reader();

    var buffer: [4096]u8 = undefined;
    var writer = fd.writer();
    var written_total: usize = 0;

    while (true) {
        const bytes_read = try body_stream.read(&buffer);
        if (bytes_read == 0) break;

        try writer.writeAll(buffer[0..bytes_read]);
        written_total += bytes_read;
    }

    try std.io.getStdOut().writer().print("Download complete!\n", .{});
    return written_total;
}
