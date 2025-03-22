pub fn BoundedQueue(size: usize, comptime Type: type) type {
    return struct {
        const Self = @This();
        items: [size]Type,
        head: usize = 0,
        tail: usize = 0,
        count: usize = 0,

        pub const empty = Self{
            .items = undefined,
            .head = 0,
            .tail = 0,
            .count = 0,
        };

        pub fn push(self: *Self, item: Type) !void {
            if (self.count == self.items.len) {
                return error.QueueFull;
            }
            self.items[self.tail] = item;
            self.tail = (self.tail + 1) % self.items.len;
            self.count += 1;
        }

        pub fn pop(self: *Self) ?Type {
            if (self.count == 0) {
                return null;
            }
            const item = self.items[self.head];
            self.head = (self.head + 1) % self.items.len;
            self.count -= 1;
            return item;
        }
    };
}
