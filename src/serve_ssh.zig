const std = @import("std");
const push = @import("push.zig");
const xit = @import("xit");
const rp = xit.repo;
const xitui = xit.xitui;
const StreamTerminal = xitui.stream_terminal.StreamTerminal;
const Size = xitui.layout.Size;
const ui = @import("./ui.zig");
const ssh = @import("./serve_ssh_protocol.zig");
const evt = @import("./event.zig");
const serve_common = @import("./serve_common.zig");
const fork = @import("./fork.zig");
const progress = @import("./progress.zig");

// listener resource limits. the watchdog gives peers a hard deadline to start
// a session, times out non-interactive sessions that stall while we're blocked
// on the peer, and bounds the post-CLOSE drain.
const max_connections: u32 = 4096;
const watchdog_interval = std.Io.Duration.fromSeconds(5);
const presession_timeout_ticks: u32 = 6; // 30 seconds
const idle_timeout_ticks: u32 = 24; // 120 seconds
const close_drain_timeout_ticks: u32 = 2; // 5-10 seconds
const escape_timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(25), .clock = .awake } };

var active_connections: std.atomic.Value(u32) = .init(0);

const any_repo_opts: rp.AnyRepoOpts(.xit) = .{ .ProgressCtx = *progress.Sideband };

pub const SessionHandler = struct {
    admin_repo_path: []const u8,
    users_dir: []const u8,
    wui_port: u16, // port the web UI is served on, shown in the TUI footer's url
    git_http_port: ?u16,
    git_ssh_port: ?u16,
    git_ssh_prefix: []const u8,
    err: *std.Io.Writer,

    /// returning without an exit leaves the protocol layer to send status 0
    pub fn handleSession(self: *const SessionHandler, sess: *ssh.SessionCtx, request: ssh.Request) !void {
        serve_common.logError(sess.conn.io, self.err, "ssh session: kind={s} key={s}\n", .{ @tagName(request), sess.fingerprint });
        switch (request) {
            .shell => |shell| {
                const pty = shell.pty orelse {
                    // a shell without a pty has no useful TUI to render; in
                    // openssh client terms this is `ssh -T host`. say so and
                    // exit non-zero.
                    try sess.writeBytes("haxy ssh: this server only serves the TUI when a pty is allocated (use a normal `ssh` invocation).\r\n");
                    try sess.exit(1);
                    return;
                };
                sess.exemptFromIdleTimeout();
                try runTuiSession(self, sess, pty, shell.color);
            },
            .exec => |exec| {
                try runGitSession(self, sess, exec);
            },
        }
    }
};

pub fn runListener(
    io: std.Io,
    allocator: std.mem.Allocator,
    host_key: *const ssh.HostKey,
    session_handler: *const SessionHandler,
    watchdog: *Watchdog,
    net_server: *std.Io.net.Server,
    tasks: *std.Io.Group,
    err: *std.Io.Writer,
) void {
    const Context = struct {
        io: std.Io,
        allocator: std.mem.Allocator,
        host_key: *const ssh.HostKey,
        session_handler: *const SessionHandler,
        watchdog: *Watchdog,
        err: *std.Io.Writer,
    };

    const handle = struct {
        fn h(ctx: Context, stream: std.Io.net.Stream) void {
            defer stream.close(ctx.io);

            const prev_count = active_connections.fetchAdd(1, .acq_rel);
            defer _ = active_connections.fetchSub(1, .acq_rel);
            if (prev_count >= max_connections) {
                serve_common.logError(ctx.io, ctx.err, "ssh: connection limit reached, dropping\n", .{});
                return;
            }

            var connection = Watchdog.Connection{ .stream = &stream };
            ctx.watchdog.add(ctx.io, &connection);
            defer ctx.watchdog.remove(ctx.io, &connection);

            // timed peeks need room for a complete encrypted packet
            var recv_buf: [ssh.packet_buffer_size]u8 = undefined;
            var send_buf: [4096]u8 = undefined;
            var stream_reader = stream.reader(ctx.io, &recv_buf);
            var stream_writer = stream.writer(ctx.io, &send_buf);
            ssh.handleConnection(
                ctx.io,
                ctx.allocator,
                &stream_reader.interface,
                &stream_writer.interface,
                ctx.host_key,
                &connection.idle_state,
                ctx.session_handler,
            ) catch |session_err| {
                serve_common.logError(ctx.io, ctx.err, "ssh session failed: {s}\n", .{@errorName(session_err)});
            };
        }
    }.h;

    // without the watchdog nothing bounds a connection, so don't listen
    tasks.concurrent(io, Watchdog.run, .{ watchdog, io }) catch |spawn_err| {
        serve_common.logError(io, err, "ssh: watchdog spawn failed: {s}\n", .{@errorName(spawn_err)});
        return;
    };

    serve_common.runListener(io, net_server, tasks, err, "ssh", Context{
        .io = io,
        .allocator = allocator,
        .host_key = host_key,
        .session_handler = session_handler,
        .watchdog = watchdog,
        .err = err,
    }, handle);
}

