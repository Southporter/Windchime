const std = @import("std");
const dbus = @import("dbus.zig");
const BoundedQueue = @import("queues.zig").BoundedQueue;
const Notification = @import("Notification.zig");
const StatusNotifierItem = @import("StatusNotifierItem.zig");
const icons = @import("icons.zig");
const IPC = @This();
const log = std.log.scoped(.ipc);

const introspection: [:0]const u8 = @embedFile("./introspection.xml");

app_name: [:0]const u8 = "com.github.southporter.Windchime",
path: [:0]const u8 = "/com/github/southporter/Windchime",
session: *dbus.Connection,
queue: BoundedQueue(32, Event) = .empty,
allocator: std.mem.Allocator,
serial: u32 = 0,
status_notifier_item: StatusNotifierItem,

pub const Event = struct {
    tag: Kind,
    id: u32,
    data: Data,

    pub const CloseReason = enum(u32) {
        expired = 1,
        dismissed,
        app_closed,
        _,
    };

    pub const Data = union {
        closed: CloseReason,
        activation_token: [:0]const u8,
        action: []const u8,
    };
    pub const Kind = enum {
        action_invoked,
        activation_token,
        notification_closed,
    };
};

const rules = [_][:0]const u8{
    "type='signal',interface='org.freedesktop.Notifications'",
    // "interface='org.freedesktop.DBus.Properties'",
    // "interface='com.canonical.dbusmenu'",
};
// const path_rules = [_][:0]const u8{
//     "path='{}',interface='org.freedesktop.DBus.Properties'",
//     "path_namespace='" ++ path ++ "'",
// };

pub fn init(self: *IPC, alloc: std.mem.Allocator, app_name: [:0]const u8, path: [:0]const u8) !void {
    self.app_name = app_name;
    self.path = path;
    self.allocator = alloc;
    self.queue = .empty;
    self.status_notifier_item = StatusNotifierItem{
        .category = .application_status,
        .id = "com.github.southporter.Windchime",
        .title = "Windchime",
        .status = .active,
        .window_id = 0,
        .icon_pixmap = .{
            .height = 16,
            .width = 16,
            .data = icons.default,
        },

        .item_is_menu = true,
        .menu = path,
    };

    var err: dbus.Error = undefined;
    err.init();
    defer err.free();

    const session = try dbus.Connection.connect(.session, &err);
    self.session = session;
    errdefer session.close() catch {};

    if (err.isSet()) {
        return error.DBusConnectionFailed;
    }

    try session.registerObject(path, self.object());
    errdefer session.unregisterObject(path) catch {};
    try session.registerObject("/StatusNotifierItem", self.object());
    errdefer session.unregisterObject("/StatusNotifierItem") catch {};

    try session.addFilter(signalHandler, @ptrCast(self), null);

    for (rules) |rule| {
        try session.addMatch(rule, &err);
    }

    // Setup names
    var status_notifier_name_buf: [256]u8 = undefined;
    const status_notifier_name = try std.fmt.bufPrintZ(
        &status_notifier_name_buf,
        "org.kde.StatusNotifierItem-{d}-{d}",
        .{ std.c.getpid(), 13 },
    );
    const res = try session.requestName(status_notifier_name, .{
        .allow_replacement = true,
        .replace_existing = true,
    }, &err);
    log.debug("Requesting name: {s}", .{@tagName(res)});
    errdefer _ = session.releaseName(status_notifier_name, &err);

    const msg = try dbus.Message.new(
        "org.kde.StatusNotifierWatcher",
        "/StatusNotifierWatcher",
        "org.kde.StatusNotifierWatcher",
        "RegisterStatusNotifierItem",
    );
    const success = dbus.c.dbus_message_append_args(@ptrCast(msg), dbus.c.DBUS_TYPE_STRING, &status_notifier_name.ptr, dbus.c.DBUS_TYPE_INVALID);
    if (success != dbus.TRUE) {
        log.err("Failed to append args to message", .{});
        return error.DBusMessageAppendArgsFailed;
    }
    const reply = try session.sendWithReplyAndBlock(msg, 200, &err);
    if (reply == null) {
        log.err("Failed to send message", .{});
        return error.DBusMessageSendFailed;
    }
}

pub fn deinit(self: *IPC) void {
    for (rules) |rule| {
        self.session.removeMatch(rule);
    }
    self.session.unregisterObject(self.path) catch {};
    self.session.removeFilter(signalHandler, @ptrCast(self));
    self.session.close() catch {};
}

