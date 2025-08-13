const std = @import("std");
const plotting = @import("plotting.zig");

const global = struct {
    var gpa = std.heap.DebugAllocator(.{}).init;
    const alloc = gpa.allocator();
};
const Processor = struct {
    pid: u8,
    temp_limit: f32,
    temp_cutoff: f32,
    power_mode_switching_time: f32 = 0.000_001 * 80, // 80us according to the paper
    avail: f32 = 0,
    temp_cur: f32 = TEMP_AMBIANT,
    thermo: struct {
        a: f32,
        b: f32,
        c0: f32,
        c1: f32,
        c2: f32,
        f: f32,
        fn init(c0: f32, c1: f32, c2: f32, r: f32, c: f32, f: f32) @This() {
            return .{ .a = 1.0 / c, .b = 1.0 / c / r, .c0 = c0, .c1 = c1, .c2 = c2, .f = f };
        }
    }, // all the properties
    fn thermB(self: *const Processor) f32 {
        return self.thermo.b - self.thermo.a * self.thermo.c2 * self.thermo.f;
    }
};
const TEMP_AMBIANT = 25;
const Platform = struct {
    const NPROC = 3;
    processors: [NPROC]Processor,
    communication_bw: [NPROC][NPROC]f32,
};
const Task = struct {
    id: usize,
    per_proc: [Platform.NPROC]struct { wcet: f32, steady_state_temp: f32, optimistic_finish_time: ?f32 = null },
    allocated_pid: ?u8 = null,
    actual_start_time: ?f32 = null,
    actual_finish_time: ?f32 = null,
};
const TaskCommunication = struct {
    data_transfer: f32,
};

fn DAG(comptime NodeData: type, comptime EdgeData: type) type {
    return struct {
        const Graph = @This();
        pub const Node = struct {
            data: NodeData,
            solved_deps: usize = 0,
            dependencies: std.ArrayList(struct { *Node, EdgeData }),
            dependants: std.ArrayList(struct { *Node, EdgeData }),
            const Nd = @This();
            fn init(data: NodeData) Nd {
                return Nd{
                    .data = data,
                    .dependencies = .init(global.alloc),
                    .dependants = .init(global.alloc),
                };
            }
        };
        nodes: std.ArrayList(Node),
        fn init() Graph {
            return Graph{ .nodes = .init(global.alloc) };
        }
        fn appendNode(self: *Graph, data: NodeData) !void {
            try self.nodes.append(Node.init(data));
        }
        fn connectNodes(self: *Graph, dependency: usize, dependant: usize, edge: EdgeData) !void {
            const dency = @constCast(&self.nodes.items[dependency]);
            const dant = @constCast(&self.nodes.items[dependant]);
            try dant.dependencies.append(.{ dency, edge });
            try dency.dependants.append(.{ dant, edge });
        }
    };
}

const TaskDAG = DAG(Task, TaskCommunication);

fn optimisticFinishTime(n: *TaskDAG.Node, platform: Platform, p: Processor) f32 {
    if (n.data.per_proc[p.pid].optimistic_finish_time) |oft| return oft;
    if (n.dependants.items.len == 0) return n.data.per_proc[p.pid].wcet;

    var res: f32 = 0;
    for (n.dependants.items) |it| {
        const nn, const e = it;
        var rs = std.math.inf(f32);
        for (platform.processors) |np| {
            rs = @min(
                rs,
                optimisticFinishTime(nn, platform, np) +
                    e.data_transfer / platform.communication_bw[p.pid][np.pid],
            );
        }
        res = @max(res, rs);
    }

    n.data.per_proc[p.pid].optimistic_finish_time = res + n.data.per_proc[p.pid].wcet;
    return n.data.per_proc[p.pid].optimistic_finish_time.?;
}

fn taskRank(n: *TaskDAG.Node, platform: Platform) f32 {
    var res: f32 = 0;
    for (platform.processors) |p| {
        res += optimisticFinishTime(n, platform, p);
    }
    return res / Platform.NPROC;
}