/// one task watches every connection. a connection links its entry only
/// while it runs, so the watchdog never sees a closed stream.
pub const Watchdog = struct {
    mutex: std.Io.Mutex = .init,
    connections: std.DoublyLinkedList = .{},

    const Connection = struct {
        node: std.DoublyLinkedList.Node = .{},
        stream: *const std.Io.net.Stream,
        idle_state: ssh.IdleState = .{},
        // tick state, touched only by the watchdog
        last_seen: u64 = 0,
        presession_ticks: u32 = 0,
        idle_ticks: u32 = 0,
        closing_ticks: u32 = 0,

        // interactive sessions are exempt only from the idle timeout, so a
        // stalled teardown can still be broken
        fn timedOut(self: *Connection) bool {
            if (self.idle_state.closing.load(.acquire)) {
                self.closing_ticks += 1;
                return self.closing_ticks >= close_drain_timeout_ticks;
            }
            if (!self.idle_state.session_started.load(.acquire)) {
                self.presession_ticks += 1;
                return self.presession_ticks >= presession_timeout_ticks;
            }
            if (self.idle_state.exempt.load(.acquire)) return false;

            // our own work between packets is not the peer idling
            const seen = self.idle_state.activity.load(.acquire);
            defer self.last_seen = seen;
            if (self.idle_state.waiting.load(.acquire) and seen == self.last_seen) {
                self.idle_ticks += 1;
            } else {
                self.idle_ticks = 0;
            }
            return self.idle_ticks >= idle_timeout_ticks;
        }
    };

    fn add(self: *Watchdog, io: std.Io, connection: *Connection) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.connections.append(&connection.node);
    }

    fn remove(self: *Watchdog, io: std.Io, connection: *Connection) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.connections.remove(&connection.node);
    }

    fn run(self: *Watchdog, io: std.Io) void {
        while (true) {
            io.sleep(watchdog_interval, .awake) catch return;
            self.mutex.lock(io) catch return;
            defer self.mutex.unlock(io);
            var node = self.connections.first;
            while (node) |n| : (node = n.next) {
                const connection: *Connection = @fieldParentPtr("node", n);
                if (connection.timedOut()) connection.stream.shutdown(io, .both) catch {};
            }
        }
    }
};

fn runTuiSession(handler: *const SessionHandler, sess: *ssh.SessionCtx, pty: ssh.PtySize, color: bool) !void {
    // runTui owns the terminal, whose deinit restores the client's screen and
    // runs as the function unwinds — so any error it returns leaves the TUI torn
    // down and we can surface the failure on the restored screen before exiting.
    runTui(handler, sess, pty, color) catch |tui_err| {
        const err = sess.underlyingError(tui_err);
        serve_common.logError(sess.conn.io, handler.err, "ssh tui session failed: {s}\n", .{@errorName(err)});
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "haxy ssh: {s}\r\n", .{@errorName(err)}) catch "haxy ssh: internal error\r\n";
        sess.writeBytes(msg) catch {};
        try sess.exit(1);
    };
}

