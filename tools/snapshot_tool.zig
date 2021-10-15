const std = @import("std");
const mem = std.mem;

var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
const gpa = &general_purpose_allocator.allocator;

const Snapshot = struct {
    const Section = struct {
        name: []const u8,
        address: u64,
        size: u64,
    };

    const Symtab = struct {
        const Symbol = struct {
            name: []const u8,
            address: u64,
            section: u8,
        };

        locals: []Symbol,
        globals: []Symbol,
        undefs: []Symbol,
    };

    const ResolverEntry = struct {
        name: []const u8,
        where: enum {
            global,
            undef,

            pub fn jsonStringify(value: @This(), options: std.json.StringifyOptions, out_stream: anytype) !void {
                _ = options;
                switch (value) {
                    .global => try out_stream.writeAll("\"global\""),
                    .undef => try out_stream.writeAll("\"undef\""),
                }
            }
        },
        where_index: u32,
        local_sym_index: u32,
        file: i32,
    };

    const Node = struct {
        const Link = struct {
            source_address: u64,
            target_address: u64,
        };

        address: u64,
        size: u64,
        section: u8,
        links: []Link,
    };

    timestamp: i128,
    objects: [][]const u8,
    sections: []Section,
    symtab: Symtab,
    resolver: []ResolverEntry,
    nodes: []Node,
};

pub fn main() !void {
    var arena_allocator = std.heap.ArenaAllocator.init(gpa);
    const arena = &arena_allocator.allocator;
    const args = try std.process.argsAlloc(arena);

    if (args.len == 1) {
        std.debug.warn("not enough arguments\n", .{});
        usageAndExit(args[0]);
    }
    if (args.len > 2) {
        std.debug.warn("too many arguments\n", .{});
        usageAndExit(args[0]);
    }

    const first_arg = args[1];
    const file = try std.fs.cwd().openFile(first_arg, .{});
    defer file.close();
    const stat = try file.stat();
    const contents = try file.readToEndAlloc(arena, stat.size);
    const opts = std.json.ParseOptions{
        .allocator = arena,
    };
    const snapshots = try std.json.parse([]Snapshot, &std.json.TokenStream.init(contents), opts);
    defer std.json.parseFree([]Snapshot, snapshots, opts);
}

fn usageAndExit(arg0: []const u8) noreturn {
    std.debug.warn("Usage: {s} <input_json_file>\n", .{arg0});
    std.process.exit(1);
}
