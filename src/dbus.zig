pub const std = @import("std");
pub const log = std.log.scoped(.dbus);
pub const c = @cImport({
    @cInclude("dbus/dbus.h");
});

pub const FALSE = c.FALSE;
pub const TRUE = c.TRUE;
pub const DEFAULT_TIMEOUT = c.DBUS_TIMEOUT_USE_DEFAULT;

pub const BusKind = enum {
    session,
    system,
};
pub const Error = extern struct {
    name: [*c]const u8,
    message: [*c]const u8,
    dummy1: c_uint,
    // dummy2: c_uint,
    // dummy3: c_uint,
    // dummy4: c_uint,
    // dummy5: c_uint,
    padding1: *opaque {},

    pub fn init(self: *Error) void {
        c.dbus_error_init(@ptrCast(self));
    }

    pub fn free(self: *Error) void {
        c.dbus_error_free(@ptrCast(self));
    }

    pub fn isSet(self: *Error) bool {
        return c.dbus_error_is_set(@ptrCast(self)) == TRUE;
    }
};

pub const DBusObject = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = extern struct {
        unregister_function: c.DBusObjectPathUnregisterFunction,
        message_function: c.DBusObjectPathMessageFunction,
        dbus_internal_pad1: ?*opaque {} = null,
        dbus_internal_pad2: ?*opaque {} = null,
        dbus_internal_pad3: ?*opaque {} = null,
        dbus_internal_pad4: ?*opaque {} = null,
    };
};

