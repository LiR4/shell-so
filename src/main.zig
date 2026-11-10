const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

// ============================================================================
// Camada de Compatibilidade POSIX / I/O para Zig 0.16.0
// ============================================================================

fn isLinuxErr(rc: usize) bool {
    return rc > @as(usize, @bitCast(@as(isize, -4096)));
}

fn sysRead(fd: i32, buf: []u8) !usize {
    const rc = linux.read(fd, buf.ptr, buf.len);
    if (isLinuxErr(rc)) return error.ReadFailed;
    return rc;
}

fn sysWrite(fd: i32, data: []const u8) !void {
    var written: usize = 0;
    while (written < data.len) {
        const rc = linux.write(fd, data[written..].ptr, data.len - written);
        if (isLinuxErr(rc)) return error.WriteFailed;
        if (rc == 0) break;
        written += rc;
    }
}

fn sysClose(fd: i32) void {
    _ = linux.close(fd);
}

fn getCwd(buf: []u8) ![]const u8 {
    const rc = linux.getcwd(buf.ptr, buf.len);
    if (isLinuxErr(rc) or rc == 0) return error.GetCwdFailed;
    const slice = buf[0..rc];
    if (std.mem.indexOfScalar(u8, slice, 0)) |nul_idx| {
        return slice[0..nul_idx];
    }
    return slice;
}

const File = struct {
    fd: i32,

    pub const Reader = struct {
        fd: i32,
        pub fn read(self: Reader, buf: []u8) !usize {
            return sysRead(self.fd, buf);
        }
        pub fn readUntilDelimiterOrEof(self: Reader, buf: []u8, delimiter: u8) !?[]u8 {
            var idx: usize = 0;
            while (idx < buf.len) {
                var byte: [1]u8 = undefined;
                const n = try sysRead(self.fd, &byte);
                if (n == 0) {
                    if (idx == 0) return null;
                    break;
                }
                if (byte[0] == delimiter) break;
                buf[idx] = byte[0];
                idx += 1;
            }
            return buf[0..idx];
        }
    };

    pub const Writer = struct {
        fd: i32,
        pub fn writeAll(self: Writer, data: []const u8) !void {
            try sysWrite(self.fd, data);
        }
        pub fn print(self: Writer, comptime fmt: []const u8, args: anytype) !void {
            var buf: [4096]u8 = undefined;
            const slice = try std.fmt.bufPrint(&buf, fmt, args);
            try sysWrite(self.fd, slice);
        }
    };

    pub fn reader(self: File) Reader {
        return .{ .fd = self.fd };
    }

    pub fn writer(self: File) Writer {
        return .{ .fd = self.fd };
    }

    pub fn close(self: File) void {
        sysClose(self.fd);
    }
};

const ArgList = struct {
    allocator: std.mem.Allocator,
    buf: [][]const u8 = &.{},
    items: [][]const u8 = &.{},

    pub fn init(allocator: std.mem.Allocator) ArgList {
        return .{ .allocator = allocator };
    }

    pub fn append(self: *ArgList, item: []const u8) !void {
        if (self.items.len == self.buf.len) {
            const new_cap = if (self.buf.len == 0) 8 else self.buf.len * 2;
            const new_buf = try self.allocator.alloc([]const u8, new_cap);
            if (self.items.len > 0) {
                @memcpy(new_buf[0..self.items.len], self.items);
            }
            if (self.buf.len > 0) {
                self.allocator.free(self.buf);
            }
            self.buf = new_buf;
        }
        self.buf[self.items.len] = item;
        self.items = self.buf[0 .. self.items.len + 1];
    }

    pub fn deinit(self: *ArgList) void {
        if (self.buf.len > 0) {
            self.allocator.free(self.buf);
        }
    }
};

// ============================================================================
// Estrutura Principal do Trabalho Prático (zigsh)
// ============================================================================

const ParsedCommand = struct {
    args: ArgList,
    stdin_file: ?[]const u8 = null,
    stdout_file: ?[]const u8 = null,
    stderr_file: ?[]const u8 = null,
    is_background: bool = false,

    pub fn init(allocator: std.mem.Allocator) ParsedCommand {
        return .{
            .args = ArgList.init(allocator),
        };
    }

    pub fn deinit(self: *ParsedCommand) void {
        self.args.deinit();
    }
};