fn runTui(handler: *const SessionHandler, sess: *ssh.SessionCtx, pty: ssh.PtySize, color: bool) !void {
    const allocator = sess.conn.allocator;
    const io = sess.conn.io;

    // some clients (notably scripted ssh with no local controlling tty)
    // allocate a pty without ever sending a non-zero size. fall back to a
    // conventional 80x24 in that case so render emits something.
    var terminal_size = Size{
        .width = if (pty.width_cells == 0) 80 else pty.width_cells,
        .height = if (pty.height_cells == 0) 24 else pty.height_cells,
    };

    // session-lifetime allocations (login, prefs); Nav owns the per-page arenas.
    var session_arena = std.heap.ArenaAllocator.init(allocator);
    defer session_arena.deinit();

    const Repo = rp.Repo(.xit, evt.admin_repo_opts);
    var repo = try Repo.open(io, allocator, .{ .path = handler.admin_repo_path });
    defer repo.deinit(io, allocator);
    var ui_session = try ui.Session.init(&session_arena, &repo, .{});
    ui_session.is_terminal = true;
    ui_session.color = color;
    ui_session.web_port = handler.wui_port;
    ui_session.data.git_http_port = handler.git_http_port;
    ui_session.data.git_ssh_port = handler.git_ssh_port;
    ui_session.data.git_ssh_prefix = handler.git_ssh_prefix;
    // let page builders open on-disk repos
    ui_session.io = io;
    ui_session.users_dir = handler.users_dir;

    var nav = try ui.Nav.init(allocator, &ui_session);
    defer nav.deinit(allocator);

    var session_writer_buf: [8192]u8 = undefined;
    var session_writer = ssh.SessionWriter.init(sess, &session_writer_buf);

    // the terminal's deinit writes leave-alt / show-cursor / disable-mouse and
    // flushes, restoring the client's screen. as a function-scoped defer it runs
    // before runTui returns — on the normal path and on any error — so the
    // caller can write to the client afterward (and sess.exit can close cleanly).
    var terminal_maybe: ?StreamTerminal = try StreamTerminal.init(allocator, &session_writer.interface, terminal_size);
    defer if (terminal_maybe) |*terminal| terminal.deinit();

    // initial render — user sees the page immediately
    if (terminal_maybe) |*terminal| {
        terminal.render_state.no_color = !color;
        try terminal.queryBackground();
        _ = try terminal.render(&nav.root);
    }

    // event loop. nextEvent blocks until something interesting arrives;
    // for each event, rebuild the widget tree and re-render so the user
    // sees the effect of their input on the same iteration.
    event_loop: while (true) {
        const event = try nextTuiEvent(sess, if (terminal_maybe) |*terminal| terminal else null);
        if (event) |ev| switch (ev) {
            .data => |payload| {
                defer allocator.free(payload);
                if (terminal_maybe) |*terminal| {
                    try terminal.writeBytes(payload);
                } else {
                    // the copyable text stays up until enter
                    if (std.mem.indexOfAny(u8, payload, "\r\n") == null) continue;
                    var terminal = try StreamTerminal.init(allocator, &session_writer.interface, terminal_size);
                    terminal.render_state.no_color = !color;
                    terminal_maybe = terminal;
                }
            },
            .resize => |sz| {
                terminal_size = .{ .width = sz.width_cells, .height = sz.height_cells };
                if (terminal_maybe) |*terminal| terminal.pushResize(terminal_size) else continue;
            },
            .eof, .close => break :event_loop,
        };
        if (terminal_maybe) |*terminal| {
            while (terminal.popKey()) |key| {
                try ui.inputKey(allocator, &nav.root, key, &ui_session);
            }
        }

        if (ui_session.host_request) |request| {
            ui_session.host_request = null;
            switch (request) {
                .show_copyable_text => |copyable_text| {
                    if (terminal_maybe) |*terminal| terminal.deinit();
                    terminal_maybe = null;
                    try session_writer.interface.print("\x1b[2J\x1b[Hcopy the following text and then press enter to go back:\r\n\r\n{s}\r\n", .{copyable_text});
                    try session_writer.interface.flush();
                    continue;
                },
                .sync_events => {},
                .undo => |target| ui.Repo.Undo.handleRequest(allocator, &ui_session, target),
            }
        }

        // pick up data written by other handles so the next navigation
        // builds its page from a current moment
        try ui_session.reloadMoment(allocator, &repo);

        // reconcile navigation: forward to a new page, or back on escape.
        // the terminal background can change at any time, so recheck it on each page
        if (try nav.sync(allocator, &ui_session)) {
            if (terminal_maybe) |*terminal| try terminal.queryBackground();
        }

        // the quit button (on the quit tab) asks the host to tear down
        if (ui_session.quit_requested) break :event_loop;

        try nav.root.build(allocator, .{
            .min_size = .{ .width = null, .height = null },
            .max_size = .{ .width = terminal_size.width, .height = terminal_size.height },
        }, nav.root.getFocus());
        if (terminal_maybe) |*terminal| _ = try terminal.render(&nav.root);
    }
}