pub const Connection = opaque {
    pub fn connect(bus_kind: BusKind, err: ?*Error) error{DBusConnectionFailed}!*Connection {
        const c_err: *c.DBusError = @ptrCast(err);
        c.dbus_error_init(c_err);
        const connection = c.dbus_bus_get(switch (bus_kind) {
            BusKind.session => c.DBUS_BUS_SESSION,
            BusKind.system => c.DBUS_BUS_SYSTEM,
        }, c_err);
        if (c.dbus_error_is_set(c_err) == TRUE) {
            return error.DBusConnectionFailed;
        }
        const conn = connection orelse return error.DBusConnectionFailed;
        return @ptrCast(conn);
    }

    pub fn close(self: *Connection) !void {
        c.dbus_connection_unref(@ptrCast(self));
    }

    pub fn addMatch(self: *Connection, match_rule: [:0]const u8, err: ?*Error) !void {
        const dbus_error: *c.DBusError = @ptrCast(err);
        c.dbus_bus_add_match(@ptrCast(self), match_rule.ptr, @ptrCast(dbus_error));
        if (c.dbus_error_is_set(dbus_error) == TRUE) {
            return error.DBusMatchError;
        }
    }

    pub fn removeMatch(self: *Connection, match_rule: [:0]const u8) void {
        c.dbus_bus_remove_match(@ptrCast(self), match_rule.ptr, null);
    }

    pub const FilterFunc = fn (connection: *c.DBusConnection, message: ?*c.DBusMessage, user_data: ?*anyopaque) callconv(.C) c.DBusHandlerResult;

    pub fn addFilter(self: *Connection, filter_func: FilterFunc, user_data: ?*anyopaque, free_func: ?*const fn (?*anyopaque) callconv(.c) void) !void {
        const res = c.dbus_connection_add_filter(@ptrCast(self), filter_func, user_data, free_func);
        // if (c.dbus_error_is_set(dbus_error) == TRUE) {
        //     return error.DBusFilterError;
        // }
        return checkMemoryError(res);
    }

    pub fn removeFilter(self: *Connection, filter_func: FilterFunc, user_data: ?*anyopaque) void {
        return c.dbus_connection_remove_filter(@ptrCast(self), filter_func, user_data);
    }

    pub fn readWriteDispatch(self: *Connection, timeout: i32) bool {
        const res = c.dbus_connection_read_write_dispatch(@ptrCast(self), timeout);
        return res != c.TRUE;
    }

    pub fn popMessage(self: *Connection) ?*Message {
        const msg = c.dbus_connection_pop_message(@ptrCast(self));
        return @ptrCast(msg);
    }

    pub fn send(self: *Connection, message: *Message, id: u32) !void {
        var serial: c_uint = @intCast(id);
        const res = c.dbus_connection_send(@ptrCast(self), @ptrCast(message), @ptrCast(&serial));
        return checkMemoryError(res);
    }

    pub fn sendWithReplyAndBlock(self: *Connection, message: *Message, timeout: i32, err: ?*Error) !?*Message {
        const dbus_error: *c.DBusError = @ptrCast(err);
        const res = c.dbus_connection_send_with_reply_and_block(@ptrCast(self), @ptrCast(message), timeout, dbus_error);
        if (c.dbus_error_is_set(dbus_error) == TRUE) {
            const msg = std.mem.span(err.?.message);
            log.err("Send error: {s}", .{msg});

            return error.DBusSendError;
        }
        return @ptrCast(res);
    }

    pub fn flush(self: *Connection) void {
        c.dbus_connection_flush(@ptrCast(self));
    }

    pub fn registerObject(self: *Connection, path: [:0]const u8, object: DBusObject) !void {
        const res = c.dbus_connection_register_object_path(@ptrCast(self), path, @ptrCast(object.vtable), object.ptr);
        if (res == c.FALSE) {
            return error.DBusRegisterObjectError;
        }
    }

    pub fn unregisterObject(self: *Connection, path: [:0]const u8) !void {
        const res = c.dbus_connection_unregister_object_path(@ptrCast(self), path);
        if (res == c.FALSE) {
            return error.DBusUnregisterObjectError;
        }
    }

    pub const RequestNameResult = enum(c_int) {
        err = -1,
        primary_owner = c.DBUS_REQUEST_NAME_REPLY_PRIMARY_OWNER,
        in_queue = c.DBUS_REQUEST_NAME_REPLY_IN_QUEUE,
        exists = c.DBUS_REQUEST_NAME_REPLY_EXISTS,
        denied = c.DBUS_REQUEST_NAME_REPLY_ALREADY_OWNER,
    };
    pub const RequestNameFlags = packed struct(c_uint) {
        allow_replacement: bool = false,
        replace_existing: bool = false,
        do_not_queue: bool = false,
        _: u29 = 0,
    };

    pub fn requestName(self: *Connection, name: [:0]const u8, flags: RequestNameFlags, err: ?*Error) !RequestNameResult {
        return @enumFromInt(c.dbus_bus_request_name(@ptrCast(self), name.ptr, @bitCast(flags), @ptrCast(err)));
    }

    pub const ReleaseNameResult = enum(c_int) {
        err = -1,
        released = c.DBUS_RELEASE_NAME_REPLY_RELEASED,
        not_owner = c.DBUS_RELEASE_NAME_REPLY_NOT_OWNER,
        non_existent = c.DBUS_RELEASE_NAME_REPLY_NON_EXISTENT,
    };

    pub fn releaseName(self: *Connection, name: [:0]const u8, err: ?*Error) ReleaseNameResult {
        const res = c.dbus_bus_release_name(@ptrCast(self), name.ptr, @ptrCast(err));
        return @enumFromInt(res);
    }
};

pub inline fn checkMemoryError(code: c_uint) !void {
    if (code == c.FALSE) {
        return error.OutOfMemory;
    }
}

pub const ArgKind = enum(c_int) {
    byte = c.DBUS_TYPE_BYTE,
    boolean = c.DBUS_TYPE_BOOLEAN,
    int16 = c.DBUS_TYPE_INT16,
    uint16 = c.DBUS_TYPE_UINT16,
    int32 = c.DBUS_TYPE_INT32,
    uint32 = c.DBUS_TYPE_UINT32,
    int64 = c.DBUS_TYPE_INT64,
    uint64 = c.DBUS_TYPE_UINT64,
    double = c.DBUS_TYPE_DOUBLE,
    string = c.DBUS_TYPE_STRING,
    object_path = c.DBUS_TYPE_OBJECT_PATH,
    signature = c.DBUS_TYPE_SIGNATURE,
    variant = c.DBUS_TYPE_VARIANT,
    array = c.DBUS_TYPE_ARRAY,
    dict_entry = c.DBUS_TYPE_DICT_ENTRY,
};

