const std = @import("std");
const log = std.log.scoped(.status_notifier_item);
const dbus = @import("dbus.zig");
const StatusNotifierItem = @This();

category: Category,
id: [:0]const u8,
title: [:0]const u8,
status: Status,
window_id: i32 = 0,

// KDE specific
icon_theme_path: [:0]const u8 = "",

icon_name: [:0]const u8 = "",
icon_pixmap: Pixmap = .{},
overlay_icon_name: [:0]const u8 = "",
overlay_icon_pixmap: Pixmap = .{},
attention_icon_name: [:0]const u8 = "",
attention_icon_pixmap: Pixmap = .{},
attention_movie_name: [:0]const u8 = "",
tooltip: Tooltip = .{},
item_is_menu: bool = false,
menu: [:0]const u8 = "",

pub const Category = enum {
    application_status,
    communications,
    system_service,
    hardware,
};

pub const Status = enum(u8) {
    active = 0,
    passive,
    needs_attention,
};
const StatusNames = [_][:0]const u8{
    "active",
    "passive",
    "needs_attention",
};

pub const Pixmap = struct {
    width: u32 = 0,
    height: u32 = 0,
    data: []const u8 = &.{},

    pub fn marshall(self: *const Pixmap, parent: *dbus.Message.Iter) !void {
        var container: dbus.Message.Iter = undefined;
        try parent.openContainer(.array, "(iiay)", &container);
        errdefer parent.abandonContainer(&container);

        {
            var struct_iter: dbus.Message.Iter = undefined;

            // For some reason, structs and dict_entries require a null string
            // for the type signature
            try container.openContainer(.@"struct", null, &struct_iter);
            errdefer container.abandonContainer(&struct_iter);

            try struct_iter.appendBasic(i32, @intCast(self.width));
            try struct_iter.appendBasic(i32, @intCast(self.height));
            {
                var data_iter: dbus.Message.Iter = undefined;
                try struct_iter.openContainer(.array, "y", &data_iter);
                errdefer struct_iter.abandonContainer(&data_iter);

                try data_iter.appendFixedArray(u8, self.data.ptr, self.data.len);
                try struct_iter.closeContainer(&data_iter);
            }

            try container.closeContainer(&struct_iter);
        }

        try parent.closeContainer(&container);
    }
};

pub const Tooltip = struct {
    icon_name: [:0]const u8 = "",
    icon_pixmap: Pixmap = .{},
    title: [:0]const u8 = "",
    description: [:0]const u8 = "",

    pub fn marshall(self: *const Tooltip, parent: *dbus.Message.Iter) !void {
        var container: dbus.Message.Iter = undefined;
        try parent.openContainer(.@"struct", null, &container);
        errdefer parent.abandonContainer(&container);

        try container.appendBasic([:0]const u8, self.icon_name);

        try self.icon_pixmap.marshall(&container);

        try container.appendBasic([:0]const u8, self.title);
        try container.appendBasic([:0]const u8, self.description);

        try parent.closeContainer(&container);
    }
};

