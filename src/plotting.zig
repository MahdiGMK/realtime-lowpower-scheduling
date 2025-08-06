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

pub fn simple(x: []const []f32, y: []const []f32, x_lim: [2]f32, y_lim: [2]f32) !void {
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
        for (x, y) |xx, yy| {
            plt.plot(xx, yy);
        }

        fig.end();
    }

    c.glfwTerminate();
}
