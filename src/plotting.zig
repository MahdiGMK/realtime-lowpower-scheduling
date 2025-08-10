const std = @import("std");

pub const zzplot = @import("zzplot");
pub const nvg = zzplot.nanovg;

pub const Figure = zzplot.Figure;
pub const Axes = zzplot.Axes;
pub const Plot = zzplot.Plot;

pub const c = @cImport({
    @cInclude("glad/glad.h");
    @cInclude("GLFW/glfw3.h");
});

pub const Aes = zzplot.PlotAes;
pub const Color = zzplot.Color;

pub fn simple(x: []const []f32, y: []const []f32, aes: []const Aes, x_lim: [2]f32, y_lim: [2]f32) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const shared = try zzplot.createShared();

    // nvg context creation goes after gladLoadGL
    const vg = try nvg.gl.init(allocator, .{
        .debug = true,
    });

    zzplot.Font.init(vg);
    // defer vg.deinit();  // DO NOT UNCOMMENT THIS LINE, WILL GIVE ERROR UPON EXIT

    const fig = try Figure.init(allocator, shared, vg, .{});
    const ax = try Axes.init(fig, .{});
    const plt = try Plot.init(ax, .{});

    ax.set_limits(x_lim, y_lim, .{});

    while (fig.live and 0 == c.glfwWindowShouldClose(@ptrCast(fig.window))) {
        fig.begin();

        ax.draw();
        ax.drawGrid();
        for (x, y, aes) |xx, yy, aaes| {
            plt.aes = aaes;
            plt.plot(xx, yy);
        }

        fig.end();
    }

    c.glfwTerminate();
}
pub fn rect(ax: *Axes, vg: nvg, x: f32, y: f32, w: f32, h: f32, color: nvg.Color) void {
    const space_xwid = ax.aes.xlim[1] - ax.aes.xlim[0];
    const space_ywid = ax.aes.ylim[1] - ax.aes.ylim[0];
    vg.save();
    vg.scissor(ax.xpos_axes_fb, ax.ypos_axes_fb - ax.ht_axes_fb, ax.wid_axes_fb, ax.ht_axes_fb);
    vg.beginPath();
    vg.rect(
        ax.xpos_axes_fb + (x - ax.aes.xlim[0]) / space_xwid * ax.wid_axes_fb,
        ax.ypos_axes_fb - (y - ax.aes.ylim[0]) / space_ywid * ax.ht_axes_fb,
        w * ax.wid_axes_fb / space_xwid,
        h * ax.ht_axes_fb / space_ywid,
    );
    vg.fillColor(color);
    vg.fill();
    vg.closePath();
}

pub fn complexSingle(ctx: *anyopaque, onDrawFunc: fn (*anyopaque, *Figure, *Axes, *Plot) void, x_lim: [2]f32, y_lim: [2]f32) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const shared = try zzplot.createShared();

    // nvg context creation goes after gladLoadGL
    const vg = try nvg.gl.init(allocator, .{
        .debug = true,
    });

    zzplot.Font.init(vg);
    // defer vg.deinit();  // DO NOT UNCOMMENT THIS LINE, WILL GIVE ERROR UPON EXIT

    const fig = try Figure.init(allocator, shared, vg, .{});
    const ax = try Axes.init(fig, .{});
    const plt = try Plot.init(ax, .{});

    ax.set_limits(x_lim, y_lim, .{});

    while (fig.live and 0 == c.glfwWindowShouldClose(@ptrCast(fig.window))) {
        fig.begin();

        onDrawFunc(ctx, fig, ax, plt);

        fig.end();
    }

    c.glfwTerminate();
}
