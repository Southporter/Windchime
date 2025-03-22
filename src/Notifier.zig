const std = @import("std");

const log = std.log.scoped(.notifier);
const BoundedQueue = @import("./Queue.zig").BoundedQueue;

const Self = @This();
const dbus = @import("./dbus.zig");

inline fn makeOpaque(ptr: anytype) *const anyopaque {
    return @ptrCast(&ptr);
}

allocator: std.mem.Allocator,

session: *dbus.Connection,
err: dbus.Error,
app_name: [:0]const u8,
signal_queue: BoundedQueue(8, Signal) = .empty,
capabilities: Capabilities,

fn signalHandler(conn: ?*dbus.c.DBusConnection, message: ?*dbus.c.DBusMessage, user_data: ?*anyopaque) callconv(.C) dbus.c.DBusHandlerResult {
    _ = conn;
    const self: *Self = @alignCast(@ptrCast(user_data));

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
        self.signal_queue.push(Signal{
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
    return dbus.c.DBUS_HANDLER_RESULT_NOT_YET_HANDLED;
}

const match_rule = "type='signal',interface='org.freedesktop.Notifications'";
const action_invoked_match = "type='signal',interface='org.freedesktop.Notifications',member='ActionInvoked'";

pub fn init(self: *Self, allocator: std.mem.Allocator, session: *dbus.Connection) !void {
    self.signal_queue = .empty;
    self.allocator = allocator;
    const err_ptr: *dbus.Error = @ptrCast(&self.err);
    self.err.init();
    self.session = session;

    try session.addMatch(match_rule, err_ptr);
    errdefer session.removeMatch(match_rule);

    try session.addFilter(signalHandler, @ptrCast(self), null);
    self.capabilities = Capabilities{
        .tags = .initEmpty(),
        .vendor = @splat(@enumFromInt(0)),
        .interned = .empty,
    };
}

pub fn deinit(self: *Self) void {
    self.session.removeFilter(signalHandler, @ptrCast(self));
    self.session.removeMatch(match_rule);
    self.err.free();
    self.capabilities.interned.deinit(self.allocator);
}

const DispatchStatus = enum(u8) {
    data_remains = 0,
    complete = 1,
    need_memory = 2,
};

pub const Signal = struct {
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

pub fn dispatch(self: *Self) !?Signal {
    if (self.signal_queue.pop()) |signal| {
        log.debug("Returning a queued signal", .{});
        return signal;
    }
    const is_done = self.session.readWriteDispatch(1);
    if (is_done) {
        return error.NotifierDisconnected;
    }

    const message = self.session.popMessage();
    if (message == null) {
        return null;
    }
    const msg = message orelse unreachable;
    defer msg.deinit();

    if (msg.isKind(.signal)) {
        const sender = msg.getSender();
        const interface = msg.getInterface();
        const expected_interface: [:0]const u8 = "org.freedesktop.Notifications";
        const member = msg.getMember();
        log.debug("(DISPATCH) Received signal from {s} on interface {s} with member {s}", .{ sender, interface, member });
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
            return Signal{
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
            return Signal{
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
            return Signal{
                .tag = .activation_token,
                .id = id,
                .data = .{
                    .activation_token = try self.allocator.dupeZ(u8, span),
                },
            };
        }
    }
    return null;
}

pub const NotificationId = enum(u32) {
    _,
};

pub const Notification = struct {
    summary: [:0]const u8,
    body: [:0]const u8,
    actions: []const [*]const u8,
};

pub const Urgency = enum(u8) {
    low = 0,
    normal = 1,
    critical = 2,
};

pub fn notify(self: *Self, notification: Notification, urgency: Urgency) !NotificationId {
    const err_ptr: *dbus.Error = @ptrCast(&self.err);
    errdefer err_ptr.free();

    const msg = try dbus.Message.new(
        "org.freedesktop.Notifications",
        "/org/freedesktop/Notifications",
        "org.freedesktop.Notifications",
        "Notify",
    );

    defer msg.deinit();

    try self.marshall(msg, notification, urgency);

    const reply_raw = try self.session.sendWithReplyAndBlock(
        msg,
        dbus.DEFAULT_TIMEOUT,
        err_ptr,
    );
    if (reply_raw == null) {
        std.debug.print("Error: Failed to send message {?s}\n", .{std.mem.span(self.err.message)});
        return error.DBusError;
    }
    const reply = reply_raw.?;
    defer reply.deinit();

    var id_res: dbus.c.DBusBasicValue = undefined;
    const success = dbus.c.dbus_message_get_args(@ptrCast(reply), null, dbus.c.DBUS_TYPE_UINT32, &id_res, dbus.c.DBUS_TYPE_INVALID);
    if (success != dbus.TRUE) {
        std.debug.print("Failed to get arguments: {}\n", .{success});
        return error.FailedUnmarshalNotificationID;
    } else {
        std.debug.print("Notification ID: {}\n", .{id_res.u32});
        return @enumFromInt(id_res.u32);
    }
}

fn marshall(self: *Self, msg: *dbus.Message, notification: Notification, urgency: Urgency) !void {
    var iter: dbus.Message.Iter = undefined;
    iter.initAppend(msg);

    const empty_str: [:0]const u8 = "";
    try iter.appendBasic([:0]const u8, self.app_name);
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
                try variant_iter.appendBasic(u8, @intFromEnum(urgency));
                try hint_iter.closeContainer(&variant_iter);
            }
            try hints_iter.closeContainer(&hint_iter);
        }
        try iter.closeContainer(&hints_iter);
    }

    return iter.appendBasic(i32, -1);
}

const Capability = enum(u16) {
    @"action-icons" = 16,
    actions,
    body,
    @"body-hyperlinks",
    @"body-markup",
    @"icon-multi",
    @"icon-static",
    presistence,
    sound,
    _,
};

const Capabilities = struct {
    tags: std.EnumSet(Capability),
    vendor: [16]NameIndex,
    interned: std.ArrayListUnmanaged(u8),

    const NameIndex = enum(u32) {
        _,
    };

    pub fn addCapability(self: *Capabilities, allocator: std.mem.Allocator, name: []const u8) !void {
        var known: ?u32 = null;
        for (@intFromEnum(Capability.@"action-icons")..@intFromEnum(Capability.sound)) |i| {
            const e: Capability = @enumFromInt(i);
            if (std.mem.eql(u8, name, @tagName(e))) {
                known = @truncate(i);
                break;
            }
        }
        if (known) |i| {
            const cap: Capability = @enumFromInt(i);
            self.tags.insert(cap);
        } else {
            var i: u32 = 0;
            while (self.tags.contains(@enumFromInt(i))) : (i += 1) {}
            if (i >= self.vendor.len) {
                return error.VendorCapabilitiesFull;
            }
            self.tags.insert(@enumFromInt(i));
            const start = self.interned.items.len;
            try self.interned.appendSlice(allocator, name);
            try self.interned.append(allocator, 0);
            self.vendor[i] = @enumFromInt(start);
        }
    }
};

pub fn getCapabilities(self: *Self) !void {
    const err_ptr: *dbus.Error = @ptrCast(&self.err);
    errdefer err_ptr.free();

    errdefer self.capabilities.interned.deinit(self.allocator);

    const msg = try dbus.Message.new(
        "org.freedesktop.Notifications",
        "/org/freedesktop/Notifications",
        "org.freedesktop.Notifications",
        "GetCapabilities",
    );

    defer msg.deinit();

    const reply_raw = try self.session.sendWithReplyAndBlock(
        msg,
        dbus.DEFAULT_TIMEOUT,
        err_ptr,
    );

    if (reply_raw == null) {
        std.debug.print("Error: Failed to send message {?s}\n", .{std.mem.span(self.err.message)});
        return error.DBusError;
    }
    const reply = reply_raw orelse unreachable;
    defer reply.deinit();

    var cap_iter: dbus.Message.Iter = undefined;
    try cap_iter.init(reply);
    var cap_item: dbus.Message.Iter = undefined;
    cap_iter.recurse(&cap_item);

    while (cap_item.next()) |cap| {
        std.debug.assert(cap.kind == .string);
        const name = std.mem.span(cap.value.str);
        log.info("Got capability: {s}", .{name});
        const trimmed: []const u8 = name[0 .. name.len - 1];
        try self.capabilities.addCapability(self.allocator, trimmed);
    }
}