pub fn dispatch(self: *IPC) !?Event {
    if (self.queue.pop()) |event| {
        return event;
    }

    const is_done = self.session.readWriteDispatch(1);
    if (is_done) {
        return error.DBusDisconnected;
    }

    if (self.session.popMessage()) |msg| {
        var err: dbus.Error = undefined;
        err.init();
        defer err.free();

        const sender = msg.getSender();
        const interface = msg.getInterface();
        const member = msg.getMember();
        log.debug("(DISPATCH) Received signal from {s} on interface {s} with member {s}", .{ sender, interface, member });
        if (msg.isKind(.signal)) {
            const expected_interface: [:0]const u8 = "org.freedesktop.Notifications";
            if (!std.mem.eql(u8, std.mem.span(interface), expected_interface)) {
                return null;
            }
            const mem_slice = std.mem.span(member);
            const notification_closed: [:0]const u8 = "NotificationClosed";
            if (std.mem.eql(u8, mem_slice, notification_closed)) {
                var id: u32 = 0;
                var reason: u32 = 0;
                try dbus.checkMemoryError(dbus.c.dbus_message_get_args(@ptrCast(msg), null, dbus.c.DBUS_TYPE_UINT32, &id, dbus.c.DBUS_TYPE_UINT32, &reason, dbus.c.DBUS_TYPE_INVALID));
                log.debug("Notification closed: {} ({s})", .{ id, switch (reason) {
                    1 => "expired",
                    2 => "dismissed",
                    3 => "closed by app",
                    else => "unknown reason",
                } });
                return Event{
                    .tag = .notification_closed,
                    .id = id,
                    .data = .{
                        .closed = @enumFromInt(reason),
                    },
                };
            }
            const action_invoked: [:0]const u8 = "ActionInvoked";
            if (std.mem.eql(u8, mem_slice, action_invoked)) {
                var id: u32 = 0;
                var action: [*:0]const u8 = undefined;
                try dbus.checkMemoryError(dbus.c.dbus_message_get_args(@ptrCast(msg), null, dbus.c.DBUS_TYPE_UINT32, &id, dbus.c.DBUS_TYPE_STRING, &action, dbus.c.DBUS_TYPE_INVALID));
                log.debug("Action invoked: {} ({s})", .{ id, action });
                const span = std.mem.span(action);
                return Event{
                    .tag = .action_invoked,
                    .id = id,
                    .data = .{
                        .action = try self.allocator.dupe(u8, span),
                    },
                };
            }
            const activation_token: [:0]const u8 = "ActivationToken";
            if (std.mem.eql(u8, mem_slice, activation_token)) {
                var id: u32 = 0;
                var token: [*:0]const u8 = undefined;
                try dbus.checkMemoryError(dbus.c.dbus_message_get_args(@ptrCast(msg), null, dbus.c.DBUS_TYPE_UINT32, &id, dbus.c.DBUS_TYPE_STRING, &token, dbus.c.DBUS_TYPE_INVALID));
                log.debug("Activation token received: {} ({s})", .{ id, token });
                const span = std.mem.span(token);
                return Event{
                    .tag = .activation_token,
                    .id = id,
                    .data = .{
                        .activation_token = try self.allocator.dupeZ(u8, span),
                    },
                };
            }
        }
        if (std.mem.orderZ(u8, "org.freedesktop.DBus.Properties", interface) == .eq) {
            if (std.mem.orderZ(u8, "GetAll", member) == .eq) {
                log.debug("Message signature: {s}", .{msg.getSignature()});
                var iface_name_raw: [*:0]const u8 = undefined;
                const success = dbus.c.dbus_message_get_args(@ptrCast(msg), null, dbus.c.DBUS_TYPE_STRING, &iface_name_raw, dbus.c.DBUS_TYPE_INVALID);
                if (success != dbus.TRUE) {
                    log.err("Failed to get arguments from message", .{});
                    return null;
                }
                const iface_name = std.mem.span(iface_name_raw);

                log.debug("GetAll for interface: {s}", .{iface_name});
                var reply = msg.reply() catch |e| {
                    log.err("Failed to create reply message: {any}", .{e});
                    return null;
                };
                defer reply.deinit();

                self.status_notifier_item.marshallGetAll(msg, if (std.mem.indexOf(u8, iface_name, "org.kde.")) |_| .kde else .freedesktop) catch |e| {
                    log.err("Failed to marshall GetAll message: {any}", .{e});
                    return null;
                };
                try self.session.send(reply, self.serial);
                self.session.flush();
                self.serial += 1;
            }
        }
        if (std.mem.orderZ(u8, "org.freedesktop.DBus.Introspectable", interface) == .eq) {
            if (std.mem.orderZ(u8, "Introspect", member) == .eq) {
                log.debug("Message signature: {s}", .{msg.getSignature()});
                var reply = try msg.reply();
                defer reply.deinit();

                const success = dbus.c.dbus_message_append_args(@ptrCast(msg), dbus.c.DBUS_TYPE_STRING, &introspection.ptr, dbus.c.DBUS_TYPE_INVALID);
                if (success != dbus.TRUE) {
                    log.err("Failed to append args to message", .{});
                    return null;
                }
                try self.session.send(reply, self.serial);
                self.session.flush();
                self.serial += 1;
            }
        }
    }

    return null;
}

fn object(self: *IPC) dbus.DBusObject {
    return .{
        .ptr = self,
        .vtable = &dbus.DBusObject.VTable{
            .unregister_function = IPC.unregister,
            .message_function = IPC.handleMessage,
        },
    };
}

fn unregister(connection: ?*dbus.c.DBusConnection, data: ?*anyopaque) callconv(.c) void {
    _ = connection;
    const ipc: *IPC = @alignCast(@ptrCast(data));

    log.debug("Unregistering {any}", .{ipc});
}

