const std = @import("std");
const log = std.log.scoped(.app_menu);

const AppMenu = @This();

const dbus = @import("dbus.zig");

pub const name: [:0]const u8 = "com.github.southporter.Windchime";
const interface: [:0]const u8 = "com.canonical.dbusmenu";
pub const path: [:0]const u8 = "/com/github/southporter/Windchime";

err: dbus.Error,

pub fn init(self: *AppMenu, session: *dbus.Connection) !void {
    try session.registerObject(path, self.object());
    const err_ptr: *dbus.Error = &self.err;
    self.err.init();

    const properties_rule = "interface='org.freedesktop.DBus.Properties'";
    try session.addMatch(properties_rule, err_ptr);
    errdefer session.removeMatch(properties_rule);

    const status_notifier_item_rule = "interface='org.kde.StatusNotifierItem'";
    try session.addMatch(status_notifier_item_rule, err_ptr);
    try session.addFilter(signalHandler, self, null);

    const path_rule = "path='" ++ path ++ "'";
    try session.addMatch(path_rule, err_ptr);
    errdefer session.removeMatch(path_rule);
}

pub fn deinit(self: *AppMenu, session: *dbus.Connection) void {
    session.unregisterObject(path) catch {};

    var status_notifier_name_buf: [256]u8 = undefined;
    const status_notifier_name = std.fmt.bufPrintZ(
        &status_notifier_name_buf,
        "org.freedesktop.StatusNotifierItem-{d}-{d}",
        .{ std.c.getpid(), 13 },
    ) catch unreachable;
    _ = session.releaseName(status_notifier_name, &self.err);
}

pub const Event = union(enum) {};

pub fn dispatch(self: *AppMenu) !?Event {
    const is_done = self.session.readWriteDispatch(1);
    if (is_done) {
        return error.AppMenuDisconnected;
    }

    const message = self.session.popMessage();
    if (message) |msg| {
        const msg_type = msg.getType();
        const iface = msg.getInterface();
        const member = msg.getMember();
        log.debug("AppMenu Dispatch Message: {s} {s}", .{ iface, member });
        log.debug("AppMenu Dispatch Message type: {s}", .{@tagName(msg_type)});
        if (msg_type == .signal) {
            log.debug("Signal received", .{});
        } else if (msg_type == .method_call) {
            log.debug("Method call received", .{});
        }
    }

    return null;
}

fn signalHandler(conn: ?*dbus.c.DBusConnection, message: ?*dbus.c.DBusMessage, user_data: ?*anyopaque) callconv(.C) dbus.c.DBusHandlerResult {
    _ = conn;
    const self: *AppMenu = @alignCast(@ptrCast(user_data));
    _ = self;
    const iface = dbus.c.dbus_message_get_interface(message);
    const member = dbus.c.dbus_message_get_member(message);
    log.debug("AppMenu signal handler: {s} {s}", .{ iface, member });
    if (std.mem.orderZ(u8, "org.freedesktop.DBus.Properties", iface) == .eq) {
        if (std.mem.orderZ(u8, "PropertiesChanged", member) == .eq) {
            const msg: *dbus.Message = @ptrCast(message orelse unreachable);
            log.debug("Message signature: {s}", .{msg.getSignature()});
            var iter: dbus.Message.Iter = undefined;
            iter.init(msg) catch return dbus.c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
            const kind = iter.getArgType();
            log.debug("PropertiesChanged signal received: {s}", .{@tagName(kind)});

            // const i = iter.next() orelse unreachable;
            // std.debug.assert(i.kind == .string);
            // const iface_name = std.mem.span(i.value.str);
            // log.debug("PropertiesChanged signal received: {s}", .{iface_name});
        }
    }

    return dbus.c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
}