fn effectiveStartTime(n: *const TaskDAG.Node, platform: Platform, p: Processor) f32 { // OK
    var dep: f32 = 0;
    for (n.dependencies.items) |it| {
        const pn, const e = it;
        if (pn.data.actual_finish_time) |aft| {
            dep = @max(
                dep,
                aft + e.data_transfer / platform.communication_bw[pn.data.allocated_pid.?][p.pid],
            );
        } else return std.math.inf(f32);
    }
    return @max(p.avail, dep);
}

fn maximumDurationOfContExecution(t: Task, p: Processor, temp_ini: f32) f32 { // OK
    const temp_steady = t.per_proc[p.pid].steady_state_temp;
    if (temp_ini > p.temp_limit) return 0;
    if (temp_steady < p.temp_limit) {
        return std.math.inf(f32);
    }
    const res: f32 = -1.0 / p.thermB() * @log((p.temp_limit - temp_steady) / (temp_ini - temp_steady));
    // std.debug.print("{} {} {} {} => {}\n", .{ p.thermB(), p.temp_limit, temp_steady, temp_ini, res });
    return res;
}

fn coolingTime(p: Processor, temp_fin: f32, temp_ini: f32) f32 { // OK
    return -1.0 / p.thermB() * @log((temp_fin - TEMP_AMBIANT) / (temp_ini - TEMP_AMBIANT));
}

fn heatingTemp(p: Processor, temp_fin: f32, temp_ini: f32, duration: f32) f32 { // OK
    return temp_fin + (temp_ini - temp_fin) * @exp(-p.thermB() * duration);
}

fn coolingTemp(p: Processor, temp_ini: f32, duration: f32) f32 { // OK
    return heatingTemp(p, TEMP_AMBIANT, temp_ini, duration);
}

fn numberOfCoollingIntervals(t: Task, p: Processor, temp_est: f32) usize { // OK
    const wcet = t.per_proc[p.pid].wcet;
    const first_cycle = maximumDurationOfContExecution(t, p, temp_est);
    if (first_cycle >= wcet) return 0;

    const after_first = wcet - first_cycle;
    const run_cycle_dur = maximumDurationOfContExecution(t, p, p.temp_cutoff);
    const res = after_first / run_cycle_dur;
    return @intFromFloat(@floor(res) + 1);
}

fn maxTempAllowedContExec(t: Task, p: Processor, rem_exec_time: f32) f32 { // OK
    if (t.per_proc[p.pid].steady_state_temp < p.temp_limit)
        return p.temp_limit;
    return t.per_proc[p.pid].steady_state_temp +
        (p.temp_limit - t.per_proc[p.pid].steady_state_temp) /
            @exp(-p.thermB() * rem_exec_time);
}

fn tett(t: Task, p: Processor, cur_time: f32, temp_ini: f32) struct { fin_t: f32, fin_temp: f32 } {
    var allowed_exec_time = maximumDurationOfContExecution(t, p, temp_ini);
    const wcet = t.per_proc[p.pid].wcet;
    const tss = t.per_proc[p.pid].steady_state_temp;
    if (wcet <= allowed_exec_time) return .{
        .fin_t = cur_time + wcet,
        .fin_temp = heatingTemp(p, tss, temp_ini, wcet),
    };
    var rem_exec_time = wcet - allowed_exec_time;
    var cur_t = cur_time + allowed_exec_time;
    const idle_t = coolingTime(p, p.temp_cutoff, p.temp_limit);
    allowed_exec_time = maximumDurationOfContExecution(t, p, p.temp_cutoff);

    while (rem_exec_time > 0) {
        if (rem_exec_time >= allowed_exec_time) {
            cur_t += idle_t + allowed_exec_time + 2 * p.power_mode_switching_time; // could be optimized
        } else {
            cur_t += coolingTime(
                p,
                maxTempAllowedContExec(t, p, rem_exec_time),
                p.temp_limit,
            ) + rem_exec_time + 2 * p.power_mode_switching_time;
        }
        rem_exec_time -= allowed_exec_time;
    }
    return .{ .fin_t = cur_t, .fin_temp = p.temp_limit };
}