fn handleMessage(connection: ?*dbus.c.DBusConnection, message: ?*dbus.c.DBusMessage, data: ?*anyopaque) callconv(.c) dbus.c.DBusHandlerResult {
    _ = connection;
    const ipc: *IPC = @alignCast(@ptrCast(data));
    _ = ipc;

    if (message == null) {
        log.warn("Received null message", .{});
        return dbus.c.DBUS_HANDLER_RESULT_HANDLED;
    }

    const msg: *dbus.Message = @ptrCast(message orelse unreachable);

    log.debug("Handling message: {s} {s}", .{ msg.getInterface(), msg.getMember() });
    return dbus.c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
}

fn signalHandler(conn: ?*dbus.c.DBusConnection, message: ?*dbus.c.DBusMessage, user_data: ?*anyopaque) callconv(.C) dbus.c.DBusHandlerResult {
    _ = conn;
    const self: *IPC = @alignCast(@ptrCast(user_data));

    const sender = dbus.c.dbus_message_get_sender(message);
    const interface = dbus.c.dbus_message_get_interface(message);
    const member = dbus.c.dbus_message_get_member(message);
    log.debug("(Handler) Received signal from {s} on interface {s} with member {s}", .{ sender, interface, member });
    const action_invoked: [:0]const u8 = "ActionInvoked";
    log.debug("Got: {s} -- expected: {s}", .{ std.mem.span(member), action_invoked });
    if (std.mem.eql(u8, std.mem.span(member), action_invoked)) {
        log.debug("(Handler) Action invoked", .{});
        var id: u32 = 0;
        var action: [*:0]const u8 = undefined;
        const res = dbus.c.dbus_message_get_args(message, null, dbus.c.DBUS_TYPE_UINT32, &id, dbus.c.DBUS_TYPE_STRING, &action, dbus.c.DBUS_TYPE_INVALID);
        if (res == dbus.FALSE) {
            log.err("Failed to get arguments from message", .{});
            return dbus.c.DBUS_HANDLER_RESULT_NEED_MEMORY;
        }
        log.debug("Action invoked: {} ({s})", .{ id, action });
        const span = std.mem.span(action);
        self.queue.push(Event{
            .tag = .action_invoked,
            .id = id,
            .data = .{
                .action = self.allocator.dupe(u8, span) catch "none",
            },
        }) catch |err| {
            log.err("Failed to push signal to queue: {any}", .{err});
        };
        return dbus.c.DBUS_HANDLER_RESULT_HANDLED;
    }
    if (std.mem.orderZ(u8, "org.freedesktop.DBus.Properties", interface) == .eq) {
        if (std.mem.orderZ(u8, "GetAll", member) == .eq) {
            const msg: *dbus.Message = @alignCast(@ptrCast(message orelse unreachable));
            log.debug("Message signature: {s}", .{msg.getSignature()});
            var iface_name_raw: [*:0]const u8 = undefined;
            const success = dbus.c.dbus_message_get_args(message, null, dbus.c.DBUS_TYPE_STRING, &iface_name_raw, dbus.c.DBUS_TYPE_INVALID);
            if (success != dbus.TRUE) {
                log.err("Failed to get arguments from message", .{});
                return dbus.c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
            }
            const iface_name = std.mem.span(iface_name_raw);

            log.debug("GetAll for interface: {s}", .{iface_name});
            var reply = msg.reply() catch |e| {
                log.err("Failed to create reply message: {any}", .{e});
                return dbus.c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
            };
            defer reply.deinit();

            self.status_notifier_item.marshallGetAll(msg, if (std.mem.indexOf(u8, iface_name, "org.kde.")) |_| .kde else .freedesktop) catch |e| {
                log.err("Failed to marshall GetAll message: {any}", .{e});
                return dbus.c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
            };
            defer self.serial += 1;
            self.session.send(reply, self.serial) catch |e| {
                log.err("Failed to send reply message: {any}", .{e});
                return dbus.c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
            };
            self.session.flush();
            log.debug("(Handler) Sent reply message", .{});
            return dbus.c.DBUS_HANDLER_RESULT_HANDLED;
        }
    }
    return dbus.c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
}

pub fn notify(self: *IPC, notification: Notification) !Notification.NotificationId {
    var err: dbus.Error = undefined;
    err.init();
    defer err.free();

    const msg = try dbus.Message.new(
        "org.freedesktop.Notifications",
        "/org/freedesktop/Notifications",
        "org.freedesktop.Notifications",
        "Notify",
    );

    defer msg.deinit();

    try notification.marshall(msg, self.app_name);

    const reply_raw = try self.session.sendWithReplyAndBlock(
        msg,
        dbus.DEFAULT_TIMEOUT,
        &err,
    );
    if (reply_raw == null) {
        log.err("Error: Failed to send message {?s}\n", .{std.mem.span(err.message)});
        return error.DBusError;
    }
    const reply = reply_raw.?;
    defer reply.deinit();

    return Notification.unmarshallId(reply);
}
