//! start a server with some fake data and then launch
//! the TUI. this provides a nice way to test things
//! out safely.

const std = @import("std");
const builtin = @import("builtin");
const hx = @import("haxy");
const srv = hx.serve;
const evt = hx.event;
const xit = hx.xit;
const rp = xit.repo;
const ui = hx.ui;

pub fn main(init: std.process.Init) !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var threaded = std.Io.Threaded.init(allocator, .{
        .environ = init.minimal.environ,
    });
    defer threaded.deinit();
    const io = threaded.io();

    const temp_dir_name = "temp-try";

    // create the temp dir
    const cwd = std.Io.Dir.cwd();
    var temp_dir_or_err = cwd.openDir(io, temp_dir_name, .{});
    if (temp_dir_or_err) |*temp_dir| {
        temp_dir.close(io);
        try cwd.deleteTree(io, temp_dir_name);
    } else |_| {}
    var temp_dir = try cwd.createDirPathOpen(io, temp_dir_name, .{});
    defer cwd.deleteTree(io, temp_dir_name) catch {};
    defer temp_dir.close(io);

    const cwd_path = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd_path);

    var page_arena = std.heap.ArenaAllocator.init(allocator);
    defer page_arena.deinit();

    // create the admin repo and build the Page from it
    const page: ui.Page = blk: {
        const work_path = try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name, "server", "admin" });
        defer allocator.free(work_path);

        const repo_opts: rp.RepoOpts(.xit) = .{ .is_test = true };
        const Repo = rp.Repo(.xit, repo_opts);
        var repo = try Repo.init(io, allocator, .{ .path = work_path });
        defer repo.deinit(io, allocator);

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();

        // define test events

        var prng = std.Random.DefaultPrng.init(std.testing.random_seed);

        const user_data = [_]struct {
            name: []const u8,
            display_name: []const u8,
            email: []const u8,
        }{
            .{ .name = "alice", .display_name = "Alice Tulley", .email = "alice@example.test" },
            .{ .name = "bob", .display_name = "Bob Smith", .email = "bob@example.test" },
            .{ .name = "carol", .display_name = "Carol Johnson", .email = "carol@example.test" },
            .{ .name = "dave", .display_name = "Dave Wilson", .email = "dave@example.test" },
            .{ .name = "eve", .display_name = "Eve Anderson", .email = "eve@example.test" },
            .{ .name = "frank", .display_name = "Frank Miller", .email = "frank@example.test" },
            .{ .name = "grace", .display_name = "Grace Lee", .email = "grace@example.test" },
            .{ .name = "henry", .display_name = "Henry Davis", .email = "henry@example.test" },
            .{ .name = "ivy", .display_name = "Ivy Martinez", .email = "ivy@example.test" },
            .{ .name = "jack", .display_name = "Jack Thompson", .email = "jack@example.test" },
            .{ .name = "kate", .display_name = "Kate Robinson", .email = "kate@example.test" },
            .{ .name = "liam", .display_name = "Liam Walker", .email = "liam@example.test" },
            .{ .name = "mona", .display_name = "Mona Patel", .email = "mona@example.test" },
            .{ .name = "noah", .display_name = "Noah Garcia", .email = "noah@example.test" },
            .{ .name = "olivia", .display_name = "Olivia Hernandez", .email = "olivia@example.test" },
            .{ .name = "peter", .display_name = "Peter Wright", .email = "peter@example.test" },
            .{ .name = "quinn", .display_name = "Quinn Foster", .email = "quinn@example.test" },
            .{ .name = "rachel", .display_name = "Rachel Bennett", .email = "rachel@example.test" },
            .{ .name = "sam", .display_name = "Sam Brooks", .email = "sam@example.test" },
            .{ .name = "tina", .display_name = "Tina Cooper", .email = "tina@example.test" },
        };

        const repo_data = [_]struct {
            user_index: usize,
            name: []const u8,
            description: []const u8,
        }{
            .{ .user_index = 0, .name = "ziglings", .description = "Learn the Zig programming language by fixing tiny broken programs" },
            .{ .user_index = 1, .name = "linux", .description = "Linux kernel source tree" },
            .{ .user_index = 2, .name = "kubernetes", .description = "Production-grade container orchestration" },
            .{ .user_index = 3, .name = "react", .description = "A declarative, efficient, and flexible JavaScript library for building user interfaces" },
            .{ .user_index = 4, .name = "typescript", .description = "TypeScript is a superset of JavaScript that compiles to clean JavaScript output" },
            .{ .user_index = 5, .name = "rust", .description = "Empowering everyone to build reliable and efficient software" },
            .{ .user_index = 6, .name = "go", .description = "The Go programming language" },
            .{ .user_index = 7, .name = "nodejs", .description = "Node.js JavaScript runtime" },
            .{ .user_index = 8, .name = "cpython", .description = "The Python programming language" },
            .{ .user_index = 9, .name = "docker", .description = "Container platform for developing, shipping, and running applications" },
            .{ .user_index = 0, .name = "vim", .description = "The ubiquitous text editor" },
            .{ .user_index = 1, .name = "neovim", .description = "Hyperextensible Vim-based text editor" },
            .{ .user_index = 2, .name = "emacs", .description = "GNU Emacs source code mirror" },
            .{ .user_index = 3, .name = "tmux", .description = "Terminal multiplexer" },
            .{ .user_index = 4, .name = "zsh", .description = "Mirror of the Z shell source code repository" },
            .{ .user_index = 5, .name = "git", .description = "Distributed version control system" },
            .{ .user_index = 6, .name = "mercurial", .description = "Source-control management tool" },
            .{ .user_index = 7, .name = "tensorflow", .description = "An end-to-end open source machine learning platform" },
            .{ .user_index = 8, .name = "pytorch", .description = "Tensors and dynamic neural networks in Python with strong GPU acceleration" },
            .{ .user_index = 9, .name = "numpy", .description = "The fundamental package for scientific computing with Python" },
            .{ .user_index = 0, .name = "pandas", .description = "Flexible and powerful data analysis and manipulation library for Python" },
            .{ .user_index = 1, .name = "scikit-learn", .description = "Machine learning in Python" },
            .{ .user_index = 2, .name = "nginx", .description = "High performance HTTP server and reverse proxy" },
            .{ .user_index = 3, .name = "redis", .description = "In-memory data structure store, used as a database, cache, and message broker" },
            .{ .user_index = 4, .name = "postgres", .description = "The world's most advanced open source relational database" },
            .{ .user_index = 5, .name = "sqlite", .description = "Self-contained, serverless, zero-configuration SQL database engine" },
            .{ .user_index = 6, .name = "mongodb", .description = "The MongoDB Database" },
            .{ .user_index = 7, .name = "elasticsearch", .description = "Free and open, distributed, RESTful search engine" },
            .{ .user_index = 8, .name = "kafka", .description = "Distributed event streaming platform" },
            .{ .user_index = 9, .name = "terraform", .description = "Infrastructure as code tool" },
            .{ .user_index = 10, .name = "svelte", .description = "Cybernetically enhanced web apps" },
            .{ .user_index = 11, .name = "vue", .description = "The progressive JavaScript framework" },
            .{ .user_index = 12, .name = "flask", .description = "The Python micro framework for building web applications" },
            .{ .user_index = 13, .name = "django", .description = "The web framework for perfectionists with deadlines" },
            .{ .user_index = 14, .name = "rails", .description = "Ruby on Rails web framework" },
            .{ .user_index = 15, .name = "phoenix", .description = "Peace of mind from prototype to production for Elixir web apps" },
            .{ .user_index = 16, .name = "laravel", .description = "The PHP framework for web artisans" },
            .{ .user_index = 17, .name = "prometheus", .description = "The Prometheus monitoring system and time series database" },
            .{ .user_index = 18, .name = "grafana", .description = "The open and composable observability and data visualization platform" },
            .{ .user_index = 19, .name = "ansible", .description = "Simple, agentless IT automation" },
        };

        var user_ids: [user_data.len][evt.event_id_size]u8 = undefined;
        for (&user_ids) |*id| id.* = evt.EventWithId.randomId(prng.random());

        var repo_event_ids: [repo_data.len][evt.event_id_size]u8 = undefined;
        for (&repo_event_ids) |*id| id.* = evt.EventWithId.randomId(prng.random());

        var password_hash_buf: [evt.User.password_hash_max_len]u8 = undefined;
        const password_hash = try evt.User.hashPassword("correct horse battery staple", &password_hash_buf, io);

        var events_to_consume: [user_data.len + repo_data.len]evt.EventWithId = undefined;
        for (user_data, 0..) |u, i| {
            events_to_consume[i] = .{
                .id = std.fmt.bytesToHex(user_ids[i], .lower),
                .event = .{
                    .user = .{
                        .name = u.name,
                        .display_name = u.display_name,
                        .email = u.email,
                        .password_hash = password_hash,
                    },
                },
            };
        }
        for (repo_data, 0..) |r, i| {
            events_to_consume[user_data.len + i] = .{
                .id = std.fmt.bytesToHex(repo_event_ids[i], .lower),
                .event = .{
                    .repo = .{
                        .user_id = &user_ids[r.user_index],
                        .name = r.name,
                        .description = r.description,
                        .enable_issue = true,
                    },
                },
            };
        }

        // insert users and repos as commits in the repo
        {
            var json: std.Io.Writer.Allocating = .init(allocator);
            defer json.deinit();

            for (events_to_consume) |event| {
                json.clearRetainingCapacity();

                try std.json.Stringify.value(event, .{}, &json.writer);

                // commit the event into a special branch
                _ = try repo.commitAtRef(io, allocator, .{ .message = json.written() }, null, .{ .kind = .head, .name = "haxy/meta" });
            }
        }

        // consume events into the database
        try evt.consume(repo_opts, io, allocator, &repo, .{ .kind = .head, .name = "haxy/meta" });

        break :blk .{ .users_and_repos = try .init(repo_opts, &page_arena, &repo) };
    };

    // start the server

    var launch_sshd = false;

    var arg_it = try init.minimal.args.iterateAllocator(allocator);
    defer arg_it.deinit();
    _ = arg_it.skip();
    while (arg_it.next()) |arg| {
        if (std.mem.eql(u8, "--sshd", arg)) {
            launch_sshd = true;
        }
    }

    const server_path = try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name, "server" });
    defer allocator.free(server_path);

    if (launch_sshd) {
        var stdout_writer = std.Io.File.stdout().writer(io, &.{});
        var stderr_writer = std.Io.File.stderr().writer(io, &.{});
        const run_opts = hx.main.RunOpts{ .out = &stdout_writer.interface, .err = &stderr_writer.interface, .environ_map = init.environ_map };

        const port = 2222;

        // create priv host key
        const host_key_file = try std.Io.Dir.cwd().createFile(io, temp_dir_name ++ "/host_key", .{});
        defer host_key_file.close(io);
        try host_key_file.writeStreamingAll(io,
            \\-----BEGIN OPENSSH PRIVATE KEY-----
            \\b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAaAAAABNlY2RzYS
            \\1zaGEyLW5pc3RwMjU2AAAACG5pc3RwMjU2AAAAQQS1ppUfk8n7yvVKEgz3tXjt4q76VGuj
            \\LcQlRwmogzovV40LLcX0aTObZlQaLWfzJMNpCa/ztMpQlr86nsarE4lEAAAAqLe43zK3uN
            \\8yAAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBLWmlR+TyfvK9UoS
            \\DPe1eO3irvpUa6MtxCVHCaiDOi9XjQstxfRpM5tmVBotZ/Mkw2kJr/O0ylCWvzqexqsTiU
            \\QAAAAgQ+LCk30ZNJxb2Da5JL+QOFWCMf7bgXCWcEzhEGGvFWYAAAALcmFkYXJAcm9hcmsB
            \\AgMEBQ==
            \\-----END OPENSSH PRIVATE KEY-----
            \\
        );
        if (.windows != builtin.os.tag) {
            try host_key_file.setPermissions(io, @enumFromInt(0o600));
        }

        // create priv client key
        const priv_key_file = try std.Io.Dir.cwd().createFile(io, temp_dir_name ++ "/key", .{});
        defer priv_key_file.close(io);
        try priv_key_file.writeStreamingAll(io,
            \\-----BEGIN OPENSSH PRIVATE KEY-----
            \\b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
            \\QyNTUxOQAAACCniLPJiaooAWecvOCeAjoJwCSeWxzysvpTNkpYjF22JgAAAJA+7hikPu4Y
            \\pAAAAAtzc2gtZWQyNTUxOQAAACCniLPJiaooAWecvOCeAjoJwCSeWxzysvpTNkpYjF22Jg
            \\AAAEDVlopOMnKt/7by/IA8VZvQXUS/O6VLkixOqnnahUdPCKeIs8mJqigBZ5y84J4COgnA
            \\JJ5bHPKy+lM2SliMXbYmAAAAC3JhZGFyQHJvYXJrAQI=
            \\-----END OPENSSH PRIVATE KEY-----
            \\
        );
        if (.windows != builtin.os.tag) {
            try priv_key_file.setPermissions(io, @enumFromInt(0o600));
        }

        // create pub key
        const pub_key_file = try std.Io.Dir.cwd().createFile(io, temp_dir_name ++ "/key.pub", .{});
        defer pub_key_file.close(io);
        try pub_key_file.writeStreamingAll(io,
            \\ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKeIs8mJqigBZ5y84J4COgnAJJ5bHPKy+lM2SliMXbYm radar@roark
            \\
        );
        if (.windows != builtin.os.tag) {
            try pub_key_file.setPermissions(io, @enumFromInt(0o600));
        }

        const haxy_bin_path = try std.fs.path.join(allocator, &.{ cwd_path, "zig-out", "bin", "haxy" });
        defer allocator.free(haxy_bin_path);

        // dispatch.sh — sshd's forced command. picks between ssh-tui (for
        // interactive sessions) and ssh-git (for `git clone`/`git push`) by
        // checking whether sshd populated $SSH_ORIGINAL_COMMAND
        const dispatch_contents = try std.fmt.allocPrint(
            allocator,
            "#!/bin/sh\n" ++
                "if [ -z \"$SSH_ORIGINAL_COMMAND\" ]; then\n" ++
                "    exec {s} ssh-tui --tui-connect 127.0.0.1:8082 --user-key test-user\n" ++
                "else\n" ++
                "    exec {s} ssh-git\n" ++
                "fi\n",
            .{ haxy_bin_path, haxy_bin_path },
        );
        defer allocator.free(dispatch_contents);

        // scope the file handle so the close happens before sshd ever spawns
        // a shell that tries to exec it — otherwise Linux raises ETXTBSY.
        {
            const dispatch_file = try std.Io.Dir.cwd().createFile(io, temp_dir_name ++ "/dispatch.sh", .{});
            defer dispatch_file.close(io);
            try dispatch_file.writeStreamingAll(io, dispatch_contents);
            if (.windows != builtin.os.tag) {
                try dispatch_file.setPermissions(io, @enumFromInt(0o755));
            }
        }

        // create authorized_keys file. forced command runs dispatch.sh so a
        // single key can drive both the TUI and git operations.
        const dispatch_path = try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name, "dispatch.sh" });
        defer allocator.free(dispatch_path);

        const auth_keys_contents = try std.fmt.allocPrint(
            allocator,
            "command=\"{s}\" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKeIs8mJqigBZ5y84J4COgnAJJ5bHPKy+lM2SliMXbYm radar@roark\n",
            .{dispatch_path},
        );
        defer allocator.free(auth_keys_contents);

        const auth_keys_file = try std.Io.Dir.cwd().createFile(io, temp_dir_name ++ "/authorized_keys", .{});
        defer auth_keys_file.close(io);
        try auth_keys_file.writeStreamingAll(io, auth_keys_contents);
        if (.windows != builtin.os.tag) {
            try auth_keys_file.setPermissions(io, @enumFromInt(0o600));
        }

        // create known_hosts file
        const known_hosts_file = try std.Io.Dir.cwd().createFile(io, temp_dir_name ++ "/known_hosts", .{});
        defer known_hosts_file.close(io);
        const port_str = std.fmt.comptimePrint("{}", .{port});
        try known_hosts_file.writeStreamingAll(io, "[localhost]:" ++ port_str ++ " ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBLWmlR+TyfvK9UoSDPe1eO3irvpUa6MtxCVHCaiDOi9XjQstxfRpM5tmVBotZ/Mkw2kJr/O0ylCWvzqexqsTiUQ=");
        if (.windows != builtin.os.tag) {
            try known_hosts_file.setPermissions(io, @enumFromInt(0o600));
        }

        // create sshd_config file
        const sshd_config_str = blk: {
            // SetEnv PATH=... allows us to propagate the test process's PATH
            // to the spawned login shell (in sshd).
            //
            // without it, shells that don't auto-resource PATH on startup (e.g. nushell
            // on NixOS) through /etc/set-environment will fail to find
            // git-upload-pack / git-receive-pack.
            const base_config =
                \\AuthenticationMethods publickey
                \\PubkeyAuthentication yes
                \\PasswordAuthentication no
                \\StrictModes no
                //SetEnv PATH={s} -- if we find $PATH defined.
            ;
            var env_map = try std.process.Environ.createMap(init.minimal.environ, allocator);
            defer env_map.deinit();

            const config_str = if (env_map.get("PATH")) |path_str|
                try std.fmt.allocPrint(allocator, "{s}\n" ++ "SetEnv PATH={s}\n", .{ base_config, path_str })
            else
                try std.fmt.allocPrint(allocator, "{s}", .{base_config});

            break :blk config_str;
        };
        defer allocator.free(sshd_config_str);

        const sshd_config_file = try std.Io.Dir.cwd().createFile(io, temp_dir_name ++ "/sshd_config", .{});
        defer sshd_config_file.close(io);
        try sshd_config_file.writeStreamingAll(io, sshd_config_str);
        if (.windows != builtin.os.tag) {
            try sshd_config_file.setPermissions(io, @enumFromInt(0o600));
        }

        // create sshd.sh contents
        const host_key_path = try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name, "host_key" });
        defer allocator.free(host_key_path);
        const auth_keys_path = try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name, "authorized_keys" });
        defer allocator.free(auth_keys_path);
        const sshd_contents = try std.fmt.allocPrint(
            allocator,
            "#!/bin/sh\nexec $(which sshd) -p {} -f sshd_config -h \"{s}\" -D -e -o AuthorizedKeysFile=\"{s}\" -o PidFile=none",
            .{ port, host_key_path, auth_keys_path },
        );
        defer allocator.free(sshd_contents);

        // if path has a space char, it fucks up sshd
        try std.testing.expect(null == std.mem.indexOfScalar(u8, auth_keys_path, ' '));

        // create sshd.sh
        {
            const sshd_file = try std.Io.Dir.cwd().createFile(io, temp_dir_name ++ "/sshd.sh", .{});
            defer sshd_file.close(io);
            try sshd_file.writeStreamingAll(io, sshd_contents);
            if (.windows != builtin.os.tag) {
                try sshd_file.setPermissions(io, .executable_file);
            }
        }

        // build a copy-pasteable ssh command line for the user
        const ssh_key_path = try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name, "key" });
        defer allocator.free(ssh_key_path);
        const known_hosts_path = try std.fs.path.join(allocator, &.{ cwd_path, temp_dir_name, "known_hosts" });
        defer allocator.free(known_hosts_path);

        const ssh_command = try std.fmt.allocPrint(
            allocator,
            "ssh -p {} -i {s} -o UserKnownHostsFile={s} -o IdentitiesOnly=yes localhost",
            .{ port, ssh_key_path, known_hosts_path },
        );
        defer allocator.free(ssh_command);

        // git uses GIT_SSH_COMMAND to override the ssh invocation it'd
        // normally do. uses scp-style `host:path` rather than ssh://host/path
        // so the path stays relative — ssh://host/test would send /test
        // (absolute), which haxy serve rejects as outside the repo root.
        const git_command = try std.fmt.allocPrint(
            allocator,
            "GIT_SSH_COMMAND='ssh -p {} -i {s} -o UserKnownHostsFile={s} -o IdentitiesOnly=yes' git push localhost:test master",
            .{ port, ssh_key_path, known_hosts_path },
        );
        defer allocator.free(git_command);

        const Runnable = struct {
            io: std.Io,
            ssh_command: []const u8,
            git_command: []const u8,

            pub fn run(self: @This()) !void {
                std.debug.print(
                    \\
                    \\open the TUI from another terminal with:
                    \\
                    \\  {s}
                    \\
                    \\create a git repo and push it over ssh with:
                    \\
                    \\  mkdir -p temp-try/client/test
                    \\  cd temp-try/client/test
                    \\  git init
                    \\  echo "hello" > hello.txt
                    \\  git add hello.txt
                    \\  git commit -m "let there be light"
                    \\  {s}
                    \\
                    \\press enter to stop.
                    \\
                    \\
                , .{ self.ssh_command, self.git_command });

                // launch sshd
                var process = try std.process.spawn(self.io, .{
                    .argv = &.{"./sshd.sh"},
                    .cwd = .{ .path = temp_dir_name },
                    .stdin = .pipe,
                    .stdout = .inherit,
                    .stderr = .inherit,
                });
                defer process.kill(self.io);

                var buf: [1]u8 = undefined;
                _ = std.posix.read(std.posix.STDIN_FILENO, &buf) catch {};
            }
        };

        try srv.run(.xit, .{}, io, allocator, cwd_path, .{
            .data_dir = server_path,
        }, run_opts.err, Runnable{ .io = io, .ssh_command = ssh_command, .git_command = git_command });
    } else {
        var null_writer = std.Io.Writer.Discarding.init(&.{});
        const run_opts = hx.main.RunOpts{ .out = &null_writer.writer, .err = &null_writer.writer, .environ_map = init.environ_map };

        const Runnable = struct {
            io: std.Io,
            allocator: std.mem.Allocator,
            page: *const ui.Page,

            pub fn run(self: @This()) !void {
                // launch the TUI
                try hx.ui.run(self.io, self.allocator, self.page);
            }
        };

        try srv.run(.xit, .{}, io, allocator, cwd_path, .{
            .data_dir = server_path,
        }, run_opts.err, Runnable{ .io = io, .allocator = allocator, .page = &page });
    }
}
