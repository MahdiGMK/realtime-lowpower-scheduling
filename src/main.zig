const std = @import("std");
const plotting = @import("plotting.zig");

const ArrayList = std.ArrayListUnmanaged;
const base = @import("base.zig");
const TaskDAG = base.TaskDAG;
const Platform = base.Platform;
const Processor = base.Processor;
const Task = base.Task;
const TEMP_AMBIANT = base.TEMP_AMBIANT;
const global = base.global;

const MAX_BW = 1e6;

const testing = struct {
    fn update(value: anytype, updated_terms: anytype) @TypeOf(value) {
        const T = @TypeOf(value);
        const flds: []const std.builtin.Type.StructField = std.meta.fields(T);
        var updated: T = value;
        inline for (flds) |fld| {
            if (@hasField(@TypeOf(updated_terms), fld.name))
                @field(updated, fld.name) = @field(updated_terms, fld.name);
        }
        return updated;
    }
    const testing_tasks = &.{
        Task{
            .id = 0,
            .per_proc = .{
                .{ .wcet = 2000, .steady_state_temp = 100 }, // p0
                .{ .wcet = 2000, .steady_state_temp = 100 }, // p1
                .{ .wcet = 2000, .steady_state_temp = 100 }, // p2
            },
        },
        Task{
            .id = 0,
            .per_proc = .{
                .{ .wcet = 800, .steady_state_temp = 300 }, // p0
                .{ .wcet = 800, .steady_state_temp = 300 }, // p1
                .{ .wcet = 900, .steady_state_temp = 300 }, // p2
            },
        },
    };
    const testing_task = testing_tasks[0];
    const testing_platform = Platform{ .processors = .{
        .{ .pid = 0, .temp_limit = 80, .thermo = .init(2.332, 13.1568, 0.1754, 0.68, 380, 2.6) },
        .{ .pid = 1, .temp_limit = 70, .thermo = .init(2.138, 5.0187, 0.1942, 0.487, 295, 3.4) },
        .{ .pid = 2, .temp_limit = 60, .thermo = .init(4.556, 15.6262, 0.1942, 0.238, 320, 3.0) },
    }, .communication_bw = .{
        .{ MAX_BW, 2, 2 },
        .{ 2, MAX_BW, 2 },
        .{ 2, 2, MAX_BW },
    }, .communication_lat = .{
        .{ 0, 0, 0 },
        .{ 0, 0, 0 },
        .{ 0, 0, 0 },
    } };

    fn makeTestDag() !TaskDAG {
        var dag = TaskDAG.init();
        try dag.appendNode(update(testing_tasks[0], .{ .id = 0 }));
        try dag.appendNode(update(testing_tasks[1], .{ .id = 1 }));
        try dag.appendNode(update(testing_tasks[0], .{ .id = 2 }));
        try dag.appendNode(update(testing_tasks[1], .{ .id = 3 }));
        try dag.appendNode(update(testing_tasks[0], .{ .id = 4 }));
        // try dag.appendNode(testing_task);
        try dag.connectNodes(0, 1, .{ .data_transfer = 100 });
        try dag.connectNodes(0, 2, .{ .data_transfer = 100 });
        try dag.connectNodes(1, 2, .{ .data_transfer = 1 });
        return dag;
    }

    test "tmds" {
        var platform = testing_platform;

        var dag = try makeTestDag();

        try @import("tmds.zig").schedule(&dag, &platform);

        for (dag.nodes.items, 0..) |node, id| {
            std.debug.print("{} == {}-{} on {}\n", .{
                id,
                node.data.actual_start_time.?,
                node.data.actual_finish_time.?,
                node.data.allocated_pid.?,
            });
        }
        _ = 0;
        try base.visualizeSchedule(dag, platform);
    }

    test "theft" {
        var platform = testing_platform;
        var dag = try makeTestDag();

        try @import("theft.zig").schedule(&dag, &platform);

        for (dag.nodes.items, 0..) |node, id| {
            std.debug.print("{} == {}-{} on {}\n", .{
                id,
                node.data.actual_start_time.?,
                node.data.actual_finish_time.?,
                node.data.allocated_pid.?,
            });
        }
        _ = 0;
        try base.visualizeSchedule(dag, platform);
    }

    test "tpeft" {
        var platform = testing_platform;
        var dag = try makeTestDag();

        try @import("tpeft.zig").schedule(&dag, &platform);

        for (dag.nodes.items, 0..) |node, id| {
            std.debug.print("{} == {}-{} on {}\n", .{
                id,
                node.data.actual_start_time.?,
                node.data.actual_finish_time.?,
                node.data.allocated_pid.?,
            });
        }
        _ = 0;
        try base.visualizeSchedule(dag, platform);
    }

    test "tppts" {
        var platform = testing_platform;
        var dag = try makeTestDag();

        try @import("tppts.zig").schedule(&dag, &platform);

        for (dag.nodes.items, 0..) |node, id| {
            std.debug.print("{} == {}-{} on {}\n", .{
                id,
                node.data.actual_start_time.?,
                node.data.actual_finish_time.?,
                node.data.allocated_pid.?,
            });
        }
        _ = 0;
        try base.visualizeSchedule(dag, platform);
    }

    test "tpsls" {
        var platform = testing_platform;
        var dag = try makeTestDag();

        try @import("tpsls.zig").schedule(&dag, &platform);

        for (dag.nodes.items, 0..) |node, id| {
            std.debug.print("{} == {}-{} on {}\n", .{
                id,
                node.data.actual_start_time.?,
                node.data.actual_finish_time.?,
                node.data.allocated_pid.?,
            });
        }
        _ = 0;
        try base.visualizeSchedule(dag, platform);
    }

    test "tods" {
        var platform = testing_platform;
        var dag = try makeTestDag();

        try @import("tods.zig").schedule(&dag, &platform);

        for (dag.nodes.items, 0..) |node, id| {
            std.debug.print("{} == {}-{} on {}\n", .{
                id,
                node.data.actual_start_time.?,
                node.data.actual_finish_time.?,
                node.data.allocated_pid.?,
            });
        }
        _ = 0;
        try base.visualizeSchedule(dag, platform);
    }

    test "gaussian-comparison" {}
};