// only ambiguous input (a lone ESC or ESC ]) needs a deadline; longer
// fragments must remain buffered until complete. a timeout leaves partial SSH
// packets in the reader.
pub fn nextTuiEvent(sess: *ssh.SessionCtx, terminal: ?*StreamTerminal) !?ssh.Event {
    if (terminal) |t| {
        if (t.parser.isAmbiguous()) {
            sess.conn.read_timeout = escape_timeout.toDeadline(sess.conn.io);
            defer sess.conn.read_timeout = .none;
            return sess.nextEvent() catch |err| switch (err) {
                error.Timeout => {
                    try t.flushEscape();
                    return null;
                },
                else => return err,
            };
        }
    }
    return try sess.nextEvent();
}

// ---------------------------------------------------------------------------
// git path (exec)
// ---------------------------------------------------------------------------

const GitService = enum { upload_pack, receive_pack };

const ParsedGitCommand = struct {
    service: GitService,
    dir: []u8,

    fn deinit(self: ParsedGitCommand, allocator: std.mem.Allocator) void {
        allocator.free(self.dir);
    }
};

fn runGitSession(handler: *const SessionHandler, sess: *ssh.SessionCtx, exec: ssh.Request.Exec) !void {
    const allocator = sess.conn.allocator;
    const io = sess.conn.io;
    const protocol_version = xit.net_server_common.parseProtocolVersion(exec.git_protocol);

    // the repo's pack functions consume the channel like any other stream.
    // whatever they leave buffered is flushed before the exit status goes out.
    var reader_buf: [4096]u8 = undefined;
    var writer_buf: [4096]u8 = undefined;
    var reader = ssh.SessionReader.init(sess, &reader_buf);
    var writer = ssh.SessionWriter.init(sess, &writer_buf);
    defer writer.interface.flush() catch {};

    const parsed = parseGitCommand(allocator, exec.command) catch return writeError(sess, "unsupported command (expected git-upload-pack or git-receive-pack)");
    defer parsed.deinit(allocator);
    const repo_identity = std.mem.trimStart(u8, parsed.dir, "/");

    // a "+" names a fork's patch draft
    if (std.mem.indexOfScalar(u8, repo_identity, '+') != null) {
        return runForkSession(handler, sess, repo_identity, parsed.service, protocol_version, &reader.interface, &writer.interface);
    }

    const owner_repo = evt.parseOwnerRepoPath(repo_identity) orelse return writeError(sess, "repo path must be <owner>:<repo>");
    var author_arena = std.heap.ArenaAllocator.init(allocator);
    defer author_arena.deinit();
    const author = switch (try authorizeRepoKey(io, &author_arena, handler.admin_repo_path, handler.users_dir, owner_repo.owner, owner_repo.name, parsed.service, &sess.fingerprint)) {
        .allowed => |user| user,
        .create => |creator| return runCreatingPush(handler, sess, &creator, owner_repo.name, protocol_version, &reader.interface, &writer.interface),
        .denied => return switch (parsed.service) {
            .upload_pack => writeError(sess, "unauthorized: this SSH key cannot read this repo"),
            .receive_pack => writeError(sess, "unauthorized: this SSH key cannot push to this repo"),
        },
        .not_found => return writeError(sess, "repo not found"),
    };

    const repo_path = switch (try serve_common.resolveRepoPath(io, allocator, handler.users_dir, handler.admin_repo_path, repo_identity)) {
        .ok => |p| p,
        .invalid => unreachable, // parsed above
        .not_found => return writeError(sess, "repo not found"),
    };
    defer allocator.free(repo_path);

    var any_repo = try rp.AnyRepo(.xit, any_repo_opts).open(io, allocator, .{ .path = repo_path });
    defer any_repo.deinit(io, allocator);

    switch (any_repo) {
        inline else => |*repo| switch (parsed.service) {
            .upload_pack => {
                var sideband = progress.Sideband{ .writer = &writer.interface, .sess = sess };
                try repo.uploadPack(io, allocator, &reader.interface, &writer.interface, .{ .protocol_version = protocol_version }, &sideband);
            },
            .receive_pack => try push.receivePackAndConsume(repo.self_repo_opts, io, allocator, repo, &reader.interface, &writer.interface, .{ .protocol_version = protocol_version }, author, handler.users_dir, handler.err, sess),
        },
    }
}

