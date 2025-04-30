const mini = @cImport({
    @cInclude("miniaudio.h");
});

pub const Context = struct {
    engine: mini.ma_engine,
};

pub fn init() !Context {
    var engine: mini.ma_engine = undefined;
    const result = mini.ma_engine_init(null, &engine);
    if (result != mini.MA_SUCCESS) {
        return error.SoundInitFailed;
    }

    return .{
        .engine = engine,
    };
}

pub fn play(ctx: *Context, path: [:0]const u8) !void {
    mini.ma_engine_play_sound(&ctx.engine, path.ptr, null);
}

pub fn deinit(ctx: *Context) void {
    mini.ma_engine_uninit(&ctx.engine);
}