test {
    _ = base;
    _ = testing;
}

pub fn main() !void {
    var prng = std.Random.DefaultPrng.init(0);
    const rnd = prng.random();

    const graph_layouts = .{
        TaskDAG.initGaussianElimination,
        TaskDAG.initLaplace,
    };
    const graph_layout_names = .{
        "GaussianElimination",
        "Laplace",
    };
    const sched_names = [_][]const u8{
        "tmds.zig",
        "theft.zig",
        "tods.zig",
        "tpeft.zig",
        "tppts.zig",
        "tpsls.zig",
    };
    const schedules = .{
        @import("tmds.zig").schedule,
        @import("theft.zig").schedule,
        @import("tods.zig").schedule,
        @import("tpeft.zig").schedule,
        @import("tppts.zig").schedule,
        @import("tpsls.zig").schedule,
    };

    var resultss: [2][100][sched_names.len]f32 = undefined;
    inline for (graph_layouts, &resultss) |initLayout, *results| {
        for (0..100) |i| {
            var task_dag = try initLayout(rnd.intRangeAtMost(u8, 3, 10));
            for (task_dag.nodes.items, 0..) |*nd, id| {
                nd.data = Task{
                    .id = id,
                    .per_proc = .{
                        .{
                            .wcet = rnd.float(f32) * 1000 + 500,
                            .steady_state_temp = rnd.float(f32) * 50 + 50,
                        },
                        .{
                            .wcet = rnd.float(f32) * 1000 + 500,
                            .steady_state_temp = rnd.float(f32) * 50 + 50,
                        },
                        .{
                            .wcet = rnd.float(f32) * 1000 + 500,
                            .steady_state_temp = rnd.float(f32) * 50 + 50,
                        },
                    },
                };
                for (nd.dependencies.items) |*ed|
                    ed.@"1" = base.TaskCommunication{ .data_transfer = rnd.float(f32) };
                for (nd.dependants.items) |*ed|
                    ed.@"1" = base.TaskCommunication{ .data_transfer = rnd.float(f32) };
            }
            var platform = Platform{
                .processors = .{
                    Processor{
                        .pid = 0,
                        .temp_limit = rnd.float(f32) * 30 + 50,
                        .thermo = .init(2.332, 13.1568, 0.1754, 0.68, 380, 2.6),
                    },
                    Processor{
                        .pid = 0,
                        .temp_limit = rnd.float(f32) * 30 + 50,
                        .thermo = .init(2.332, 13.1568, 0.1754, 0.68, 380, 2.6),
                    },
                    Processor{
                        .pid = 0,
                        .temp_limit = rnd.float(f32) * 30 + 50,
                        .thermo = .init(2.332, 13.1568, 0.1754, 0.68, 380, 2.6),
                    },
                },
                .communication_bw = .{
                    .{ MAX_BW, rnd.float(f32) + 2, rnd.float(f32) + 2 },
                    .{ rnd.float(f32) + 2, MAX_BW, rnd.float(f32) + 2 },
                    .{ rnd.float(f32) + 2, rnd.float(f32) + 2, MAX_BW },
                },
                .communication_lat = .{
                    .{ 0, rnd.float(f32), rnd.float(f32) },
                    .{ rnd.float(f32), 0, rnd.float(f32) },
                    .{ rnd.float(f32), rnd.float(f32), 0 },
                },
            };

            inline for (sched_names, schedules, 0..) |name, sched, ind| {
                std.debug.print("---sched--- : {} {s}\n", .{ i, name });
                base.resetSchedule(&task_dag, &platform);
                try sched(&task_dag, &platform);
                var makespan: f32 = 0;
                for (task_dag.nodes.items) |nd| makespan = @max(makespan, nd.data.actual_finish_time.?);
                results[i][ind] = makespan;
            }
        }
    }

    inline for (resultss, graph_layout_names) |results, layname| {
        std.debug.print("\n--- --- --- --- --- --- --- --- {s} RESULTS --- --- --- --- --- --- --- ---\n", .{layname});
        var wins: [6][6]usize = @splat(@splat(0));
        var ties: [6][6]usize = @splat(@splat(0));
        var loss: [6][6]usize = @splat(@splat(0));
        for (sched_names) |name| {
            std.debug.print("{s}\t", .{name});
        }
        std.debug.print("\n", .{});
        for (results) |row| {
            for (row) |val| {
                std.debug.print("{:0.4}\t", .{val});
            }
            std.debug.print("\n", .{});

            for (&wins, &ties, &loss, row) |*ws, *ts, *ls, r0| {
                for (ws, ts, ls, row) |*w, *t, *l, r1| {
                    if (r0 < r1 - 0.001) {
                        w.* += 1;
                    } else if (r0 > r1 + 0.001) {
                        l.* += 1;
                    } else {
                        t.* += 1;
                    }
                }
            }

            std.debug.print("\n--- --- --- --- --- --- --- --- {s} - WINS/TIES/LOSSES  --- --- --- --- --- --- --- ---\n", .{layname});
            std.debug.print("\t", .{});
            for (sched_names) |name| {
                std.debug.print("\t{s}", .{name});
            }
            std.debug.print("\n", .{});
            for (wins, ties, loss, sched_names) |ws, ts, ls, name| {
                std.debug.print("{s}\t", .{name});
                for (ws, ts, ls) |w, t, l| {
                    std.debug.print(" {}/{}/{} \t", .{ w, t, l });
                }
                std.debug.print("\n", .{});
            }
        }
    }
}