pub fn marshallGetAll(self: *const StatusNotifierItem, msg: *dbus.Message, kind: enum { kde, freedesktop }) !void {
    var iter: dbus.Message.Iter = undefined;
    iter.initAppend(msg);

    var array: dbus.Message.Iter = undefined;
    try iter.openContainer(.array, "{sv}", &array);
    errdefer iter.abandonContainer(&array);

    {
        var dict_entry: dbus.Message.Iter = undefined;
        try array.openContainer(.dict_entry, null, &dict_entry);
        errdefer array.abandonContainer(&dict_entry);

        try dict_entry.appendBasic([:0]const u8, "Category");
        {
            var variant_iter: dbus.Message.Iter = undefined;
            try dict_entry.openContainer(.variant, "s", &variant_iter);
            errdefer dict_entry.abandonContainer(&variant_iter);

            try variant_iter.appendBasic([:0]const u8, @tagName(self.category));
            try dict_entry.closeContainer(&variant_iter);
        }
        try array.closeContainer(&dict_entry);
    }
    {
        var dict_entry: dbus.Message.Iter = undefined;
        try array.openContainer(.dict_entry, null, &dict_entry);
        errdefer array.abandonContainer(&dict_entry);

        try dict_entry.appendBasic([:0]const u8, "Id");
        {
            var variant_iter: dbus.Message.Iter = undefined;
            try dict_entry.openContainer(.variant, "s", &variant_iter);
            errdefer dict_entry.abandonContainer(&variant_iter);

            try variant_iter.appendBasic([:0]const u8, self.id);
            try dict_entry.closeContainer(&variant_iter);
        }
        try array.closeContainer(&dict_entry);
    }
    {
        var dict_entry: dbus.Message.Iter = undefined;
        try array.openContainer(.dict_entry, null, &dict_entry);
        errdefer array.abandonContainer(&dict_entry);

        try dict_entry.appendBasic([:0]const u8, "Title");
        {
            var variant_iter: dbus.Message.Iter = undefined;
            try dict_entry.openContainer(.variant, "s", &variant_iter);
            errdefer dict_entry.abandonContainer(&variant_iter);

            try variant_iter.appendBasic([:0]const u8, self.title);
            try dict_entry.closeContainer(&variant_iter);
        }
        try array.closeContainer(&dict_entry);
    }

    {
        var dict_entry: dbus.Message.Iter = undefined;
        try array.openContainer(.dict_entry, null, &dict_entry);
        errdefer array.abandonContainer(&dict_entry);

        try dict_entry.appendBasic([:0]const u8, "Status");
        {
            var variant_iter: dbus.Message.Iter = undefined;
            try dict_entry.openContainer(.variant, "s", &variant_iter);
            errdefer dict_entry.abandonContainer(&variant_iter);

            try variant_iter.appendBasic([:0]const u8, StatusNames[@intFromEnum(self.status)]);
            try dict_entry.closeContainer(&variant_iter);
        }
        try array.closeContainer(&dict_entry);
    }

    {
        var dict_entry: dbus.Message.Iter = undefined;
        try array.openContainer(.dict_entry, null, &dict_entry);
        errdefer array.abandonContainer(&dict_entry);

        try dict_entry.appendBasic([:0]const u8, "WindowId");
        {
            var variant_iter: dbus.Message.Iter = undefined;
            try dict_entry.openContainer(.variant, "i", &variant_iter);
            errdefer dict_entry.abandonContainer(&variant_iter);

            try variant_iter.appendBasic(i32, self.window_id);
            try dict_entry.closeContainer(&variant_iter);
        }
        try array.closeContainer(&dict_entry);
    }

    if (kind == .kde) {
        {
            var dict_entry: dbus.Message.Iter = undefined;
            try array.openContainer(.dict_entry, null, &dict_entry);
            errdefer array.abandonContainer(&dict_entry);

            try dict_entry.appendBasic([:0]const u8, "IconThemePath");
            {
                var variant_iter: dbus.Message.Iter = undefined;
                try dict_entry.openContainer(.variant, "s", &variant_iter);
                errdefer dict_entry.abandonContainer(&variant_iter);

                try variant_iter.appendBasic([:0]const u8, self.icon_theme_path);
                try dict_entry.closeContainer(&variant_iter);
            }
            try array.closeContainer(&dict_entry);
        }
    }

    {
        var dict_entry: dbus.Message.Iter = undefined;
        try array.openContainer(.dict_entry, null, &dict_entry);
        errdefer array.abandonContainer(&dict_entry);

        try dict_entry.appendBasic([:0]const u8, "IconName");
        {
            var variant_iter: dbus.Message.Iter = undefined;
            try dict_entry.openContainer(.variant, "s", &variant_iter);
            errdefer dict_entry.abandonContainer(&variant_iter);

            try variant_iter.appendBasic([:0]const u8, self.icon_name);
            try dict_entry.closeContainer(&variant_iter);
        }
        try array.closeContainer(&dict_entry);
    }

    {
        var dict_entry: dbus.Message.Iter = undefined;
        try array.openContainer(.dict_entry, null, &dict_entry);
        errdefer array.abandonContainer(&dict_entry);

        try dict_entry.appendBasic([:0]const u8, "IconPixmap");
        {
            var variant_iter: dbus.Message.Iter = undefined;
            try dict_entry.openContainer(.variant, "a(iiay)", &variant_iter);
            errdefer dict_entry.abandonContainer(&variant_iter);
            try self.icon_pixmap.marshall(&variant_iter);
            try dict_entry.closeContainer(&variant_iter);
        }

        try array.closeContainer(&dict_entry);
    }
    {
        var dict_entry: dbus.Message.Iter = undefined;
        try array.openContainer(.dict_entry, null, &dict_entry);
        errdefer array.abandonContainer(&dict_entry);

        try dict_entry.appendBasic([:0]const u8, "OverlayIconName");
        {
            var variant_iter: dbus.Message.Iter = undefined;
            try dict_entry.openContainer(.variant, "s", &variant_iter);
            errdefer dict_entry.abandonContainer(&variant_iter);

            try variant_iter.appendBasic([:0]const u8, self.overlay_icon_name);
            try dict_entry.closeContainer(&variant_iter);
        }
        try array.closeContainer(&dict_entry);
    }

    {
        var dict_entry: dbus.Message.Iter = undefined;
        try array.openContainer(.dict_entry, null, &dict_entry);
        errdefer array.abandonContainer(&dict_entry);

        try dict_entry.appendBasic([:0]const u8, "OverlayIconPixmap");
        {
            var variant_iter: dbus.Message.Iter = undefined;
            try dict_entry.openContainer(.variant, "a(iiay)", &variant_iter);
            errdefer dict_entry.abandonContainer(&variant_iter);
            try self.overlay_icon_pixmap.marshall(&variant_iter);
            try dict_entry.closeContainer(&variant_iter);
        }

        try array.closeContainer(&dict_entry);
    }
    {
        var dict_entry: dbus.Message.Iter = undefined;
        try array.openContainer(.dict_entry, null, &dict_entry);
        errdefer array.abandonContainer(&dict_entry);

        try dict_entry.appendBasic([:0]const u8, "AttentionIconName");
        {
            var variant_iter: dbus.Message.Iter = undefined;
            try dict_entry.openContainer(.variant, "s", &variant_iter);
            errdefer dict_entry.abandonContainer(&variant_iter);

            try variant_iter.appendBasic([:0]const u8, self.attention_icon_name);
            try dict_entry.closeContainer(&variant_iter);
        }
        try array.closeContainer(&dict_entry);
    }
    {
        var dict_entry: dbus.Message.Iter = undefined;
        try array.openContainer(.dict_entry, null, &dict_entry);
        errdefer array.abandonContainer(&dict_entry);

        try dict_entry.appendBasic([:0]const u8, "AttentionIconPixmap");
        {
            var variant_iter: dbus.Message.Iter = undefined;
            try dict_entry.openContainer(.variant, "a(iiay)", &variant_iter);
            errdefer dict_entry.abandonContainer(&variant_iter);

            try self.attention_icon_pixmap.marshall(&variant_iter);
            try dict_entry.closeContainer(&variant_iter);
        }
        try array.closeContainer(&dict_entry);
    }
    {
        var dict_entry: dbus.Message.Iter = undefined;
        try array.openContainer(.dict_entry, null, &dict_entry);
        errdefer array.abandonContainer(&dict_entry);

        try dict_entry.appendBasic([:0]const u8, "AttentionMovieName");
        {
            var variant_iter: dbus.Message.Iter = undefined;
            try dict_entry.openContainer(.variant, "s", &variant_iter);
            errdefer dict_entry.abandonContainer(&variant_iter);

            try variant_iter.appendBasic([:0]const u8, self.attention_movie_name);
            try dict_entry.closeContainer(&variant_iter);
        }
        try array.closeContainer(&dict_entry);
    }

    {
        var dict_entry: dbus.Message.Iter = undefined;
        try array.openContainer(.dict_entry, null, &dict_entry);
        errdefer array.abandonContainer(&dict_entry);

        try dict_entry.appendBasic([:0]const u8, "ToolTip");
        {
            var variant_iter: dbus.Message.Iter = undefined;
            try dict_entry.openContainer(.variant, "(sa(iiay)ss)", &variant_iter);
            errdefer dict_entry.abandonContainer(&variant_iter);

            try self.tooltip.marshall(&variant_iter);
            try dict_entry.closeContainer(&variant_iter);
        }

        try array.closeContainer(&dict_entry);
    }
    {
        var dict_entry: dbus.Message.Iter = undefined;
        try array.openContainer(.dict_entry, null, &dict_entry);
        errdefer array.abandonContainer(&dict_entry);

        try dict_entry.appendBasic([:0]const u8, "ItemIsMenu");
        {
            var variant_iter: dbus.Message.Iter = undefined;
            try dict_entry.openContainer(.variant, "b", &variant_iter);
            errdefer dict_entry.abandonContainer(&variant_iter);

            try variant_iter.appendBasic(bool, self.item_is_menu);
            try dict_entry.closeContainer(&variant_iter);
        }
        try array.closeContainer(&dict_entry);
    }
    {
        var dict_entry: dbus.Message.Iter = undefined;
        try array.openContainer(.dict_entry, null, &dict_entry);
        errdefer array.abandonContainer(&dict_entry);

        try dict_entry.appendBasic([:0]const u8, "Menu");
        {
            var variant_iter: dbus.Message.Iter = undefined;
            try dict_entry.openContainer(.variant, "s", &variant_iter);
            errdefer dict_entry.abandonContainer(&variant_iter);

            try variant_iter.appendBasic([:0]const u8, self.menu);
            try dict_entry.closeContainer(&variant_iter);
        }
        try array.closeContainer(&dict_entry);
    }

    try iter.closeContainer(&array);
}