fn tmds(dag: *TaskDAG, platform: *Platform) !void {
    var task_list = std.ArrayList(*TaskDAG.Node).init(global.alloc);
    for (dag.nodes.items) |*nd|
        if (nd.dependencies.items.len == 0)
            try task_list.append(nd);
    // task_list == sources(graph)

    while (task_list.items.len > 0) {
        const task = extract_best_task: {
            var tsk: *TaskDAG.Node = undefined;
            var idx: usize = undefined;
            var rnk: f32 = 0;
            for (task_list.items, 0..) |t, i| {
                const r = taskRank(t, platform.*);
                if (rnk <= r) {
                    rnk = r;
                    idx = i;
                    tsk = t;
                }
            }
            _ = task_list.swapRemove(idx);
            break :extract_best_task tsk;
        };
        std.log.info("selected task : {}\n", .{task.data.id});
        var optproc: u8 = undefined;
        var opttemp: f32 = undefined;
        var optstrt: f32 = undefined;
        var optfin: f32 = undefined;
        var optcompl = std.math.inf(f32);
        for (platform.processors) |proc| {
            std.log.info("--checking proc{}\n", .{proc.pid});
            const sttime = effectiveStartTime(task, platform.*, proc);
            std.log.info("  --start-time : {}\n", .{sttime});
            const temp_estim = coolingTemp(proc, proc.temp_cur, sttime - proc.avail);
            std.log.info("  --start-temp : {}\n", .{temp_estim});
            const estim = tett(task.data, proc, sttime, temp_estim);
            std.log.info("  --end-temp : {}\n", .{estim.fin_temp});
            std.log.info("  --end-time : {}\n", .{estim.fin_t});

            const optimistic_dependant_completion =
                optimisticFinishTime(task, platform.*, proc) -
                task.data.per_proc[proc.pid].wcet;
            const schedule_compl_time = estim.fin_t + optimistic_dependant_completion;
            std.log.info("  --++dep-compl : {}\n", .{optimistic_dependant_completion});
            std.log.info("  --++final-heuristic : {}\n", .{schedule_compl_time});
            if (optcompl > schedule_compl_time) {
                optcompl = schedule_compl_time;
                opttemp = estim.fin_temp;
                optstrt = sttime;
                optfin = estim.fin_t;
                optproc = proc.pid;
            }
        }
        task.data.allocated_pid = optproc;
        task.data.actual_start_time = optstrt;
        task.data.actual_finish_time = optfin;
        platform.processors[optproc].avail = optfin;
        platform.processors[optproc].temp_cur = opttemp;

        for (task.dependants.items) |it| {
            const nd, _ = it;
            nd.solved_deps += 1;
            if (nd.solved_deps == nd.dependencies.items.len) {
                try task_list.append(nd);
            }
        }
    }
}

