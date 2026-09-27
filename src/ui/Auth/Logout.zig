const std = @import("std");
const ui = @import("../../ui.zig");
const inp = @import("../input.zig");
const xit = @import("xit");
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const Key = xitui.input.Key;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;

const Self = @This();

pub fn init() Self {
    return .{};
}

pub const View = struct {
    center: ui.widget.Center,
    data: *const Self,
    session: *ui.Session,
    ansi_id: usize,
    logout_id: usize,

    const ansi_index: usize = 0;

    pub fn init(allocator: std.mem.Allocator, data: *const Self, session: *ui.Session) !View {
        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .round_corners = true, .direction = .vert });
        errdefer box.deinit(allocator);

        const ansi_id = try addButton(allocator, &box, "form:ansi", ansiLabel(session));

        {
            var gap = try wgt.Text.init(allocator, " ");
            errdefer gap.deinit(allocator);
            try box.children.put(allocator, gap.getFocus().id, .{
                .widget = .{ .text = gap },
                .rect = null,
                .min_size = null,
            });
        }

        const logout_id = try addButton(allocator, &box, "form:logout", "logout");

        box.getFocus().child_id = box.children.keys()[ansi_index];

        return .{
            .center = try ui.widget.Center.init(allocator, .{ .box = box }),
            .data = data,
            .session = session,
            .ansi_id = ansi_id,
            .logout_id = logout_id,
        };
    }

    // each button sits in its own form box so the web renderer posts it to its own route
    fn addButton(allocator: std.mem.Allocator, parent: *wgt.Box(ui.Widget), form: []const u8, label: []const u8) !usize {
        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .vert });
        errdefer box.deinit(allocator);
        box.getFocus().kind = .{ .custom = form };

        var button = try wgt.TextBox.init(allocator, label, .{ .border_style = .single, .round_corners = true, .wrap_kind = .none });
        errdefer button.deinit(allocator);
        button.getFocus().mode = .all;
        // the renderer distinguishes plain clickables from buttons that
        // should POST to a server route by this kind.
        button.getFocus().kind = .{ .custom = "submit" };
        const button_id = button.getFocus().id;
        try box.children.put(allocator, button_id, .{
            .widget = .{ .text_box = button },
            .rect = null,
            .min_size = null,
        });
        box.getFocus().child_id = button_id;

        try parent.children.put(allocator, box.getFocus().id, .{
            .widget = .{ .box = box },
            .rect = null,
            .min_size = null,
        });
        return button_id;
    }

    pub fn deinit(self: *View, allocator: std.mem.Allocator) void {
        self.center.deinit(allocator);
    }

    pub fn build(self: *View, allocator: std.mem.Allocator, constraint: layout.Constraint, root_focus: *Focus) !void {
        const ansi_box = &self.center.child.box.children.values()[ansi_index].widget.box;
        try ansi_box.children.values()[0].widget.text_box.setContent(allocator, ansiLabel(self.session));
        try self.center.build(allocator, constraint, root_focus);
    }

    pub fn input(self: *View, allocator: std.mem.Allocator, key: Key, root_focus: *Focus) !void {
        _ = allocator;
        const focused_id = if (self.atTop()) self.ansi_id else self.logout_id;
        switch (key) {
            .arrow_up => root_focus.setFocus(self.ansi_id),
            .arrow_down => root_focus.setFocus(self.logout_id),
            .enter => try self.activate(focused_id),
            .mouse => |mouse| if (inp.leftClickOn(root_focus, focused_id, mouse)) try self.activate(focused_id),
            else => {},
        }
    }

    fn activate(self: *View, button_id: usize) !void {
        if (button_id == self.ansi_id) {
            try self.session.push(.toggle_ansi);
            return;
        }
        self.session.logOut();
        // leave the auth tab for the page it belongs to, where the web's
        // /logout redirect also lands
        try self.session.navigate(self.session.data.current_page.pageRoot());
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

    pub fn atTop(self: View) bool {
        return self.center.child.box.focus.child_id == self.center.child.box.children.keys()[ansi_index];
    }
};

fn ansiLabel(session: *const ui.Session) []const u8 {
    return if (session.data.enable_ansi) "turn off ANSI art" else "turn on ANSI art";
}
