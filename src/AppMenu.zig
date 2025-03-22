const std = @import("std");
const log = std.log.scoped(.app_menu);

const AppMenu = @This();

const dbus = @import("dbus.zig");

pub const name: [:0]const u8 = "com.github.southporter.Windchime";
const interface: [:0]const u8 = "com.canonical.dbusmenu";
pub const path: [:0]const u8 = "/com/github/southporter/Windchime";

pub fn init(self: *AppMenu, session: *dbus.Connection) !void {
    try session.registerObject(path, self.object());
}

pub fn deinit(_: *AppMenu, session: *dbus.Connection) void {
    session.unregisterObject(path) catch {};
}

fn object(self: *AppMenu) dbus.DBusObject {
    return .{
        .ptr = self,
        .vtable = &dbus.DBusObject.VTable{
            .unregister_function = AppMenu.unregister,
            .message_function = AppMenu.handleMessage,
        },
    };
}

fn unregister(connection: ?*dbus.c.DBusConnection, data: ?*anyopaque) callconv(.c) void {
    _ = connection;
    const menu: *AppMenu = @ptrCast(data);

    log.debug("Unregistering {any}", .{menu});
}

fn handleMessage(connection: ?*dbus.c.DBusConnection, message: ?*dbus.c.DBusMessage, data: ?*anyopaque) callconv(.c) dbus.c.DBusHandlerResult {
    _ = connection;
    const menu: *AppMenu = @ptrCast(data);
    _ = menu;

    if (message == null) {
        log.warn("Received null message", .{});
        return dbus.c.DBUS_HANDLER_RESULT_HANDLED;
    }

    const msg: *dbus.Message = @ptrCast(message orelse unreachable);

    log.debug("Handling message: {s} {s}", .{ msg.getInterface(), msg.getMember() });
    return dbus.c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
}