// push to a repo that doesn't exist yet, creating it in the hash format the
// client's first command names
fn runCreatingPush(
    handler: *const SessionHandler,
    sess: *ssh.SessionCtx,
    creator: *const RepoCreator,
    name: []const u8,
    protocol_version: xit.net_server_common.ProtocolVersion,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
) !void {
    const allocator = sess.conn.allocator;
    const io = sess.conn.io;

    evt.Repo.validateName(name) catch return writeError(sess, "invalid repo name");

    try xit.net_server_receive_pack.advertiseUncreated(.xit, writer, .{ .protocol_version = protocol_version });
    try writer.flush();
    // a client with nothing to push creates nothing
    const hash_kind = (try xit.net_server_receive_pack.peekObjectFormat(reader)) orelse return;

    const location = evt.createRepo(io, allocator, handler.users_dir, &creator.owner_id, creator.owner, name, "", .private, hash_kind) catch |err| switch (err) {
        error.NameTaken => return writeError(sess, "repo was just created by another push, try again"),
        else => |e| return e,
    };
    const repo_path = try evt.repoPath(allocator, handler.users_dir, &location.owner_id, &location.repo_id);
    defer allocator.free(repo_path);

    switch (hash_kind) {
        inline else => |kind| {
            var repo = try rp.Repo(.xit, any_repo_opts.toRepoOptsWithHash(kind)).open(io, allocator, .{ .path = repo_path });
            defer repo.deinit(io, allocator);
            // stateless since the advertisement already went out
            try push.receivePackAndConsume(repo.self_repo_opts, io, allocator, &repo, reader, writer, .{ .protocol_version = protocol_version, .is_stateless = true }, creator.owner, handler.users_dir, handler.err, sess);
        },
    }
}

// serve a patch draft: anyone may fetch it, only its author may push to it
fn runForkSession(
    handler: *const SessionHandler,
    sess: *ssh.SessionCtx,
    fork_path: []const u8,
    service: GitService,
    protocol_version: xit.net_server_common.ProtocolVersion,
    reader: *std.Io.Reader,
    writer: *std.Io.Writer,
) !void {
    const allocator = sess.conn.allocator;
    const io = sess.conn.io;

    const route = fork.parseRoute(fork_path) orelse return writeError(sess, "invalid fork path");
    // the route names the forker and the target repo
    const forker_repo = evt.parseOwnerRepoPath(route.identity) orelse return writeError(sess, "repo path must be <forker>:<repo>");

    var admin = try rp.Repo(.xit, evt.admin_repo_opts).open(io, allocator, .{ .path = handler.admin_repo_path });
    defer admin.deinit(io, allocator);
    var admin_arena = std.heap.ArenaAllocator.init(allocator);
    defer admin_arena.deinit();
    const admin_moment = try evt.currentMoment(evt.admin_repo_opts, &admin);
    const fork_id = try evt.parseEventId(&route.id);
    const forker_id = (try evt.User.readIdByName(evt.AdminDB, evt.admin_repo_opts.hash, admin_moment, forker_repo.owner)) orelse
        return writeError(sess, "patch draft not found");
    const fork_record = (try evt.readForkById(io, allocator, &admin_arena, handler.users_dir, &forker_id, &fork_id)) orelse
        return writeError(sess, "patch draft not found");
    if (fork_record.removed) return writeError(sess, "patch draft not found");
    const user = (try evt.User.readById(evt.AdminDB, evt.admin_repo_opts.hash, admin_moment, &admin_arena, &forker_id)) orelse
        return writeError(sess, "invalid patch draft");
    if (user.removed) return writeError(sess, "invalid patch draft");
    if (service == .receive_pack and !isKeyInAuthorizedKeys(user.event.ssh_keys, &sess.fingerprint))
        return writeError(sess, "unauthorized: this SSH key is not registered to the patch author");

    const target = (try evt.readRepoById(io, allocator, &admin_arena, handler.users_dir, fork_record.event.repo_user_id[0..evt.event_id_size], fork_record.event.repo_id[0..evt.event_id_size], forker_id)) orelse
        return writeError(sess, "repo not found");
    // patches that are off take their drafts with them
    const patch_role = target.repo.event.patch_role orelse return writeError(sess, "patch draft not found");
    if (service == .receive_pack) {
        const role = target.role orelse return writeError(sess, "repo not found");
        if (!role.atLeast(patch_role)) return writeError(sess, "unauthorized: your role in this repo may not write patches");
    }

    const draft_path = try fork.forkPath(allocator, handler.users_dir, &forker_id, &fork_id);
    defer allocator.free(draft_path);
    var draft = rp.AnyRepo(.xit, any_repo_opts).open(io, allocator, .{ .path = draft_path }) catch
        return writeError(sess, "patch draft not found");
    defer draft.deinit(io, allocator);
    if (service == .upload_pack) {
        var sideband = progress.Sideband{ .writer = writer, .sess = sess };
        switch (draft) {
            inline else => |*repo| try repo.uploadPack(io, allocator, reader, writer, .{ .protocol_version = protocol_version }, &sideband),
        }
    } else {
        if (!std.mem.eql(u8, target.repo.event.name, forker_repo.name)) return writeError(sess, "patch draft belongs to another repo");
        const target_path = try evt.repoPath(allocator, handler.users_dir, fork_record.event.repo_user_id, fork_record.event.repo_id);
        defer allocator.free(target_path);
        const author: evt.CommitAuthor = .{ .name = user.event.name, .email = user.event.email };
        const timestamp: u64 = @intCast(std.Io.Timestamp.now(io, .real).toSeconds());
        switch (draft) {
            inline else => |*repo| {
                var target_repo = rp.Repo(.xit, repo.self_repo_opts).open(io, allocator, .{ .path = target_path }) catch
                    return writeError(sess, "repo not found or has the wrong hash");
                defer target_repo.deinit(io, allocator);
                try push.receiveFork(repo.self_repo_opts, io, allocator, repo, &target_repo, handler.users_dir, &route.id, author, timestamp, reader, writer, handler.err, sess);
            },
        }
    }
}

