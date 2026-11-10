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

fn sysPipe() ![2]i32 {
    var fds: [2]i32 = undefined;
    const rc = linux.syscall2(.pipe2, @intFromPtr(&fds), 0);
    if (isLinuxErr(rc)) return error.PipeFailed;
    return fds;
}

fn sysDup2(old_fd: i32, new_fd: i32) !void {
    if (old_fd == new_fd) return;
    const rc = linux.syscall3(.dup3, @intCast(old_fd), @intCast(new_fd), 0);
    if (isLinuxErr(rc)) return error.DupFailed;
}

fn sysFork() !i32 {
    if (@hasDecl(posix, "fork")) {
        const pid = try posix.fork();
        return @intCast(pid);
    } else {
        const rc = linux.fork();
        if (isLinuxErr(rc)) return error.ForkFailed;
        return @intCast(rc);
    }
}

fn sysWaitpid(pid: i32) void {
    if (@hasDecl(posix, "waitpid")) {
        _ = posix.waitpid(@intCast(pid), 0);
    } else {
        var status: u32 = 0;
        _ = linux.waitpid(@intCast(pid), &status, 0);
    }
}

fn sysExecveZ(
    path: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) void {
    if (@hasDecl(posix, "execveZ")) {
        _ = posix.execveZ(path, argv, envp) catch {};
    } else {
        _ = linux.execve(path, argv, envp);
    }
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

fn changeCurDir(allocator: std.mem.Allocator, path: []const u8) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const rc = linux.chdir(path_z.ptr);
    if (isLinuxErr(rc)) return error.ChdirFailed;
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

const CwdDir = struct {
    allocator: std.mem.Allocator,

    pub fn openFile(self: CwdDir, path: []const u8) !File {
        const path_z = try self.allocator.dupeZ(u8, path);
        defer self.allocator.free(path_z);
        const at_fdcwd: usize = @bitCast(@as(isize, -100));
        const o_rdonly: usize = 0;
        const rc = linux.syscall4(.openat, at_fdcwd, @intFromPtr(path_z.ptr), o_rdonly, 0);
        if (isLinuxErr(rc)) return error.FileNotFound;
        return File{ .fd = @intCast(rc) };
    }

    pub fn createFile(self: CwdDir, path: []const u8) !File {
        const path_z = try self.allocator.dupeZ(u8, path);
        defer self.allocator.free(path_z);
        const at_fdcwd: usize = @bitCast(@as(isize, -100));
        // O_WRONLY (0o1) | O_CREAT (0o100) | O_TRUNC (0o1000) = 0o1101
        const flags: usize = 0o1101;
        const mode: usize = 0o644;
        const rc = linux.syscall4(.openat, at_fdcwd, @intFromPtr(path_z.ptr), flags, mode);
        if (isLinuxErr(rc)) return error.CreateFailed;
        return File{ .fd = @intCast(rc) };
    }
};

fn cwd(allocator: std.mem.Allocator) CwdDir {
    return .{ .allocator = allocator };
}

fn execInChild(argv_slices: []const []const u8) noreturn {
    const envp = [_:null]?[*:0]const u8{
        "PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin",
        "TERM=xterm-256color",
    };

    var arg_storage: [64][512]u8 = undefined;
    var argv_buf: [64:null]?[*:0]const u8 = undefined;
    const count = @min(argv_slices.len, 63);

    for (argv_slices[0..count], 0..) |arg, idx| {
        const len = @min(arg.len, 511);
        @memcpy(arg_storage[idx][0..len], arg[0..len]);
        arg_storage[idx][len] = 0;
        const arg_z: [:0]const u8 = arg_storage[idx][0..len :0];
        argv_buf[idx] = arg_z.ptr;
    }
    argv_buf[count] = null;

    const bin = argv_slices[0];
    if (std.mem.indexOfScalar(u8, bin, '/') != null) {
        sysExecveZ(argv_buf[0].?, &argv_buf, &envp);
    } else {
        const search_dirs = [_][]const u8{
            "/bin",
            "/usr/bin",
            "/usr/local/bin",
            "/sbin",
            "/usr/sbin",
        };
        var path_buf: [512]u8 = undefined;
        for (search_dirs) |dir| {
            if (dir.len + 1 + bin.len >= path_buf.len) continue;
            @memcpy(path_buf[0..dir.len], dir);
            path_buf[dir.len] = '/';
            @memcpy(path_buf[dir.len + 1 .. dir.len + 1 + bin.len], bin);
            const total_len = dir.len + 1 + bin.len;
            path_buf[total_len] = 0;
            const full_z: [:0]const u8 = path_buf[0..total_len :0];
            sysExecveZ(full_z.ptr, &argv_buf, &envp);
        }
    }

    const err_writer = (File{ .fd = 2 }).writer();
    err_writer.print("zigsh: comando nao encontrado: {s}\n", .{bin}) catch {};
    std.process.exit(127);
}

const Child = struct {
    pub const StdIo = enum { Inherit, Pipe };

    argv: []const []const u8,
    allocator: std.mem.Allocator,
    stdin_behavior: StdIo = .Inherit,
    stdout_behavior: StdIo = .Inherit,
    stderr_behavior: StdIo = .Inherit,
    stdin: ?File = null,
    stdout: ?File = null,
    stderr: ?File = null,
    pid: i32 = -1,

    pub fn init(argv: []const []const u8, allocator: std.mem.Allocator) Child {
        return .{
            .argv = argv,
            .allocator = allocator,
        };
    }

    pub fn spawn(self: *Child) !void {
        var in_pipe: ?[2]i32 = null;
        errdefer if (in_pipe) |p| {
            sysClose(p[0]);
            sysClose(p[1]);
        };
        var out_pipe: ?[2]i32 = null;
        errdefer if (out_pipe) |p| {
            sysClose(p[0]);
            sysClose(p[1]);
        };
        var err_pipe: ?[2]i32 = null;
        errdefer if (err_pipe) |p| {
            sysClose(p[0]);
            sysClose(p[1]);
        };

        if (self.stdin_behavior == .Pipe) in_pipe = try sysPipe();
        if (self.stdout_behavior == .Pipe) out_pipe = try sysPipe();
        if (self.stderr_behavior == .Pipe) err_pipe = try sysPipe();

        // Pilar 1: Clonagem (fork)
        const pid = try sysFork();
        if (pid == 0) {
            if (in_pipe) |p| {
                sysClose(p[1]);
                sysDup2(p[0], 0) catch std.process.exit(1);
                sysClose(p[0]);
            }
            if (out_pipe) |p| {
                sysClose(p[0]);
                sysDup2(p[1], 1) catch std.process.exit(1);
                sysClose(p[1]);
            }
            if (err_pipe) |p| {
                sysClose(p[0]);
                sysDup2(p[1], 2) catch std.process.exit(1);
                sysClose(p[1]);
            }
            // Pilar 2 e 4: Mutação (execve) e Encerramento (exit)
            execInChild(self.argv);
        }

        self.pid = pid;
        if (in_pipe) |p| {
            sysClose(p[0]);
            self.stdin = File{ .fd = p[1] };
        }
        if (out_pipe) |p| {
            sysClose(p[1]);
            self.stdout = File{ .fd = p[0] };
        }
        if (err_pipe) |p| {
            sysClose(p[1]);
            self.stderr = File{ .fd = p[0] };
        }
    }

    pub fn wait(self: *Child) !u32 {
        if (self.stdin) |f| {
            f.close();
            self.stdin = null;
        }
        if (self.stdout) |f| {
            f.close();
            self.stdout = null;
        }
        if (self.stderr) |f| {
            f.close();
            self.stderr = null;
        }
        if (self.pid > 0) {
            // Pilar 3: Sincronização (waitpid)
            sysWaitpid(self.pid);
            self.pid = -1;
        }
        return 0;
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

fn pumpStream(reader: File.Reader, writer: File.Writer) !void {
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try reader.read(&buf);
        if (n == 0) break;
        try writer.writeAll(buf[0..n]);
    }
}

// Utilização da assinatura idiomática Juicy Main em Zig 0.16.0
pub fn main(init: std.process.Init) !void {
    // Em Zig 0.16.0, o GeneralPurposeAllocator já é entregue pronto em init.gpa
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

        // TODO 3: Fazer a tokenização da linha e identificar:
        // - Pipeline (|) separando sub-comandos
        // - Redirecionamentos (>, 2>, <)
        // - Operador de Background (& ao final do comando)
        if (std.mem.indexOfScalar(u8, trimmed_line, '|')) |pipe_idx| {
            // TODO 7: Implementar o encadeamento I/O entre processos conectados por Pipeline (|)
            // Conectar o stdout.Pipe do processo 1 ao stdin.Pipe do processo 2
            const left_part = std.mem.trim(u8, trimmed_line[0..pipe_idx], " \t");
            const right_part = std.mem.trim(u8, trimmed_line[pipe_idx + 1 ..], " \t");

            var cmd1 = try parseSingleCommand(temp_alloc, allocator, left_part);
            defer cmd1.deinit();
            var cmd2 = try parseSingleCommand(temp_alloc, allocator, right_part);
            defer cmd2.deinit();

            if (cmd1.args.items.len == 0 or cmd2.args.items.len == 0) continue;

            var child1 = Child.init(cmd1.args.items, allocator);
            child1.stdout_behavior = .Pipe;

            var child2 = Child.init(cmd2.args.items, allocator);
            child2.stdin_behavior = .Pipe;

            try child1.spawn();
            try child2.spawn();

            if (child1.stdout) |c1_out| {
                if (child2.stdin) |c2_in| {
                    try pumpStream(c1_out.reader(), c2_in.writer());
                    c2_in.close();
                    child2.stdin = null;
                }
                c1_out.close();
                child1.stdout = null;
            }

            _ = try child1.wait();
            _ = try child2.wait();
            continue;
        }

        var cmd = try parseSingleCommand(temp_alloc, allocator, trimmed_line);
        defer cmd.deinit();

        if (cmd.args.items.len == 0) continue;
        const cmd_name = cmd.args.items[0];

        // TODO 4: Verificar e executar Comandos Internos (cd, pwd, help, exit)
        if (std.mem.eql(u8, cmd_name, "cd")) {
            const target_dir = if (cmd.args.items.len > 1) cmd.args.items[1] else "/";
            changeCurDir(temp_alloc, target_dir) catch |err| {
                try stdout.print("cd: erro ao acessar '{s}': {}\n", .{ target_dir, err });
            };
            continue;
        } else if (std.mem.eql(u8, cmd_name, "pwd")) {
            const dir_str = try getCwd(&cwd_buf);
            try stdout.print("{s}\n", .{dir_str});
            continue;
        } else if (std.mem.eql(u8, cmd_name, "help")) {
            try stdout.writeAll(
                "zigsh - Comandos internos suportados:\n" ++
                    "  cd [dir]     : Altera o diretorio de trabalho atual\n" ++
                    "  pwd          : Exibe o diretorio de trabalho atual\n" ++
                    "  help         : Exibe esta mensagem de ajuda\n" ++
                    "  exit [cod]   : Encerra o shell com o codigo informado\n" ++
                    "Operadores: > (stdout), 2> (stderr), < (stdin), & (background), | (pipe)\n",
            );
            continue;
        } else if (std.mem.eql(u8, cmd_name, "exit")) {
            const code: u8 = if (cmd.args.items.len > 1)
                std.fmt.parseInt(u8, cmd.args.items[1], 10) catch 0
            else
                0;
            std.process.exit(code);
        }

        // TODO 5: Configurar e disparar a execução de Comandos Externos via Child
        var child = Child.init(cmd.args.items, allocator);

        if (cmd.stdin_file != null) child.stdin_behavior = .Pipe;
        if (cmd.stdout_file != null) child.stdout_behavior = .Pipe;
        if (cmd.stderr_file != null) child.stderr_behavior = .Pipe;

        child.spawn() catch |err| {
            try stdout.print("Erro ao executar '{s}': {}\n", .{ cmd_name, err });
            continue;
        };

        // TODO 6: Implementar a lógica de leitura/escrita para os arquivos de redirecionamento
        if (cmd.stdin_file) |in_path| {
            const in_file = try cwd(temp_alloc).openFile(in_path);
            defer in_file.close();
            if (child.stdin) |c_in| {
                try pumpStream(in_file.reader(), c_in.writer());
                c_in.close();
                child.stdin = null;
            }
        }

        if (cmd.stdout_file) |out_path| {
            const out_file = try cwd(temp_alloc).createFile(out_path);
            defer out_file.close();
            if (child.stdout) |c_out| {
                try pumpStream(c_out.reader(), out_file.writer());
                c_out.close();
                child.stdout = null;
            }
        }

        if (cmd.stderr_file) |err_path| {
            const err_file = try cwd(temp_alloc).createFile(err_path);
            defer err_file.close();
            if (child.stderr) |c_err| {
                try pumpStream(c_err.reader(), err_file.writer());
                c_err.close();
                child.stderr = null;
            }
        }

        // TODO 8: Controle de Concorrência:
        // - Se cmd.is_background == true: exibir mensagem de background e NÃO aguardar
        // - Se cmd.is_background == false: aguardar a finalização dos processos filhos via child.wait()
        if (cmd.is_background) {
            try stdout.writeAll("[Processo disparado em segundo plano]\n");
        } else {
            _ = try child.wait();
        }
    }
}
