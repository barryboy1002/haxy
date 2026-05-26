const std = @import("std");
const ui = @import("../../ui.zig");
const xit = @import("xit");
const xitui = xit.xitui;
const wgt = xitui.widget;
const layout = xitui.layout;
const inp = xitui.input;
const Grid = xitui.grid.Grid;
const Focus = xitui.focus.Focus;

const Self = @This();

const Tab = enum { users, repos };

pub fn init() Self {
    return .{};
}

pub const View = struct {
    box: wgt.Box(ui.Widget),
    data: *const Self,

    pub fn init(allocator: std.mem.Allocator, data: *const Self) !View {
        var box = try wgt.Box(ui.Widget).init(allocator, .{ .border_style = null, .direction = .horiz });
        errdefer box.deinit();

        inline for (@typeInfo(Tab).@"enum".fields) |tab_field| {
            const tab: Tab = @enumFromInt(tab_field.value);
            const name = switch (tab) {
                .users => "users",
                .repos => "repos",
            };
            var text_box = try wgt.TextBox(ui.Widget).init(allocator, name, .{ .border_style = .single, .wrap_kind = .none });
            errdefer text_box.deinit();
            text_box.getFocus().focusable = true;
            try box.children.put(box.allocator, text_box.getFocus().id, .{ .widget = .{ .text_box = text_box }, .rect = null, .min_size = null });
        }

        var self = View{ .box = box, .data = data };
        self.getFocus().child_id = box.children.keys()[0];
        return self;
    }

    pub fn deinit(self: *View) void {
        self.box.deinit();
    }

    pub fn build(self: *View, constraint: layout.Constraint, root_focus: *Focus) !void {
        self.clearGrid();
        for (self.box.children.keys(), self.box.children.values()) |id, *tab| {
            tab.widget.text_box.options.border_style = if (self.getFocus().child_id == id)
                (if (root_focus.grandchild_id == id) .double else .single)
            else
                .hidden;
        }
        try self.box.build(constraint, root_focus);
    }

    pub fn input(self: *View, key: inp.Key, root_focus: *Focus) !void {
        if (self.getFocus().child_id) |child_id| {
            const children = &self.box.children;
            if (children.getIndex(child_id)) |current_index| {
                var index = current_index;

                switch (key) {
                    .arrow_left => {
                        index -|= 1;
                    },
                    .arrow_right => {
                        if (index + 1 < children.count()) {
                            index += 1;
                        }
                    },
                    else => {},
                }

                if (index != current_index) {
                    try root_focus.setFocus(children.keys()[index]);
                }
            }
        }
    }

    pub fn clearGrid(self: *View) void {
        self.box.clearGrid();
    }

    pub fn getGrid(self: View) ?Grid {
        return self.box.getGrid();
    }

    pub fn getFocus(self: *View) *Focus {
        return self.box.getFocus();
    }

    pub fn getSelectedIndex(self: View) ?usize {
        if (self.box.focus.child_id) |child_id| {
            return self.box.children.getIndex(child_id);
        } else {
            return null;
        }
    }
};