fn parseGitCommand(allocator: std.mem.Allocator, command: []const u8) !ParsedGitCommand {
    var tokens = try std.process.Args.IteratorGeneral(.{ .single_quotes = true }).init(allocator, command);
    defer tokens.deinit();

    const service_token = tokens.next() orelse return error.InvalidCommand;
    const dir_token = tokens.next() orelse return error.InvalidCommand;

    const service: GitService =
        if (std.mem.eql(u8, service_token, "git-upload-pack") or std.mem.eql(u8, service_token, "upload-pack"))
            .upload_pack
        else if (std.mem.eql(u8, service_token, "git-receive-pack") or std.mem.eql(u8, service_token, "receive-pack"))
            .receive_pack
        else
            return error.UnsupportedService;

    return .{ .service = service, .dir = try allocator.dupe(u8, dir_token) };
}

const RepoAuthorization = union(enum) { allowed: ?evt.CommitAuthor, create: RepoCreator, denied, not_found };

// the owner of a repo a push may create
const RepoCreator = struct {
    owner_id: [evt.event_id_size]u8,
    owner: evt.CommitAuthor,
};

fn authorizeRepoKey(
    io: std.Io,
    arena: *std.heap.ArenaAllocator,
    admin_repo_path: []const u8,
    users_dir: []const u8,
    owner_name: []const u8,
    repo_name: []const u8,
    service: GitService,
    fingerprint: *const [ssh.fingerprint_len]u8,
) !RepoAuthorization {
    const allocator = arena.child_allocator;
    var admin = rp.Repo(.xit, evt.admin_repo_opts).open(io, allocator, .{ .path = admin_repo_path }) catch |err| switch (err) {
        error.RepoNotFound => return .not_found,
        else => |e| return e,
    };
    defer admin.deinit(io, allocator);

    const moment = try evt.currentMoment(evt.admin_repo_opts, &admin);
    // no viewer yet, so this carries the base role
    const repo = (try evt.readRepoByOwnerAndName(io, allocator, arena, moment, users_dir, owner_name, repo_name, null)) orelse {
        if (service == .upload_pack) return .not_found;
        const owner_id = (try evt.User.readIdByName(evt.AdminDB, evt.admin_repo_opts.hash, moment, owner_name)) orelse return .not_found;
        const owner = (try evt.User.readById(evt.AdminDB, evt.admin_repo_opts.hash, moment, arena, &owner_id)) orelse unreachable;
        return if (isKeyInAuthorizedKeys(owner.event.ssh_keys, fingerprint))
            .{ .create = .{ .owner_id = owner_id, .owner = .{ .name = owner.event.name, .email = owner.event.email } } }
        else
            .denied;
    };

    const min_role: evt.Repo.Role = switch (service) {
        .upload_pack => .read,
        .receive_pack => .write,
    };
    // skip the key lookups when the base role is enough
    if (repo.role) |base| {
        if (base.atLeast(min_role)) return .{ .allowed = null };
    }

    // the creator owns the repo
    const owner_id = repo.repo.event.user_id[0..evt.event_id_size];
    if (try authorWithKey(moment, arena, owner_id, fingerprint)) |author| return .{ .allowed = author };

    // anyone else holding the key needs a grant with the role. a key can be
    // shared, so a grant that falls short doesn't end the search.
    for (try evt.readRepoGrants(io, allocator, arena, users_dir, owner_id, &repo.event_id)) |grant| {
        if (!grant.role.atLeast(min_role)) continue;
        if (try authorWithKey(moment, arena, grant.user_id, fingerprint)) |author| return .{ .allowed = author };
    }
    return .denied;
}

