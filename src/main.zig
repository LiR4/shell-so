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

// Utilização da assinatura idiomática Juicy Main em Zig 0.16.0
pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    _ = allocator;

    const stdin = (File{ .fd = 0 }).reader();
    const stdout = (File{ .fd = 1 }).writer();

    var cwd_buf: [4096]u8 = undefined;
    var line_buf: [4096]u8 = undefined;

    while (true) {
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
    }
}