const Simulation = struct {
    const Event = struct {
        time: f32,
        task_id: ?usize,
    };

    event_lists: [Platform.NPROC]std.ArrayList(Event),
};
fn simulateScheduleByTETT(dag: TaskDAG, platform: Platform) !Simulation {
    var sim = Simulation{ .event_lists = undefined };
    for (&sim.event_lists) |*e| {
        e.* = try .initCapacity(global.alloc, 2);
        try e.append(.{ .task_id = null, .time = -2 });
        try e.append(.{ .task_id = null, .time = -1 });
    }

    var proc_tasks = std.ArrayList(Task).init(global.alloc);
    defer proc_tasks.deinit();

    var maxt: f32 = 0;
    for (platform.processors) |p| {
        proc_tasks.clearRetainingCapacity();

        for (dag.nodes.items) |nd| if (nd.data.allocated_pid == p.pid) try proc_tasks.append(nd.data);

        const Static = struct {
            fn taskLessThan(_: void, a: Task, b: Task) bool {
                return a.actual_finish_time.? < b.actual_finish_time.?;
            }
        };
        std.mem.sort(Task, proc_tasks.items, void{}, Static.taskLessThan);

        var time: f32 = -1;
        var temp: f32 = TEMP_AMBIANT;
        for (proc_tasks.items) |task| {
            temp = coolingTemp(p, temp, task.actual_start_time.? - time);
            time = task.actual_start_time.?;
            var rem_time = task.per_proc[p.pid].wcet;
            std.debug.print("proc,task -- {}:{}\n", .{ p.pid, task.id });
            const max_iter_cont_exec = maximumDurationOfContExecution(task, p, p.temp_cutoff);
            while (rem_time > 0.1) {
                try sim.event_lists[p.pid].append(.{
                    .task_id = task.id,
                    .time = time,
                });

                std.debug.print("{}:{} , remtime:{}\n", .{ time, temp, rem_time });
                const dur = @min(maximumDurationOfContExecution(task, p, temp), rem_time);
                rem_time -= dur;
                time += dur;
                temp = heatingTemp(
                    p,
                    task.per_proc[p.pid].steady_state_temp,
                    temp,
                    dur,
                );
                std.debug.print("run for {} => {}:{} , remtime:{}\n", .{ dur, time, temp, rem_time });
                std.debug.assert(rem_time < 0.1 or @abs(temp - p.temp_limit) < 0.1);

                if (rem_time <= 0.001) break;

                try sim.event_lists[p.pid].append(.{
                    .task_id = null,
                    .time = time,
                });

                const cool_to_temp =
                    if (rem_time <= max_iter_cont_exec)
                        maxTempAllowedContExec(task, p, rem_time)
                    else
                        p.temp_cutoff;

                const cool_dur = coolingTime(p, cool_to_temp, temp);
                time += cool_dur;
                temp = coolingTemp(p, temp, cool_dur);
                std.debug.assert(@abs(temp - cool_to_temp) < 0.1);
            }

            std.debug.print("was supposed to end in {} , time is : {}\n", .{ task.actual_finish_time.?, time });
            std.debug.assert(@abs(time - task.actual_finish_time.?) < 0.1);
            time = task.actual_finish_time.?; // sync with scheduler

            time = task.actual_finish_time.?;
            try sim.event_lists[p.pid].append(.{
                .task_id = null,
                .time = time,
            });
        }
        maxt = @max(maxt, time);
    }
    for (&sim.event_lists) |*evlist| {
        try evlist.append(.{ .task_id = null, .time = maxt + 1 });
    }

    for (sim.event_lists, 0..) |evlist, pid| {
        std.debug.print("proc {}\n", .{pid});
        for (evlist.items) |it| {
            std.debug.print("  --evt @{} : {any}\n", .{ it.time, it.task_id });
        }
    }

    return sim;
}
fn visualizeSchedule(dag_inp: TaskDAG, platform_inp: Platform) !void {
    const Ctx = struct {
        dag: *const TaskDAG,
        platform: *const Platform,
        maxt: f32,
        proc_temp_graph: [Platform.NPROC][2][]f32,
        sim: Simulation,
    };
    const simul = try simulateScheduleByTETT(dag_inp, platform_inp);

    const temp_sample_per_event = 25;
    var proc_temp_graph: [Platform.NPROC][2][]f32 = undefined;
    for (&proc_temp_graph, platform_inp.processors, simul.event_lists) |*mem_xy, proc, evlist| {
        const pid = proc.pid;
        var xarr = try std.ArrayList(f32).initCapacity(
            global.alloc,
            temp_sample_per_event * evlist.items.len,
        );
        var yarr = try std.ArrayList(f32).initCapacity(
            global.alloc,
            temp_sample_per_event * evlist.items.len,
        );
        defer mem_xy[0] = xarr.toOwnedSlice() catch unreachable;
        defer mem_xy[1] = yarr.toOwnedSlice() catch unreachable;

        var ttime = evlist.items[0].time;
        var temp: f32 = TEMP_AMBIANT;
        var sstemp: f32 = TEMP_AMBIANT;

        std.debug.print("+proc:{}\n", .{pid});

        const evlen = evlist.items.len;
        for (evlist.items[0 .. evlen - 1], evlist.items[1..]) |evt, nxt_evt| {
            const delta_time: f32 = (nxt_evt.time - ttime) / temp_sample_per_event;
            sstemp = if (evt.task_id) |tid|
                dag_inp.nodes.items[tid].data.per_proc[pid].steady_state_temp
            else
                TEMP_AMBIANT;
            for (0..temp_sample_per_event) |_| {
                temp = heatingTemp(proc, sstemp, temp, delta_time);
                ttime += delta_time;
                try xarr.append(ttime);
                try yarr.append(@as(f32, @floatFromInt(pid)) +
                    (temp - TEMP_AMBIANT) / (proc.temp_limit - TEMP_AMBIANT));
                // std.debug.print("--xarr <- {}\n", .{ttime});
            }
        }
    }

    const Static = struct {
        var prng = std.Random.DefaultPrng.init(0);
        const rnd = prng.random();
        fn taskColor(tid: usize) plotting.nvg.Color {
            prng.seed(@intCast(tid));
            const hue = rnd.float(f32);
            return plotting.nvg.hsl(hue, 1, 0.5);
        }
        fn onDraw(ctx: *anyopaque, fig: *plotting.Figure, ax: *plotting.Axes, plt: *plotting.Plot) void {
            _ = fig; // autofix
            ax.draw();
            const typed_ctx: *const Ctx = @ptrCast(@alignCast(ctx));
            const dag = typed_ctx.dag;
            _ = dag; // autofix
            const platform = typed_ctx.platform;
            const maxt = typed_ctx.maxt;
            _ = maxt; // autofix
            const sim = typed_ctx.sim;
            const graphs = typed_ctx.proc_temp_graph;

            for (sim.event_lists, 0..) |evlist, pid| {
                const evlen = evlist.items.len;
                for (evlist.items[0 .. evlen - 1], evlist.items[1..]) |evt, nxt_evt| {
                    if (evt.task_id) |tid| {
                        plotting.rect(
                            ax,
                            plt.vg,
                            evt.time,
                            @as(f32, @floatFromInt(pid)) + 0.95,
                            nxt_evt.time - evt.time,
                            0.9,
                            taskColor(tid),
                        );
                        var tidbuf: [16]u8 = undefined;
                        const tidstr =
                            std.fmt.bufPrint(&tidbuf, "task{}", .{tid}) catch unreachable;
                        ax.text(
                            (evt.time * 1.5 + nxt_evt.time) / 2.5,
                            @as(f32, @floatFromInt(pid)) + 0.5,
                            .{ .str = tidstr },
                        );
                    }
                }
            }
            // for (dag.nodes.items) |it| {
            //     plotting.rect(
            //         ax,
            //         plt.vg,
            //         it.data.actual_start_time.?,
            //         @as(f32, @floatFromInt(it.data.allocated_pid.?)) + 0.95,
            //         it.data.actual_finish_time.? - it.data.actual_start_time.?,
            //         0.9,
            //         plotting.Color.green,
            //     );
            // }

            plt.aes.line_width = 5;
            for (platform.processors, graphs) |proc, grp| {
                _ = proc; // autofix
                if (grp[0].len > 0)
                    plt.plot(grp[0], grp[1]);
            }

            // for (platform.processors) |p| {
            //     var time: f32 = 0;
            //     var temp: f32 = TEMP_AMBIANT;
            //     var xx: [time_sample_count]f32 = undefined;
            //     var yy: [time_sample_count]f32 = undefined;
            //     xx[0] = time;
            //     yy[0] = temp;
            //     const delta_time = maxt / time_sample_count;
            //     var is_active = true;
            //     for (xx[1..], yy[1..], yy[0 .. yy.len - 1]) |*x, *y, py| {
            //         _ = py; // autofix
            //         time += delta_time;
            //         x.* = time;
            //         temp = if (is_active) heatingTemp(
            //             p,
            //             dag.nodes.items[1].data.per_proc[p.pid].steady_state_temp,
            //             temp,
            //             delta_time,
            //         ) else coolingTemp(p, temp, delta_time);
            //         if (temp > p.temp_limit) is_active = false;
            //         if (temp < p.temp_cutoff) is_active = true;
            //         y.* = (temp - TEMP_AMBIANT) / (p.temp_limit - TEMP_AMBIANT) + @as(f32, @floatFromInt(p.pid));
            //     }
            //     plt.aes.line_width = 5;
            //     plt.plot(&xx, &yy);
            // }

            ax.drawGrid();
        }
    };
    var maxt: f32 = 0;
    for (dag_inp.nodes.items) |it| {
        if (it.data.actual_finish_time) |t|
            maxt = @max(maxt, t);
    }

    const ctx = Ctx{
        .dag = &dag_inp,
        .platform = &platform_inp,
        .maxt = maxt,
        .proc_temp_graph = proc_temp_graph,
        .sim = simul,
    };
    try plotting.complexSingle(
        @constCast(&ctx),
        Static.onDraw,
        .{ -5, maxt + 5 },
        .{ -1, Platform.NPROC + 1 },
    );
}
const MAX_BW = 1e6;
pub fn main() !void {
    // Platform.NPROC = 3
    var platform = Platform{ .processors = .{
        .{ .pid = 0, .temp_limit = 80, .temp_cutoff = 60, .thermo = .init(2.332, 13.1568, 0.1754, 0.68, 380, 2.6) },
        .{ .pid = 1, .temp_limit = 70, .temp_cutoff = 50, .thermo = .init(2.138, 5.0187, 0.1942, 0.487, 295, 3.4) },
        .{ .pid = 2, .temp_limit = 60, .temp_cutoff = 40, .thermo = .init(4.556, 15.6262, 0.1942, 0.238, 320, 3.0) },
    }, .communication_bw = .{
        .{ MAX_BW, 2, 2 },
        .{ 2, MAX_BW, 2 },
        .{ 2, 2, MAX_BW },
    } };

    // task dag :
    var task_dag = TaskDAG.init();

    // append task nodes :
    try task_dag.appendNode(Task{ // t0
        .id = 0,
        .per_proc = .{
            .{ .wcet = 1, .steady_state_temp = 90 }, // p0
            .{ .wcet = 2, .steady_state_temp = 80 }, // p1
            .{ .wcet = 4, .steady_state_temp = 50 }, // p2
        },
    });
    try task_dag.appendNode(Task{ // t1
        .id = 1,
        .per_proc = .{
            .{ .wcet = 1, .steady_state_temp = 90 }, // p0
            .{ .wcet = 2, .steady_state_temp = 80 }, // p1
            .{ .wcet = 4, .steady_state_temp = 50 }, // p2
        },
    });
    try task_dag.appendNode(Task{ // t2
        .id = 2,
        .per_proc = .{
            .{ .wcet = 1, .steady_state_temp = 90 }, // p0
            .{ .wcet = 2, .steady_state_temp = 80 }, // p1
            .{ .wcet = 4, .steady_state_temp = 50 }, // p2
        },
    });

    // connect tasks :
    try task_dag.connectNodes(0, 1, .{ .data_transfer = 0.001 });
    try task_dag.connectNodes(0, 2, .{ .data_transfer = 0.001 });
    try task_dag.connectNodes(1, 2, .{ .data_transfer = 0.001 });

    // solve scheduling :
    try tmds(&task_dag, &platform);

    // results :
    for (task_dag.nodes.items, 0..) |nd, tid| {
        std.debug.print(
            "task_{} : from {d}s to {d}s on proc_{}\n",
            .{ tid, nd.data.actual_start_time.?, nd.data.actual_finish_time.?, nd.data.allocated_pid.? },
        );
    }
}

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
    const testing_task = Task{
        .id = 0,
        .per_proc = .{
            .{ .wcet = 1000, .steady_state_temp = 90 }, // p0
            .{ .wcet = 1200, .steady_state_temp = 80 }, // p1
            .{ .wcet = 3000, .steady_state_temp = 50 }, // p2
        },
    };
    const testing_platform = Platform{ .processors = .{
        .{ .pid = 0, .temp_limit = 80, .temp_cutoff = 60, .thermo = .init(2.332, 13.1568, 0.1754, 0.68, 380, 2.6) },
        .{ .pid = 1, .temp_limit = 70, .temp_cutoff = 50, .thermo = .init(2.138, 5.0187, 0.1942, 0.487, 295, 3.4) },
        .{ .pid = 2, .temp_limit = 60, .temp_cutoff = 40, .thermo = .init(4.556, 15.6262, 0.1942, 0.238, 320, 3.0) },
    }, .communication_bw = .{
        .{ MAX_BW, 2, 2 },
        .{ 2, MAX_BW, 2 },
        .{ 2, 2, MAX_BW },
    } };

    test "cooling/heating temp/time" { // OK
        const p = testing_platform.processors[0];
        var t: f32 = 0;
        const sample_count = 100;
        var xx: [sample_count]f32 = undefined;
        var cooling: [sample_count]f32 = undefined;
        var heating: [sample_count]f32 = undefined;
        var ttcool: [sample_count]f32 = undefined;
        const temp_ini = 50;
        const temp_fin = 100;
        for (&xx, &cooling, &heating, &ttcool) |*time0, *ctemp, *htemp, *tcool| {
            defer t += 50;

            time0.* = t;
            ctemp.* = coolingTemp(p, temp_ini, t);
            htemp.* = heatingTemp(p, temp_fin, temp_ini, t);
            tcool.* = coolingTime(p, ctemp.*, temp_ini);
        }
        try plotting.simple(
            &.{ &xx, &xx, &ttcool },
            &.{ &cooling, &heating, &cooling },
            &.{
                plotting.Aes{ .line_col = plotting.Color.cyan, .line_width = 3 },
                plotting.Aes{ .line_col = plotting.Color.red, .line_width = 3 },
                plotting.Aes{ .line_col = plotting.Color.olive, .line_width = 3 },
            },
            .{ -5, t + 5 },
            .{ -5, 105 },
        );
    }
    test "maximumDurationOfContExecution" { //OK
        const t = testing_task;

        const sample_count = 100;
        const temp_from = 0.0;
        const temp_to = 100.0;
        var temp_ini: [sample_count]f32 = undefined;
        var exec_dur: [Platform.NPROC][sample_count]f32 = undefined;
        var tt: f32 = temp_from;
        for (&temp_ini) |*temp| {
            temp.* = tt;
            tt += (temp_to - temp_from) / @as(comptime_float, sample_count);
        }
        for (testing_platform.processors, &exec_dur) |p, *p_dur| {
            for (temp_ini, p_dur) |temp, *dur| {
                dur.* = maximumDurationOfContExecution(t, p, temp);
            }
        }
        try plotting.simple(
            &.{ &temp_ini, &temp_ini, &temp_ini },
            &.{ &exec_dur[0], &exec_dur[1], &exec_dur[2] },
            &.{
                plotting.Aes{ .line_width = 3, .line_col = plotting.Color.red },
                plotting.Aes{ .line_width = 3, .line_col = plotting.Color.green },
                plotting.Aes{ .line_width = 3, .line_col = plotting.Color.blue },
            },
            .{ temp_from - 5, temp_to + 5 },
            .{ -10, 1000 },
        );
    }
    test "numberOfCoollingIntervals" { // OK
        const t = testing_task;

        const sample_count = 100;
        const temp_from = 0.0;
        const temp_to = 100.0;
        var temp_ini: [sample_count]f32 = undefined;
        var cooling_cnt: [Platform.NPROC][sample_count]f32 = undefined;
        var tt: f32 = temp_from;
        for (&temp_ini) |*temp| {
            temp.* = tt;
            tt += (temp_to - temp_from) / @as(comptime_float, sample_count);
        }
        for (testing_platform.processors, &cooling_cnt) |p, *p_cnt| {
            for (temp_ini, p_cnt) |temp, *cnt| {
                cnt.* = @floatFromInt(numberOfCoollingIntervals(t, p, temp));
            }
        }
        try plotting.simple(
            &.{ &temp_ini, &temp_ini, &temp_ini },
            &.{ &cooling_cnt[0], &cooling_cnt[1], &cooling_cnt[2] },
            &.{
                plotting.Aes{ .line_width = 3, .line_col = plotting.Color.red },
                plotting.Aes{ .line_width = 3, .line_col = plotting.Color.green },
                plotting.Aes{ .line_width = 3, .line_col = plotting.Color.blue },
            },
            .{ temp_from - 5, temp_to + 5 },
            .{ -1, 5 },
        );
    }
    test "maxTempAllowedContExec" { // OK
        const t = testing_task;

        const sample_count = 100;
        const time_from = 0.0;
        const time_to = 1000.0;
        var rem_time: [sample_count]f32 = undefined;
        var max_temp: [Platform.NPROC][sample_count]f32 = undefined;
        var tt: f32 = time_from;
        for (&rem_time) |*temp| {
            temp.* = tt;
            tt += (time_to - time_from) / @as(comptime_float, sample_count);
        }
        for (testing_platform.processors, &max_temp) |p, *p_tmp| {
            for (rem_time, p_tmp) |time, *tmp| {
                tmp.* = maxTempAllowedContExec(t, p, time);
            }
        }
        try plotting.simple(
            &.{ &rem_time, &rem_time, &rem_time },
            &.{ &max_temp[0], &max_temp[1], &max_temp[2] },
            &.{
                plotting.Aes{ .line_width = 3, .line_col = plotting.Color.red },
                plotting.Aes{ .line_width = 3, .line_col = plotting.Color.green },
                plotting.Aes{ .line_width = 3, .line_col = plotting.Color.blue },
            },
            .{ time_from - 5, time_to + 5 },
            .{ -5, 105 },
        );
    }
    test "tett" {
        const sample_count = 1000;
        const temp_from = 0.0;
        const temp_to = 100.0;
        var temp_init: [sample_count]f32 = undefined;
        var final_temp: [Platform.NPROC][sample_count]f32 = undefined;
        var final_time: [Platform.NPROC][sample_count]f32 = undefined;
        var tt: f32 = temp_from;
        for (&temp_init) |*temp| {
            temp.* = tt;
            tt += @as(comptime_float, temp_to - temp_from) / @as(comptime_float, sample_count);
        }
        for (testing_platform.processors, &final_temp, &final_time) |p, *p_tmp, *p_time| {
            for (temp_init, p_tmp, p_time) |temp_ini, *tmp, *fin_t| {
                const ttt = tett(testing_task, p, 0, temp_ini);
                tmp.* = ttt.fin_temp;
                fin_t.* = ttt.fin_t;
            }
        }
        try plotting.simple(
            &.{
                // &temp_init,
                // &temp_init,
                // &temp_init,
                &temp_init,
                &temp_init,
                &temp_init,
            },
            &.{
                // &final_temp[0],
                // &final_temp[1],
                // &final_temp[2],
                &final_time[0],
                &final_time[1],
                &final_time[2],
            },
            &.{
                plotting.Aes{ .line_width = 3, .line_col = plotting.Color.red },
                plotting.Aes{ .line_width = 3, .line_col = plotting.Color.green },
                plotting.Aes{ .line_width = 3, .line_col = plotting.Color.blue },
                // plotting.Aes{ .line_width = 3, .line_col = plotting.Color.orange },
                // plotting.Aes{ .line_width = 3, .line_col = plotting.Color.cyan },
                // plotting.Aes{ .line_width = 3, .line_col = plotting.Color.pink },
            },
            .{ temp_from - 5, temp_to + 5 },
            .{ -5, 1705 },
        );
    }
    test "tmds" {
        var platform = testing_platform;
        var dag = TaskDAG.init();
        try dag.appendNode(update(testing_task, .{ .id = 0 }));
        try dag.appendNode(update(testing_task, .{ .id = 1 }));
        try dag.appendNode(update(testing_task, .{ .id = 2 }));
        try dag.appendNode(update(testing_task, .{ .id = 3 }));
        try dag.appendNode(update(testing_task, .{ .id = 4 }));
        // try dag.appendNode(testing_task);
        // try dag.connectNodes(0, 1, .{ .data_transfer = 100 });
        // try dag.connectNodes(0, 2, .{ .data_transfer = 100 });
        // try dag.connectNodes(1, 2, .{ .data_transfer = 1 });

        try tmds(&dag, &platform);

        std.debug.print("tett : {}\n", .{
            tett(testing_task, platform.processors[0], 0, TEMP_AMBIANT),
        });
        for (dag.nodes.items, 0..) |node, id| {
            std.debug.print("{} == {}-{} on {}\n", .{
                id,
                node.data.actual_start_time.?,
                node.data.actual_finish_time.?,
                node.data.allocated_pid.?,
            });
        }
        _ = 0;
        try visualizeSchedule(dag, platform);
    }
};

test {
    _ = testing;
}
