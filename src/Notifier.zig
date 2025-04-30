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
