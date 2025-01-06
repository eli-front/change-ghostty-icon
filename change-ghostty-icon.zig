const std = @import("std");

const ghostty_path = "/Applications/Ghostty.app";
const custom_icon_path = "new-icon.icns";
const resource_description_path = "out.r";

const c = @cImport({
    @cInclude("sys/xattr.h"); // there is `std.os.linux.setxattr` for linux, which might work for unix systems, but I thought this was more correct
});

fn removeExtendedAttribute(filepath: [*:0]const u8, attrname: [*:0]const u8) void {
    const result = c.removexattr(filepath, attrname, 0);
    if (result != 0) {
        const errno = std.posix.errno(result);
        std.debug.print("Failed to remove xattr '{s}': {d}\n", .{ attrname, errno });

        return;
    }

    std.debug.print("Successfully removed xattr '{s}' from '{s}'\n", .{ attrname, filepath });
}

fn setExtendedAttribute(filepath: []const u8, attrname: []const u8, value: ?*const anyopaque, size: usize) void {
    const result = c.setxattr(@ptrCast(filepath), @ptrCast(attrname), value, size, 0, 0);
    if (result != 0) {
        const errno = std.posix.errno(result);
        std.debug.print("Failed to set xattr '{s}': {d}\n", .{ attrname, errno });
        return;
    }

    std.debug.print("Successfully set xattr '{s}' on '{}'\n", .{ attrname, std.zig.fmtEscapes(filepath) });
}

fn getExtendedAttribute(filepath: [*:0]const u8, attrname: [*:0]const u8) ?struct {
    length: usize,
    buffer: []u8,
} {
    // const size: usize = @intCast(c.getxattr(filepath, attrname, null, 0, 0, 0));

    var buffer: [96637]u8 = undefined;
    const result: usize = @intCast(c.getxattr(filepath, attrname, &buffer, 96637, 0, 0));
    std.debug.print("max size {d}\n", .{std.math.maxInt(usize)});
    std.debug.print("result: {d}\n", .{result});
    if (result == -1) {
        const errno = std.posix.errno(result);
        std.debug.print("Failed to get xattr '{s}': {d}\n", .{ attrname, errno });
        return null;
    }

    std.debug.print("result type: {s}\n", .{@typeName(@TypeOf(result))});
    return .{
        .length = result,
        .buffer = buffer[0..result],
    };
}

fn removeCustomIcon() !void {
    removeExtendedAttribute(ghostty_path, "com.apple.FinderInfo");
    _ = std.fs.deleteFileAbsolute(ghostty_path ++ "/Icon\r") catch 0;
}

fn setCustomIcon() !void {
    var finder_xattr = [_]u8{0} ** 32; // Initialize a 32-byte array with all zeros

    finder_xattr[8] = 0x04; // Set finder flag for `kHasCustomIcon` https://developer.apple.com/documentation/coreservices/1429609-anonymous/khascustomicon?language=objc
    setExtendedAttribute(ghostty_path, "com.apple.FinderInfo", &finder_xattr, 32);

    // Set filetype to icon 69 63 6F 6E (optional)
    finder_xattr[0] = 0x69;
    finder_xattr[1] = 0x63;
    finder_xattr[2] = 0x6F;
    finder_xattr[3] = 0x6E;

    // Set creator to GHST 47 48 53 54 (optional)
    finder_xattr[4] = 0x47;
    finder_xattr[5] = 0x48;
    finder_xattr[6] = 0x53;
    finder_xattr[7] = 0x54;

    // Set finder flags
    finder_xattr[8] = 0x40; // kIsInvisible https://developer.apple.com/documentation/coreservices/1429609-anonymous/kisinvisible?language=objc

    _ = try std.fs.createFileAbsolute(ghostty_path ++ "/Icon\r", .{});

    // Set required extended attributes for custom icon
    setExtendedAttribute(ghostty_path ++ "/Icon\r", "com.apple.FinderInfo", &finder_xattr, 32);
    setExtendedAttribute(ghostty_path ++ "/Icon\r", "com.apple.ResourceFork", null, 0);
}

fn formatIcnsHex(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    // We'll build the grouped-hex string into a StringBuilder, then return it as a []u8 slice.
    // var builder = std.StringBuilder.init(allocator);
    var list = std.ArrayList(u8).init(allocator);
    defer list.deinit();
    //$"6963 6E73 0001 E176 6963 3132 0000 0740"

    for (bytes, 0..) |byte, i| {
        var buf: [40]u8 = undefined;
        const hex = try std.fmt.bufPrint(&buf, "{X:0>2}", .{byte});

        if (i == 0) {
            try list.append('$');
            try list.append('"');
        } else if (i == bytes.len - 1) {
            try list.appendSlice(hex);
            try list.append('"');
            break;
        } else if (i % 16 == 0) {
            try list.append('"');
            try list.append('\n');
            try list.append('$');
            try list.append('"');
        } else if (i % 2 == 0) {
            try list.append(' ');
        }

        try list.appendSlice(hex);
    }

    return list.toOwnedSlice();
}
pub fn main() !void {
    try removeCustomIcon(); // clear custom icon if already set
    try setCustomIcon();

    const max_size = 1_048_576; // 1MB

    const new_icon_file = try std.fs.cwd().readFileAlloc(std.heap.page_allocator, custom_icon_path, max_size);

    const hex_body_string = try formatIcnsHex(std.heap.page_allocator, new_icon_file);

    const resource_description = try std.fmt.allocPrint(std.heap.page_allocator, "data 'icns' (-16455) {{\n{s}\n}};", .{hex_body_string});

    // save to out.r
    const out_file = try std.fs.cwd().createFile(resource_description_path, .{});

    defer out_file.close();

    try out_file.writeAll(resource_description);

    const rez_argv = [_][]const u8{ "Rez", resource_description_path, "-o", ghostty_path ++ "/Icon\r" };

    _ = try std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &rez_argv,
    });

    // delete out.r
    _ = try std.fs.cwd().deleteFile(resource_description_path);

    // verify the codesign
    const codesign_argv = [_][]const u8{ "codesign", "--verify", "--verbose", ghostty_path };

    const codesign_res = try std.process.Child.run(.{
        .allocator = std.heap.page_allocator,
        .argv = &codesign_argv,
    });

    if (codesign_res.stdout.len != 0) {
        std.debug.print("Failed codesign '{s}'\n", .{ghostty_path});
    } else {
        std.debug.print("Valid codesign '{s}'\n", .{ghostty_path});
    }
}
