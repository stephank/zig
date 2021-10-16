const std = @import("std");
const mem = std.mem;

var general_purpose_allocator = std.heap.GeneralPurposeAllocator(.{}){};
const gpa = &general_purpose_allocator.allocator;

const Snapshot = struct {
    const Section = struct {
        name: []const u8,
        address: u64,
        size: u64,
        nodes: []Node,
    };

    const Node = struct {
        const Link = struct {
            source_address: u64,
            target_address: u64,
        };

        address: u64,
        size: u64,
        links: []Link,
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

    timestamp: i128,
    objects: [][]const u8,
    sections: []Section,
    symtab: Symtab,
    resolver: []ResolverEntry,
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

    for (snapshots) |snapshot| {
        std.debug.warn("Snapshot {d}\n\n", .{snapshot.timestamp});

        var symtab = std.AutoHashMap(u64, std.ArrayList(Snapshot.Symtab.Symbol)).init(arena);

        for (snapshot.symtab.globals) |sym| {
            const res = try symtab.getOrPut(sym.address);
            if (!res.found_existing) {
                res.value_ptr.* = std.ArrayList(Snapshot.Symtab.Symbol).init(arena);
            }
            try res.value_ptr.append(sym);
        }
        for (snapshot.symtab.locals) |sym| {
            const res = try symtab.getOrPut(sym.address);
            if (!res.found_existing) {
                res.value_ptr.* = std.ArrayList(Snapshot.Symtab.Symbol).init(arena);
            }
            try res.value_ptr.append(sym);
        }

        for (snapshot.sections) |section| {
            std.debug.warn("{s:-<25}  {x}\n", .{ section.name, section.address });

            for (section.nodes) |node, node_id| {
                if (node_id > 0) {
                    std.debug.print("\n", .{});
                }
                if (symtab.get(node.address)) |syms| {
                    std.debug.print("   / {s:.<20}  {x}\n", .{ syms.items[0].name, node.address });
                } else {
                    std.debug.print("   / {s:.<20}  {x}\n", .{ "unnamed", node.address });
                }

                var symbols = std.AutoHashMap(u64, Snapshot.Symtab.Symbol).init(arena);

                for (snapshot.symtab.globals) |sym| {
                    if (sym.address == node.address) continue;
                    if (node.address <= sym.address and sym.address < node.address + node.size) {
                        if (symbols.contains(sym.address)) continue;
                        try symbols.putNoClobber(sym.address, sym);
                    }
                }
                for (snapshot.symtab.locals) |sym| {
                    if (sym.address == node.address) continue;
                    if (node.address <= sym.address and sym.address < node.address + node.size) {
                        if (symbols.contains(sym.address)) continue;
                        try symbols.putNoClobber(sym.address, sym);
                    }
                }

                var it = symbols.valueIterator();
                while (it.next()) |sym| {
                    std.debug.print("  | {s: <21}\n", .{""});
                    std.debug.print("  | {s: <21}  {x}\n", .{ sym.name, sym.address });
                }

                std.debug.print("  | {s: <21}\n", .{""});

                std.debug.print("   \\ {s:.<20}  {x}\n", .{ "", node.address + node.size });
            }

            std.debug.warn("{s:-<25}  {x}\n\n", .{ "", section.address + section.size });
        }

        std.debug.warn("\n", .{});
    }
}

fn usageAndExit(arg0: []const u8) noreturn {
    std.debug.warn("Usage: {s} <input_json_file>\n", .{arg0});
    std.process.exit(1);
}
