const std = @import("std");
const builtin = @import("builtin");
const evt = @import("../../event.zig");
const ui = @import("../../ui.zig");
const inp = @import("../input.zig");
const xit = @import("xit");
const hash = xit.hash;
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const Key = xitui.input.Key;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;

const wasm = builtin.target.cpu.arch == .wasm32;

pub const tab_label = "☼";

// the repo's settings, which only its owner sees. the hash kind is fixed at
// creation, so it only shows.
identity: []const u8,
name: []const u8,
description: []const u8,
access: evt.Repo.Access,
hash_kind: hash.HashKind,

const Self = @This();

pub const View = struct {
    center: ui.widget.Center,
    data: *const Self,
    session: *ui.Session,

    const access_index: usize = 2;
    const hash_index: usize = 3;

    pub fn init(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session) !View {
        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .vert });
        errdefer box.deinit(allocator);
        const route = ui.RoutablePage.repoRepoRoute(data.identity) orelse return error.RouteTooLong;
        box.getFocus().kind = .{ .custom = try std.fmt.allocPrint(session.page_arena.allocator(), "form:{s}", .{try route.toUrl(session.page_arena)}) };

        const saved_fields = if (session.formFeedback(.repo_settings)) |saved| saved.fields else null;

        {
            var name = try wgt.TextInput.init(allocator, .{ .label = " name ", .name = "name", .visible_width = 30, .round_corners = true, .render_content = session.is_terminal });
            errdefer name.deinit(allocator);
            name.getFocus().mode = .all;
            try name.setContent(allocator, if (saved_fields) |saved| saved.name else data.name);
            // show the start of the prefilled text
            name.cursor = 0;
            try box.children.put(allocator, name.getFocus().id, .{ .widget = .{ .text_input = name }, .rect = null, .min_size = .{ .width = null, .height = 3 } });
            box.getFocus().child_id = name.getFocus().id;
        }

        {
            var description = try wgt.TextInput.init(allocator, .{ .label = " description ", .name = "description", .visible_width = 30, .round_corners = true, .render_content = session.is_terminal });
            errdefer description.deinit(allocator);
            description.getFocus().mode = .all;
            try description.setContent(allocator, if (saved_fields) |saved| saved.description else data.description);
            // show the start of the prefilled text
            description.cursor = 0;
            try box.children.put(allocator, description.getFocus().id, .{ .widget = .{ .text_input = description }, .rect = null, .min_size = .{ .width = null, .height = 3 } });
        }

        {
            const access = if (saved_fields) |saved| saved.access else data.access;
            var access_radio = try ui.widget.Radio.init(allocator, session, "access", &.{ "private", "public" }, @tagName(access));
            errdefer access_radio.deinit(allocator);
            try box.children.put(allocator, access_radio.getFocus().id, .{ .widget = .{ .radio = access_radio }, .rect = null, .min_size = .{ .width = null, .height = 3 } });
        }

        {
            var hash_box = try wgt.TextBox.init(allocator, @tagName(data.hash_kind), .{ .border_style = .single, .round_corners = true, .wrap_kind = .none, .label = " hash " });
            errdefer hash_box.deinit(allocator);
            try box.children.put(allocator, hash_box.getFocus().id, .{ .widget = .{ .text_box = hash_box }, .rect = null, .min_size = .{ .width = null, .height = 3 } });
        }

        {
            var submit = try ui.widget.SubmitButton.initLabeled(allocator, "submit changes");
            errdefer submit.deinit(allocator);
            try box.children.put(allocator, submit.getFocus().id, .{ .widget = .{ .submit_button = submit }, .rect = null, .min_size = .{ .width = null, .height = 3 } });
        }

        return .{ .center = try ui.widget.Center.init(allocator, .{ .box = box }), .data = data, .session = session };
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.center.deinit(allocator);
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();
        const failure = if (self.session.formFeedback(.repo_settings)) |saved| saved.failure else null;
        (try formField(self.formBox(), "name")).options.label = if (failure) |value| switch (value) {
            .required_name => " name (required) ",
            .invalid_name => " name (invalid) ",
            .name_taken => " name (taken) ",
        } else " name ";
        // the web form handling finds the inputs by focus id
        const inputs_arena = self.session.arena.allocator();
        for (self.formBox().children.values()) |*child| switch (child.widget) {
            .text_input => |*ti| try self.session.text_inputs.put(inputs_arena, ti.getFocus().id, ti),
            else => {},
        };
        try self.center.build(allocator, constraint, root_focus);
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        const cid = self.formBox().getFocus().child_id orelse return;
        const cur = self.formBox().children.getIndex(cid) orelse return;
        const child = &self.formBox().children.values()[cur];
        const keys = self.formBox().children.keys();

        const on_submit = child.widget == .submit_button;
        // the read-only hash row is stepped over
        const direction = inp.vertDirection(key);
        if (direction == .up or key == .back_tab) return if (cur > 0) root_focus.setFocus(keys[if (cur - 1 == hash_index) access_index else cur - 1]);
        if (direction == .down or key == .tab) return if (cur + 1 < keys.len) root_focus.setFocus(keys[if (cur + 1 == hash_index) hash_index + 1 else cur + 1]);
        switch (key) {
            .enter => if (on_submit) return self.submitForm(allocator),
            .mouse => |mouse| if (on_submit) {
                if (inp.leftClickOn(root_focus, child.widget.submit_button.buttonId(), mouse)) return self.submitForm(allocator);
            },
            else => {},
        }
        try child.widget.input(allocator, key, root_focus);
    }

    fn formField(form: *wgt.Box(ui.Widget), name: []const u8) !*wgt.TextInput {
        for (form.children.values()) |*child| switch (child.widget) {
            .text_input => |*text_input| if (std.mem.eql(u8, text_input.options.name, name)) return text_input,
            else => {},
        };
        return error.MissingFormField;
    }

    // update the repo and navigate to its new url. this is the terminal path;
    // the web posts the form to the settings route.
    fn submitForm(self: *View, allocator: std.mem.Allocator) !void {
        if (comptime wasm) return;
        const io = self.session.io orelse return;
        const users_dir = self.session.users_dir orelse return;
        const actor = (try self.session.authorize(self.data.identity, .owner)) orelse return;

        const name = try (try formField(self.formBox(), "name")).text(allocator);
        defer allocator.free(name);
        const description = try (try formField(self.formBox(), "description")).text(allocator);
        defer allocator.free(description);
        const access_radio = &self.formBox().children.values()[access_index].widget.radio;
        const access = std.meta.stringToEnum(evt.Repo.Access, access_radio.selected()) orelse unreachable;

        const route = update(io, allocator, users_dir, actor, self.data.identity, name, description, access) catch |err| {
            const failure = ui.Session.FormFeedback.RepoFailure.fromError(err) orelse return err;
            const aa = self.session.arena.allocator();
            self.session.data.form_feedback = .{ .repo_settings = .{ .failure = failure, .fields = .{
                .name = try aa.dupe(u8, name),
                .description = try aa.dupe(u8, description),
                .access = access,
            } } };
            return;
        };
        try self.session.navigate(route);
    }

    fn formBox(self: *View) *wgt.Box(ui.Widget) {
        return &self.center.child.box;
    }

    pub fn clearGrid(self: *View) void {
        self.center.clearGrid();
    }

    pub fn getGrid(self: View) ?Grid {
        return self.center.getGrid();
    }

    pub fn getFocus(self: *View) *Focus {
        return self.center.getFocus();
    }

    // up leaves the form from its first control
    pub fn atTop(self: View) bool {
        const box = &self.center.child.box;
        return box.focus.child_id == box.children.keys()[0];
    }
};

// change the repo `identity` names as `actor`, its owner, returning its
// settings route under its new name
pub fn update(
    io: std.Io,
    allocator: std.mem.Allocator,
    users_dir: []const u8,
    actor: ui.Actor,
    identity: []const u8,
    name: []const u8,
    description: []const u8,
    access: evt.Repo.Access,
) !ui.RoutablePage {
    const parsed = ui.RoutablePage.RepoIdentity.parse(identity) orelse return error.NotFound;
    const owner_id = actor.repo_user_id orelse return error.NotFound;
    try evt.updateRepo(io, allocator, users_dir, &owner_id, actor.author, parsed.name, name, description, access);
    var buf: [ui.RoutablePage.repo_route_max_len]u8 = undefined;
    const new_identity = std.fmt.bufPrint(&buf, "{s}:{s}", .{ parsed.owner, name }) catch return error.RouteTooLong;
    return ui.RoutablePage.repoRepoRoute(new_identity) orelse error.RouteTooLong;
}
