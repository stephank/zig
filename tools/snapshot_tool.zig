const std = @import("std");
const log = std.log.scoped(.snapshot);
const mem = std.mem;

const Allocator = mem.Allocator;

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

    const out_file = try std.fs.cwd().createFile("snapshots.html", .{
        .truncate = true,
        .read = true,
    });
    defer out_file.close();

    const writer = out_file.writer();

    try writer.writeAll("<html>\n");
    try writer.writeAll("<head></head>\n");
    try writer.writeAll("<body>\n");

    for (snapshots) |snapshot| {
        try writer.writeAll("<svg width=\"100%\" height=\"100%\">\n");
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

        var snapshot_rect = Rect{
            .width = 300,
            .height = 0,
            .x = 0,
            .y = 0,
            .address = 0,
            .size = 0,
        };

        for (snapshot.sections) |section| {
            const prev_rect = snapshot_rect.lastChild();
            const sect_rect = try snapshot_rect.addChild(arena);
            sect_rect.y = if (prev_rect) |pr| pr.y + pr.height else 0;
            sect_rect.width = snapshot_rect.width;
            sect_rect.height = 50;
            sect_rect.address = section.address;
            sect_rect.size = section.size;
            sect_rect.name = section.name;
            snapshot_rect.size += section.size;

            for (section.nodes) |node| {
                const prev_node_rect = sect_rect.lastChild();
                const node_rect = try sect_rect.addChild(arena);
                node_rect.x = sect_rect.x + 10;
                node_rect.y = if (prev_node_rect) |pr| pr.y + 20 else sect_rect.y + 30;
                node_rect.width = sect_rect.width - 20;
                node_rect.height = 20;
                node_rect.address = node.address;
                node_rect.size = node.size;

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
                    _ = sym;
                }

                sect_rect.height += node_rect.height;
            }

            snapshot_rect.height += sect_rect.height;
        }

        try snapshot_rect.toHtml(writer);
        try writer.writeAll("</svg>\n");
    }

    try writer.writeAll("</body>\n");
    try writer.writeAll("</html>\n");
}

fn usageAndExit(arg0: []const u8) noreturn {
    std.debug.warn("Usage: {s} <input_json_file>\n", .{arg0});
    std.process.exit(1);
}

const Rect = struct {
    width: usize,
    height: usize,
    x: usize,
    y: usize,
    address: u64,
    size: u64,
    name: ?[]const u8 = null,
    children: std.ArrayListUnmanaged(*Rect) = .{},

    fn deinit(rect: *Rect, allocator: *Allocator) void {
        for (rect.children.items) |child| {
            child.deinit(allocator);
            allocator.destroy(child);
        }
        rect.children.deinit(allocator);
    }

    fn addChild(rect: *Rect, allocator: *Allocator) !*Rect {
        const child = try allocator.create(Rect);
        errdefer allocator.destroy(child);
        child.* = .{
            .width = 0,
            .height = 0,
            .x = 0,
            .y = 0,
            .address = 0,
            .size = 0,
        };
        try rect.children.append(allocator, child);
        return child;
    }

    fn lastChild(rect: Rect) ?*Rect {
        if (rect.children.items.len == 0) return null;
        return rect.children.items[rect.children.items.len - 1];
    }

    fn toHtml(rect: Rect, writer: anytype) @TypeOf(writer).Error!void {
        try writer.print("<rect width='{d}' height='{d}' x='{d}' y='{d}' fill='none' stroke='black' />\n", .{
            rect.width,
            rect.height,
            rect.x,
            rect.y,
        });
        if (rect.name) |name| {
            try writer.print("<text x='{d}' y='{d}'>{s}</text>", .{ rect.x + 10, rect.y + 20, name });
        }
        try writer.print("<text x='{d}' y='{d}'>{x}</text>", .{ 305, rect.y + 12, rect.address });
        for (rect.children.items) |child| {
            try child.toHtml(writer);
        }
    }
};