// the user as a commit author, or null unless they hold the key
fn authorWithKey(
    moment: evt.AdminDB.HashMap(.read_only),
    arena: *std.heap.ArenaAllocator,
    user_id: []const u8,
    fingerprint: *const [ssh.fingerprint_len]u8,
) !?evt.CommitAuthor {
    const user = (try evt.User.readById(evt.AdminDB, evt.admin_repo_opts.hash, moment, arena, user_id)) orelse return null;
    if (user.removed or !isKeyInAuthorizedKeys(user.event.ssh_keys, fingerprint)) return null;
    return .{ .name = user.event.name, .email = user.event.email };
}

fn isKeyInAuthorizedKeys(ssh_keys: []const u8, fingerprint: *const [ssh.fingerprint_len]u8) bool {
    var it = std.mem.splitScalar(u8, ssh_keys, '\n');
    while (it.next()) |line| {
        const fp = fingerprintOfAuthorizedKey(line) orelse continue;
        if (std.mem.eql(u8, &fp, fingerprint)) return true;
    }
    return false;
}

// the SHA256 fingerprint of one authorized_keys line, or null if the line is
// blank or not a parseable "<type> <base64> [comment]" entry
fn fingerprintOfAuthorizedKey(line: []const u8) ?[ssh.fingerprint_len]u8 {
    var it = std.mem.tokenizeAny(u8, line, " \t\r");
    _ = it.next() orelse return null; // key type
    const blob_b64 = it.next() orelse return null;

    const decoder = std.base64.standard.Decoder;
    const blob_len = decoder.calcSizeForSlice(blob_b64) catch return null;
    var blob_buf: [4096]u8 = undefined;
    if (blob_len > blob_buf.len) return null;
    decoder.decode(blob_buf[0..blob_len], blob_b64) catch return null;

    return ssh.formatFingerprint(blob_buf[0..blob_len]);
}

fn writeError(sess: *ssh.SessionCtx, comptime msg: []const u8) !void {
    const body = "ERR haxy ssh: " ++ msg;
    var packet: [body.len + 4]u8 = undefined;
    const line = try std.fmt.bufPrint(&packet, "{x:0>4}{s}", .{ packet.len, body });
    try sess.writeBytes(line);
    try sess.exit(1);
}

test "parseGitCommand rejects malformed input" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidCommand, parseGitCommand(allocator, "git-upload-pack"));
    try std.testing.expectError(error.UnsupportedService, parseGitCommand(allocator, "ls -la"));
    try std.testing.expectError(error.UnsupportedService, parseGitCommand(allocator, "git-fake-pack 'repo'"));
}

test "parseGitCommand happy paths" {
    const allocator = std.testing.allocator;

    {
        const parsed = try parseGitCommand(allocator, "git-upload-pack 'some-repo'");
        defer parsed.deinit(allocator);
        try std.testing.expectEqual(GitService.upload_pack, parsed.service);
        try std.testing.expectEqualStrings("some-repo", parsed.dir);
    }
    {
        const parsed = try parseGitCommand(allocator, "git-receive-pack 'user/proj'");
        defer parsed.deinit(allocator);
        try std.testing.expectEqual(GitService.receive_pack, parsed.service);
        try std.testing.expectEqualStrings("user/proj", parsed.dir);
    }
    {
        const parsed = try parseGitCommand(allocator, "git-upload-pack repo");
        defer parsed.deinit(allocator);
        try std.testing.expectEqual(GitService.upload_pack, parsed.service);
        try std.testing.expectEqualStrings("repo", parsed.dir);
    }
}