pub const Message = opaque {
    pub fn new(destination: [:0]const u8, path: [:0]const u8, interface: [:0]const u8, method: [:0]const u8) !*Message {
        const msg = c.dbus_message_new_method_call(destination.ptr, path.ptr, interface.ptr, method.ptr);
        if (msg) |m| {
            return @ptrCast(m);
        } else {
            return error.OutOfMemory;
        }
    }

    pub fn deinit(self: *Message) void {
        c.dbus_message_unref(@ptrCast(self));
    }

    pub fn reply(call: *Message) !*Message {
        const msg = c.dbus_message_new_method_return(@ptrCast(call));
        if (msg) |m| {
            return @ptrCast(m);
        } else {
            return error.OutOfMemory;
        }
    }

    pub fn getSender(self: *Message) [*c]const u8 {
        return c.dbus_message_get_sender(@ptrCast(self));
    }

    pub fn getInterface(self: *Message) [*c]const u8 {
        return c.dbus_message_get_interface(@ptrCast(self));
    }

    pub fn getMember(self: *Message) [*c]const u8 {
        return c.dbus_message_get_member(@ptrCast(self));
    }

    pub fn getSignature(self: *Message) [*c]const u8 {
        return c.dbus_message_get_signature(@ptrCast(self));
    }

    pub const Kind = enum(c_int) {
        method_call = c.DBUS_MESSAGE_TYPE_METHOD_CALL,
        method_return = c.DBUS_MESSAGE_TYPE_METHOD_RETURN,
        err = c.DBUS_MESSAGE_TYPE_ERROR,
        signal = c.DBUS_MESSAGE_TYPE_SIGNAL,
    };

    pub fn isKind(self: *Message, msg_type: Kind) bool {
        return c.dbus_message_get_type(@ptrCast(self)) == @intFromEnum(msg_type);
    }
    pub fn getType(self: *Message) Kind {
        return @enumFromInt(c.dbus_message_get_type(@ptrCast(self)));
    }

    pub const Iter = struct {
        inner: c.DBusMessageIter,

        pub fn init(self: *Iter, message: *Message) !void {
            const res = c.dbus_message_iter_init(@ptrCast(message), @ptrCast(self));
            if (res == FALSE) {
                return error.DBusMessageNoArgs;
            }
        }

        pub fn initAppend(
            iter: *Iter,
            message: *Message,
        ) void {
            return c.dbus_message_iter_init_append(@ptrCast(message), @ptrCast(iter));
        }

        pub const Value = struct {
            kind: ArgKind,
            value: c.DBusBasicValue,
        };

        pub fn next(iter: *Iter) ?Value {
            var val: c.DBusBasicValue = undefined;

            const kind = iter.getArgType();
            const res = c.dbus_message_iter_next(@ptrCast(iter)) != 0;
            if (!res) {
                return null;
            }

            iter.getBasic(&val);
            return .{
                .kind = kind,
                .value = val,
            };
        }

        pub fn getBasic(iter: *Iter, out: *c.DBusBasicValue) void {
            return c.dbus_message_iter_get_basic(@ptrCast(iter), out);
        }

        pub fn appendBasic(iter: *Iter, comptime T: type, value: T) !void {
            const i: *c.DBusMessageIter = @ptrCast(iter);
            const val: ?*const anyopaque = @ptrCast(&value);
            const info = @typeInfo(T);
            return switch (info) {
                .bool => checkMemoryError(c.dbus_message_iter_append_basic(i, c.DBUS_TYPE_BOOLEAN, if (value) &c.TRUE else &c.FALSE)),
                .int => |I| switch (I.signedness) {
                    .unsigned => switch (I.bits) {
                        0...8 => checkMemoryError(c.dbus_message_iter_append_basic(i, c.DBUS_TYPE_BYTE, val)),
                        9...16 => checkMemoryError(c.dbus_message_iter_append_basic(i, c.DBUS_TYPE_UINT16, val)),
                        17...32 => checkMemoryError(c.dbus_message_iter_append_basic(i, c.DBUS_TYPE_UINT32, val)),
                        33...64 => checkMemoryError(c.dbus_message_iter_append_basic(i, c.DBUS_TYPE_UINT64, val)),
                        else => @compileError("Unsupported Integer type for dbus message iteration"),
                    },
                    .signed => switch (I.bits) {
                        0...8 => checkMemoryError(c.dbus_message_iter_append_basic(i, c.DBUS_TYPE_BYTE, val)),
                        9...16 => checkMemoryError(c.dbus_message_iter_append_basic(i, c.DBUS_TYPE_INT16, val)),
                        17...32 => checkMemoryError(c.dbus_message_iter_append_basic(i, c.DBUS_TYPE_INT32, val)),
                        33...64 => checkMemoryError(c.dbus_message_iter_append_basic(i, c.DBUS_TYPE_INT64, val)),
                        else => @compileError("Unsupported Integer type for dbus message iteration"),
                    },
                },
                .pointer => |P| switch (P.size) {
                    .slice => switch (@typeInfo(P.child)) {
                        .int => |I| switch (I.bits) {
                            8 => checkMemoryError(c.dbus_message_iter_append_basic(i, c.DBUS_TYPE_STRING, @ptrCast(&value.ptr))),
                            else => @compileError("Unsupported slice of Integers type for dbus message iteration"),
                        },
                        else => @compileError("Unsupported Pointer Slice type for dbus message iteration"),
                    },
                    .many => switch (@typeInfo(P.child)) {
                        .int => |I| switch (I.bits) {
                            8 => checkMemoryError(c.dbus_message_iter_append_basic(i, c.DBUS_TYPE_STRING, val)),
                            else => @compileError("Unsupported many pointre of Integers type for dbus message iteration"),
                        },
                        else => @compileError("Unsupported Pointer Slice type for dbus message iteration"),
                    },
                    else => @compileError("Unsupported Pointer type for dbus message iteration"),
                },
                else => @compileError("Unsupported type for dbus message iteration"),
            };
        }

        pub fn appendFixedArray(iter: *Iter, comptime T: type, array: [*]const T, len: usize) !void {
            const i: *c.DBusMessageIter = @ptrCast(iter);
            const size: c_int = @intCast(len);
            return switch (@typeInfo(T)) {
                .int => |I| switch (I.bits) {
                    0...8 => checkMemoryError(c.dbus_message_iter_append_fixed_array(i, c.DBUS_TYPE_BYTE, @ptrCast(&array), size)),
                    9...16 => checkMemoryError(c.dbus_message_iter_append_fixed_array(i, c.DBUS_TYPE_UINT16, @ptrCast(&array), size)),
                    17...32 => checkMemoryError(c.dbus_message_iter_append_fixed_array(i, c.DBUS_TYPE_UINT32, @ptrCast(&array), size)),
                    33...64 => checkMemoryError(c.dbus_message_iter_append_fixed_array(i, c.DBUS_TYPE_UINT64, @ptrCast(&array), size)),
                    else => @compileError("Unsupported Integer type for appending fixed array to dbus message iteration"),
                },
                else => @compileError("Unsupported type for appending fixed array to dbus message iteration"),
            };
        }

        pub const ContainerKind = enum(c_int) {
            array = c.DBUS_TYPE_ARRAY,
            dict_entry = c.DBUS_TYPE_DICT_ENTRY,
            variant = c.DBUS_TYPE_VARIANT,
            @"struct" = c.DBUS_TYPE_STRUCT,
        };

        pub fn openContainer(iter: *Iter, kind: ContainerKind, signature: ?[:0]const u8, child: *Iter) !void {
            return checkMemoryError(c.dbus_message_iter_open_container(@ptrCast(iter), @intFromEnum(kind), if (signature) |s| s.ptr else null, @ptrCast(child)));
        }

        pub fn abandonContainer(iter: *Iter, child: *Iter) void {
            c.dbus_message_iter_abandon_container(@ptrCast(iter), @ptrCast(child));
        }

        pub fn closeContainer(iter: *Iter, child: *Iter) !void {
            return checkMemoryError(c.dbus_message_iter_close_container(@ptrCast(iter), @ptrCast(child)));
        }

        pub fn recurse(iter: *Iter, child: *Iter) void {
            c.dbus_message_iter_recurse(@ptrCast(iter), @ptrCast(child));
        }

        pub fn getArgType(iter: *Iter) ArgKind {
            return @enumFromInt(c.dbus_message_iter_get_arg_type(@ptrCast(iter)));
        }
    };
};
