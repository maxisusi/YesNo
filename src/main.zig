const std = @import("std");

const http = std.http;
const log = std.log.scoped(.server);

pub fn main() !void {

    // Set server ports
    const server_addr = "10.20.0.70";
    const server_port = 9333;

    // Definie memory allocator
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);

    const allocator = gpa.allocator();

    var server = http.Server.init(allocator, .{ .reuse_address = true });
    defer server.deinit();

    log.info("Server is running at {s}:{d}", .{ server_addr, server_port });

    // Launch server
    const address = std.net.Address.parseIp(server_addr, server_port) catch unreachable;
    try server.listen(address);

    runServer(&server, allocator) catch |err| {
        log.err("Server error: {}\n", .{err});

        if (@errorReturnTrace()) |trace| {
            std.debug.dumpStackTrace(trace.*);
        }
        std.os.exit(1);
    };
}

fn runServer(server: *http.Server, allocator: std.mem.Allocator) !void {
    outer: while (true) {
        var response = try server.accept(.{ .allocator = allocator });
        defer response.deinit();

        while (response.reset() != .closing) {
            response.wait() catch |err| switch (err) {
                error.HttpHeadersInvalid => continue :outer,
                error.EndOfStream => continue,
                else => return err,
            };

            try handleRequest(&response, allocator);
        }
    }
}

fn handleRequest(res: *http.Server.Response, allocator: std.mem.Allocator) !void {
    log.info("{s} {s} {s}", .{ @tagName(res.request.method), @tagName(res.request.version), res.request.target });

    var prng = std.rand.DefaultPrng.init(blk: {
        var seed: u64 = undefined;
        try std.os.getrandom(std.mem.asBytes(&seed));
        break :blk seed;
    });

    const rand = prng.random();
    const yes_no = rand.intRangeAtMost(u8, 0, 1);

    // Read the request
    const body = try res.reader().readAllAlloc(allocator, 8192);
    defer allocator.free(body);

    if (res.request.headers.contains("connection")) {
        try res.headers.append("connection", "keep-alive");
    }

    if (std.mem.startsWith(u8, res.request.target, "/")) {
        var html = std.ArrayList(u8).init(allocator);
        defer html.deinit();

        if (yes_no == 1) try html.appendSlice("<h1>Yes</h1>") else try html.appendSlice("<h1>No</h1>");

        res.transfer_encoding = .{ .content_length = html.items.len };
        try res.headers.append("content-type", "text/html");

        try res.do();

        if (res.request.method != .HEAD) {
            try res.writeAll(html.items);
            try res.finish();
        } else {
            res.status = .not_found;
            try res.do();
        }
    }
}
