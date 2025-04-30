const std = @import("std");
const log = std.log.scoped(.notification);
const dbus = @import("dbus.zig");
const Notification = @This();

pub const NotificationId = enum(u32) {
    _,
};

summary: [:0]const u8,
body: [:0]const u8,
actions: []const [*]const u8,

urgency: Urgency = Urgency.normal,

pub const Urgency = enum(u8) {
    low = 0,
    normal = 1,
    critical = 2,
};

pub fn marshall(notification: *const Notification, msg: *dbus.Message, app_name: [:0]const u8) !void {
    var iter: dbus.Message.Iter = undefined;
    iter.initAppend(msg);

    const empty_str: [:0]const u8 = "";
    try iter.appendBasic([:0]const u8, app_name);
    try iter.appendBasic(u32, 0);
    try iter.appendBasic([:0]const u8, empty_str);
    try iter.appendBasic(@TypeOf(notification.summary), notification.summary);
    try iter.appendBasic(@TypeOf(notification.body), notification.body);

    {
        var actions_iter: dbus.Message.Iter = undefined;
        try iter.openContainer(.array, "s", &actions_iter);
        errdefer iter.abandonContainer(&actions_iter);

        for (notification.actions) |action| {
            try actions_iter.appendBasic([*]const u8, action);
        }
        try iter.closeContainer(&actions_iter);
    }

    {
        var hints_iter: dbus.Message.Iter = undefined;
        hints_iter.initAppend(msg);

        try iter.openContainer(.array, "{sv}", &hints_iter);
        errdefer iter.abandonContainer(&hints_iter);

        {
            var hint_iter: dbus.Message.Iter = undefined;
            try hints_iter.openContainer(.dict_entry, null, &hint_iter);
            errdefer hints_iter.abandonContainer(&hint_iter);

            try hint_iter.appendBasic([:0]const u8, "urgency");
            {
                var variant_iter: dbus.Message.Iter = undefined;
                try hint_iter.openContainer(.variant, "y", &variant_iter);
                try variant_iter.appendBasic(u8, @intFromEnum(notification.urgency));
                try hint_iter.closeContainer(&variant_iter);
            }
            try hints_iter.closeContainer(&hint_iter);
        }
        try iter.closeContainer(&hints_iter);
    }

    return iter.appendBasic(i32, -1);
}

pub fn unmarshallId(msg: *dbus.Message) !NotificationId {
    var id_res: dbus.c.DBusBasicValue = undefined;
    const success = dbus.c.dbus_message_get_args(@ptrCast(msg), null, dbus.c.DBUS_TYPE_UINT32, &id_res, dbus.c.DBUS_TYPE_INVALID);
    if (success != dbus.TRUE) {
        log.debug("Failed to get NotificationId arguments: {}\n", .{success});
        return error.FailedUnmarshalNotificationID;
    } else {
        log.debug("Notification ID: {}\n", .{id_res.u32});
        return @enumFromInt(id_res.u32);
    }
}