/// > dbus[376003]: Writing an element of type struct, but the expected type here is dict_entry
/// > The overall signature expected here was 'sa{sv}' and we are on byte 2 of that signature.
/// >   D-Bus not built with -rdynamic so unable to print a backtrace
///
/// This message was a little confusing. I found out that it meant I was using a parent
/// container when I should have been using a child container.
/// Using LLDB gave me a backtrace to the line and it took a while to figure it out.
/// ```diff
/// -     try array.appendBasic([:0]const u8, "Category");
/// +     try dict_entry.appendBasic([:0]const u8, "Category");
/// ```
///
/// > dbus[375446]: arguments to dbus_message_iter_open_container() were incorrect, assertion "(type == DBUS_TYPE_STRUCT && contained_signature == NULL) || (type == DBUS_TYPE_DICT_ENTRY && contained_signature == NULL) || (type == DBUS_TYPE_VARIANT && contained_signature != NULL) || (type == DBUS_TYPE_ARRAY && contained_signature != NULL)" failed in file ../../dbus/dbus-message.c line 2987.
/// > This is normally a bug in some application using the D-Bus library.
///
/// This message is more straightforward. Basically, if you have a container type of struct, dict_entry then the type signature needs to be null. The opposite is true for array and variant.
fn notes() void {}