fn parseSingleCommand(
    temp_alloc: std.mem.Allocator,
    gpa_alloc: std.mem.Allocator,
    segment: []const u8,
) !ParsedCommand {
    var cmd = ParsedCommand.init(gpa_alloc);
    errdefer cmd.deinit();

    var raw_tokens = ArgList.init(temp_alloc);
    var i: usize = 0;

    while (i < segment.len) {
        while (i < segment.len and (segment[i] == ' ' or segment[i] == '\t' or segment[i] == '\r')) : (i += 1) {}
        if (i >= segment.len) break;

        if (segment[i] == '"') {
            i += 1;
            var buf = try temp_alloc.alloc(u8, segment.len);
            var out_len: usize = 0;
            while (i < segment.len and segment[i] != '"') {
                if (segment[i] == '\\' and i + 1 < segment.len and segment[i + 1] == 'n') {
                    buf[out_len] = '\n';
                    out_len += 1;
                    i += 2;
                } else {
                    buf[out_len] = segment[i];
                    out_len += 1;
                    i += 1;
                }
            }
            if (i < segment.len and segment[i] == '"') i += 1;
            try raw_tokens.append(buf[0..out_len]);
        } else {
            const start = i;
            while (i < segment.len and segment[i] != ' ' and segment[i] != '\t' and segment[i] != '\r') : (i += 1) {}
            try raw_tokens.append(segment[start..i]);
        }
    }

    var idx: usize = 0;
    const tokens = raw_tokens.items;
    while (idx < tokens.len) {
        const tok = tokens[idx];
        if (std.mem.eql(u8, tok, ">")) {
            if (idx + 1 < tokens.len) {
                cmd.stdout_file = tokens[idx + 1];
                idx += 2;
                continue;
            }
        } else if (std.mem.eql(u8, tok, "2>")) {
            if (idx + 1 < tokens.len) {
                cmd.stderr_file = tokens[idx + 1];
                idx += 2;
                continue;
            }
        } else if (std.mem.eql(u8, tok, "<")) {
            if (idx + 1 < tokens.len) {
                cmd.stdin_file = tokens[idx + 1];
                idx += 2;
                continue;
            }
        } else if (std.mem.eql(u8, tok, "&") and idx == tokens.len - 1) {
            cmd.is_background = true;
            idx += 1;
            continue;
        }
        try cmd.args.append(tok);
        idx += 1;
    }

    return cmd;
}

// Utilização da assinatura idiomática Juicy Main em Zig 0.16.0
pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    const stdin = (File{ .fd = 0 }).reader();
    const stdout = (File{ .fd = 1 }).writer();

    var cwd_buf: [4096]u8 = undefined;
    var line_buf: [4096]u8 = undefined;

    while (true) {
        var line_arena = std.heap.ArenaAllocator.init(allocator);
        defer line_arena.deinit();
        const temp_alloc = line_arena.allocator();

        // TODO 1: Exibir Prompt Dinâmico exibindo o diretório de trabalho atual (getCwd)
        const current_cwd = try getCwd(&cwd_buf);
        try stdout.print("zigsh [{s}]> ", .{current_cwd});

        // TODO 2: Ler a linha digitada pelo usuário no stdin
        // Tratamento de EOF (Ctrl+D) para encerramento gracioso
        const maybe_line = try stdin.readUntilDelimiterOrEof(&line_buf, '\n');
        const raw_line = maybe_line orelse {
            try stdout.writeAll("\n");
            break;
        };
        const trimmed_line = std.mem.trim(u8, raw_line, " \t\r\n");
        if (trimmed_line.len == 0) continue;

        // TODO 3: Fazer a tokenização da linha e identificar redirecionamentos e background
        var cmd = try parseSingleCommand(temp_alloc, allocator, trimmed_line);
        defer cmd.deinit();

        if (cmd.args.items.len == 0) continue;
    }
}
