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

const css_style: []const u8 =
    \\<style>
    \\  .rect {
    \\    fill:none;
    \\    stroke:black;
    \\  }
    \\  .snapshot-div {
    \\    height:100%;
    \\    width:100%;
    \\    overflow:scroll;
    \\  }
    \\</style>
;

const SvgElement = struct {
    const Tag = enum {
        svg,
        rect,
        text,
    };

    width: usize,
    height: usize,
    x: usize,
    y: usize,
    css_class: ?[]const u8,
    tag: Tag,
    children: std.ArrayListUnmanaged(*SvgElement) = .{},
    contents: ?[]const u8,

    fn new(allocator: *Allocator) !*SvgElement {
        const svg_el = try allocator.create(SvgElement);
        svg_el.* = .{
            .width = 0,
            .height = 0,
            .x = 0,
            .y = 0,
            .css_class = null,
            .tag = .svg,
            .contents = null,
        };
        return svg_el;
    }

    fn newChild(self: *SvgElement, allocator: *Allocator) !*SvgElement {
        const child = try SvgElement.new(allocator);
        errdefer allocator.destroy(child);
        try self.children.append(allocator, child);
        return child;
    }

    fn deinit(self: *SvgElement, allocator: *Allocator) void {
        for (self.children.items) |child| {
            child.deinit(allocator);
            allocator.destroy(child);
        }
        self.children.deinit(allocator);
    }

    fn render(self: SvgElement, writer: anytype) @TypeOf(writer).Error!void {
        switch (self.tag) {
            .svg => try writer.writeAll("<svg "),
            .rect => try writer.writeAll("<rect "),
            .text => try writer.writeAll("<text "),
        }
        try writer.print("x='{d}' y='{d}' width='{d}' height='{d}' ", .{ self.x, self.y, self.width, self.height });
        if (self.css_class) |class| {
            try writer.print("class='{s}' ", .{class});
        }
        if (self.children.items.len == 0 and self.contents == null) {
            return writer.writeAll("/>\n");
        }
        try writer.writeAll(">\n");
        for (self.children.items) |child| {
            try child.render(writer);
        }
        if (self.contents) |contents| {
            try writer.writeAll(contents);
        }
        switch (self.tag) {
            .svg => try writer.writeAll("</svg>\n"),
            .rect => try writer.writeAll("</rect>\n"),
            .text => try writer.writeAll("</text>\n"),
        }
    }
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
    try writer.writeAll(css_style);

    for (snapshots) |snapshot| {
        try writer.writeAll("<div class='snapshot-div'>\n");

        const svg_snap = try SvgElement.new(arena);
        svg_snap.width = 400;
        svg_snap.height = 0;

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

        var last_svg_sect: ?*SvgElement = null;
        for (snapshot.sections) |section| {
            // <rect> delimiting box
            const svg_sect = try svg_snap.newChild(arena);
            svg_sect.tag = .rect;
            svg_sect.css_class = "rect";
            svg_sect.y = if (last_svg_sect) |last| last.y + last.height else 0;
            svg_sect.width = svg_snap.width - 100;
            svg_sect.height = 50;
            last_svg_sect = svg_sect;
            {
                // <text> with section name
                const svg_sect_name = try svg_snap.newChild(arena);
                svg_sect_name.tag = .text;
                svg_sect_name.x = svg_sect.x + 10;
                svg_sect_name.y = svg_sect.y + 20;
                svg_sect_name.contents = section.name;
                // <text> with start address
                const svg_sect_addr = try svg_snap.newChild(arena);
                svg_sect_addr.tag = .text;
                svg_sect_addr.x = svg_snap.width - 100 + 5;
                svg_sect_addr.y = svg_sect.y + 12;
                svg_sect_addr.contents = try std.fmt.allocPrint(arena, "{x}", .{section.address});
            }

            var last_svg_atom: ?*SvgElement = null;
            for (section.nodes) |node| {
                // <rect> delimiting box
                const svg_atom = try svg_snap.newChild(arena);
                svg_atom.tag = .rect;
                svg_atom.css_class = "rect";
                svg_atom.x = svg_sect.x + 10;
                svg_atom.y = if (last_svg_atom) |last| last.y + last.height else svg_sect.y + 30;
                svg_atom.width = svg_sect.width - 20;
                svg_atom.height = 20;
                last_svg_atom = svg_atom;

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

                svg_sect.height += svg_atom.height;
            }

            svg_snap.height += svg_sect.height;
        }

        try svg_snap.render(writer);
    }

    try writer.writeAll("</div>\n");
    try writer.writeAll("</body>\n");
    try writer.writeAll("</html>\n");
}

fn usageAndExit(arg0: []const u8) noreturn {
    std.debug.warn("Usage: {s} <input_json_file>\n", .{arg0});
    std.process.exit(1);
}
