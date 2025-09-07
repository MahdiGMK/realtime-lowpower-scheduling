const std = @import("std");
const ArrayList = std.ArrayListUnmanaged;
const plotting = @import("plotting.zig");

pub const global = struct {
    var gpa = std.heap.DebugAllocator(.{}).init;
    pub const alloc = gpa.allocator();
};
pub const Processor = struct {
    pid: u8,
    temp_limit: f32,
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
        pub fn init(c0: f32, c1: f32, c2: f32, r: f32, c: f32, f: f32) @This() {
            return .{ .a = 1.0 / c, .b = 1.0 / c / r, .c0 = c0, .c1 = c1, .c2 = c2, .f = f };
        }
    }, // all the properties
    fn thermB(self: *const Processor) f32 {
        return self.thermo.b - self.thermo.a * self.thermo.c2 * self.thermo.f;
    }
};
pub const TEMP_AMBIANT = 25;
pub const Platform = struct {
    pub const NPROC = 3;
    processors: [NPROC]Processor,
    communication_bw: [NPROC][NPROC]f32,
    communication_lat: [NPROC][NPROC]f32,
};
pub const Task = struct {
    id: usize,
    per_proc: [Platform.NPROC]struct {
        wcet: f32,
        steady_state_temp: f32,
        optimistic_finish_time: ?f32 = null,
    },
    allocated_pid: ?u8 = null,
    actual_start_time: ?f32 = null,
    actual_finish_time: ?f32 = null,
};
pub const TaskCommunication = struct {
    data_transfer: f32,
};

pub fn avgWCET(task: Task) f32 {
    var sum: f32 = 0;
    for (task.per_proc) |p| sum += p.wcet;
    return sum / task.per_proc.len;
}
pub fn avgCommunicationLat(platform: Platform) f32 {
    var sum: f32 = 0;
    for (platform.communication_lat) |lt| {
        for (lt) |lat| sum += lat;
    }
    return sum / @as(f32, Platform.NPROC) / @as(f32, Platform.NPROC);
}
pub fn avgCommunicationBW(platform: Platform) f32 {
    var sum: f32 = 0;
    for (platform.communication_bw) |b| {
        for (b) |bw| sum += bw;
    }
    return sum / @as(f32, Platform.NPROC) / @as(f32, Platform.NPROC);
}
pub fn makeTaskList(dag: *TaskDAG) !ArrayList(*TaskDAG.Node) {
    var task_list = ArrayList(*TaskDAG.Node).empty;
    for (dag.nodes.items) |*nd|
        if (nd.dependencies.items.len == 0)
            try task_list.append(global.alloc, nd);
    return task_list;
}
pub fn extractBestTask(task_list: *ArrayList(*TaskDAG.Node), platform: Platform, comptime rank_fn: fn (*TaskDAG.Node, Platform) f32) *TaskDAG.Node {
    var tsk: *TaskDAG.Node = undefined;
    var idx: usize = undefined;
    var rnk: f32 = -std.math.inf(f32);
    for (task_list.items, 0..) |t, i| {
        const r = rank_fn(t, platform);
        if (rnk <= r) {
            rnk = r;
            idx = i;
            tsk = t;
        }
    }
    _ = task_list.swapRemove(idx);
    return tsk;
}
pub fn DAG(comptime NodeData: type, comptime EdgeData: type) type {
    return struct {
        const Graph = @This();
        pub const Node = struct {
            data: NodeData,
            solved_deps: usize = 0,
            dependencies: ArrayList(struct { *Node, EdgeData }),
            dependants: ArrayList(struct { *Node, EdgeData }),
            const Nd = @This();
            pub fn init(data: NodeData) Nd {
                return Nd{
                    .data = data,
                    .dependencies = .empty,
                    .dependants = .empty,
                };
            }
            pub fn markAsSolved(self: Node, completed_deps: *ArrayList(*Node)) !void {
                for (self.dependants.items) |it| {
                    const nd, _ = it;
                    nd.solved_deps += 1;
                    if (nd.solved_deps == nd.dependencies.items.len) {
                        try completed_deps.append(global.alloc, nd);
                    }
                }
            }
        };
        nodes: ArrayList(Node),
        pub fn init() Graph {
            return Graph{ .nodes = .empty };
        }
        pub fn initGaussianElimination(n: usize) !Graph {
            var g = Graph{
                .nodes = try .initCapacity(global.alloc, (n - 1) * (n + 2) / 2),
            };
            try g.appendNode(undefined);
            var root: usize = 0;
            var first_in_prv_row: ?usize = null;
            for (1..n) |s| {
                const width = n - s;
                const first_in_row = g.nodes.items.len;
                for (0..width) |off| {
                    try g.appendNode(undefined);
                    try g.connectNodes(root, g.nodes.items.len - 1, undefined);
                    if (first_in_prv_row) |first_upper| {
                        try g.connectNodes(first_upper + off + 1, g.nodes.items.len - 1, undefined);
                    }
                }
                first_in_prv_row = first_in_row;
                if (width == 1) break;

                root = g.nodes.items.len;
                try g.appendNode(undefined);
                try g.connectNodes(first_in_row, root, undefined);
            }
            return g;
        }
        pub fn initLaplace(n: usize) !Graph {
            var g = Graph{
                .nodes = try .initCapacity(global.alloc, n * n),
            };
            try g.appendNode(undefined);
            var root: usize = 0;
            for (2..n + 1) |width| {
                const first = g.nodes.items.len;
                for (0..width) |off| {
                    try g.appendNode(undefined);
                    if (root + off < first) try g.connectNodes(root + off, first + off, undefined);
                    if (off > 0) try g.connectNodes(root + off - 1, first + off, undefined);
                }
                root = first;
            }
            for (1..n) |s| {
                const width = n - s;
                const first = g.nodes.items.len;
                for (0..width) |off| {
                    try g.appendNode(undefined);
                    try g.connectNodes(root + off, first + off, undefined);
                    if (root + off + 1 < first)
                        try g.connectNodes(root + off + 1, first + off, undefined);
                }
                root = first;
            }
            return g;
        }

        pub fn appendNode(self: *Graph, data: NodeData) !void {
            try self.nodes.append(global.alloc, Node.init(data));
        }
        pub fn connectNodes(self: *Graph, dependency: usize, dependant: usize, edge: EdgeData) !void {
            const dency = @constCast(&self.nodes.items[dependency]);
            const dant = @constCast(&self.nodes.items[dependant]);
            try dant.dependencies.append(global.alloc, .{ dency, edge });
            try dency.dependants.append(global.alloc, .{ dant, edge });
        }
    };
}

pub const TaskDAG = DAG(Task, TaskCommunication);

pub fn resetSchedule(dag: *TaskDAG, platform: *Platform) void {
    for (dag.nodes.items) |*nd| {
        nd.data.actual_finish_time = null;
        nd.data.actual_start_time = null;
        nd.data.allocated_pid = null;
        nd.solved_deps = 0;
        for (0..Platform.NPROC) |pid| nd.data.per_proc[pid].optimistic_finish_time = null;
    }
    for (&platform.processors) |*proc| {
        proc.avail = 0;
        proc.temp_cur = TEMP_AMBIANT;
    }
}

/// OFT/OCT function in the literature
pub fn optimisticFinishTime(n: *TaskDAG.Node, platform: Platform, p: Processor) f32 {
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
                    e.data_transfer / platform.communication_bw[p.pid][np.pid] +
                    platform.communication_lat[p.pid][np.pid],
            );
        }
        res = @max(res, rs);
    }

    n.data.per_proc[p.pid].optimistic_finish_time = res + n.data.per_proc[p.pid].wcet;
    return n.data.per_proc[p.pid].optimistic_finish_time.?;
}

/// rank_OFT/OCT
pub fn taskRankOptimisticFinishTime(n: *TaskDAG.Node, platform: Platform) f32 {
    var res: f32 = 0;
    for (platform.processors) |p| {
        res += optimisticFinishTime(n, platform, p);
    }
    return res / Platform.NPROC;
}

pub fn effectiveStartTime(n: *const TaskDAG.Node, platform: Platform, p: Processor) f32 { // OK
    var dep: f32 = 0;
    for (n.dependencies.items) |it| {
        const pn, const e = it;
        if (pn.data.actual_finish_time) |aft| {
            dep = @max(
                dep,
                aft + e.data_transfer / platform.communication_bw[pn.data.allocated_pid.?][p.pid] +
                    platform.communication_lat[pn.data.allocated_pid.?][p.pid],
            );
        } else return std.math.inf(f32);
    }
    return @max(p.avail, dep);
}

pub fn maximumDurationOfContExecution(t: Task, p: Processor, temp_ini: f32) f32 { // OK
    const temp_steady = t.per_proc[p.pid].steady_state_temp;
    if (temp_ini > p.temp_limit) return 0;
    if (temp_steady <= p.temp_limit) {
        return std.math.inf(f32);
    }
    const res: f32 = -1.0 / p.thermB() * @log((p.temp_limit - temp_steady) / (temp_ini - temp_steady));
    // std.debug.print("{} {} {} {} => {}\n", .{ p.thermB(), p.temp_limit, temp_steady, temp_ini, res });
    return res;
}

pub fn coolingTime(p: Processor, temp_fin: f32, temp_ini: f32) f32 { // OK
    return -1.0 / p.thermB() * @log((temp_fin - TEMP_AMBIANT) / (temp_ini - TEMP_AMBIANT));
}

pub fn heatingTemp(p: Processor, temp_fin: f32, temp_ini: f32, duration: f32) f32 { // OK
    return temp_fin + (temp_ini - temp_fin) * @exp(-p.thermB() * duration);
}

pub fn coolingTemp(p: Processor, temp_ini: f32, duration: f32) f32 { // OK
    return heatingTemp(p, TEMP_AMBIANT, temp_ini, duration);
}

pub fn numberOfCoollingIntervals(t: Task, p: Processor, temp_est: f32) usize { // OK
    const wcet = t.per_proc[p.pid].wcet;
    const first_cycle = maximumDurationOfContExecution(t, p, temp_est);
    if (first_cycle >= wcet) return 0;

    const after_first = wcet - first_cycle;
    const run_cycle_dur = maximumDurationOfContExecution(t, p, optimalCooldown(t, p));
    const res = after_first / run_cycle_dur;
    return @intFromFloat(@floor(res) + 1);
}

pub fn maxTempAllowedContExec(t: Task, p: Processor, rem_exec_time: f32) f32 { // OK
    if (t.per_proc[p.pid].steady_state_temp < p.temp_limit)
        return p.temp_limit;
    return t.per_proc[p.pid].steady_state_temp +
        (p.temp_limit - t.per_proc[p.pid].steady_state_temp) /
            @exp(-p.thermB() * rem_exec_time);
}
pub fn optimalCooldown(t: Task, p: Processor) f32 {
    // execution is split into regions of
    // power_mode_switching_time|coolingTime|maximumDurationOfContExecution(Actual work)|power_mode_switching_time
    // so we want to optimize the ratio of "Actual work" compared to the total duration of cycle
    //
    // we should optimize :
    // f(c) = maximumDurationOfContExecution/(2*power_mode_switching_time+coolingTime+maximumDurationOfContExecution)
    // =>
    // L: p.temp_limit
    // B: -1.0 / p.thermB()
    // A: TEMP_AMBIANT
    // x: cutoff
    // H: t.temp_steady
    // S: p.power_mode_switching_time
    // maxDur:   B * @log((L - H) / (x - H));
    // coolTime: B * @log((x - A) / (L - A));
    // find optimum using ternary search
    //

    const Sample = struct {
        fn func(
            task: Task,
            proc: Processor,
            temp_cutoff: f32,
        ) f32 {
            const maxDur = maximumDurationOfContExecution(task, proc, temp_cutoff);
            const coolT = coolingTime(proc, temp_cutoff, proc.temp_limit);
            return maxDur / (coolT + maxDur + 2 * proc.power_mode_switching_time);
        }
    };
    var l: f32 = TEMP_AMBIANT;
    var r: f32 = p.temp_limit;
    const NUM_ITER = 20;
    for (0..NUM_ITER) |_| {
        const mid1 = (l + r) / 2;
        const mid2 = mid1 + 0.001;
        const f1 = Sample.func(t, p, mid1);
        const f2 = Sample.func(t, p, mid2);
        if (@abs(f1 - f2) < 0.001) {
            return if (f1 > f2) mid1 else mid2;
        }
        if (f1 < f2) {
            l = mid1;
        } else r = mid2;
    }
    return l;
}
pub fn tett(t: Task, p: Processor, cur_time: f32, temp_ini: f32) struct { fin_t: f32, fin_temp: f32 } {
    var allowed_exec_time = maximumDurationOfContExecution(t, p, temp_ini);
    const wcet = t.per_proc[p.pid].wcet;
    const tss = t.per_proc[p.pid].steady_state_temp;
    if (wcet <= allowed_exec_time) return .{
        .fin_t = cur_time + wcet,
        .fin_temp = heatingTemp(p, tss, temp_ini, wcet),
    };
    var rem_exec_time = wcet - allowed_exec_time;
    var cur_t = cur_time + allowed_exec_time;
    const idle_t = coolingTime(p, optimalCooldown(t, p), p.temp_limit);
    allowed_exec_time = maximumDurationOfContExecution(t, p, optimalCooldown(t, p));

    std.debug.print("optcool : {}\n", .{optimalCooldown(t, p)});
    std.debug.print("lim : {}\n", .{p.temp_limit});

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

const Simulation = struct {
    const Event = struct {
        time: f32,
        task_id: ?usize,
    };

    event_lists: [Platform.NPROC]ArrayList(Event),
};
pub fn simulateScheduleByTETT(dag: TaskDAG, platform: Platform) !Simulation {
    var sim = Simulation{ .event_lists = undefined };
    for (&sim.event_lists) |*e| {
        e.* = try .initCapacity(global.alloc, 2);
        try e.append(global.alloc, .{ .task_id = null, .time = -2 });
        try e.append(global.alloc, .{ .task_id = null, .time = -1 });
    }

    var proc_tasks = ArrayList(Task).empty;
    defer proc_tasks.deinit(global.alloc);

    var maxt: f32 = 0;
    for (platform.processors) |p| {
        proc_tasks.clearRetainingCapacity();

        for (dag.nodes.items) |nd| if (nd.data.allocated_pid == p.pid) try proc_tasks.append(global.alloc, nd.data);

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
            const max_iter_cont_exec = maximumDurationOfContExecution(task, p, optimalCooldown(task, p));
            while (rem_time > 0.1) {
                try sim.event_lists[p.pid].append(global.alloc, .{
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

                try sim.event_lists[p.pid].append(global.alloc, .{
                    .task_id = null,
                    .time = time,
                });

                const cool_to_temp =
                    if (rem_time <= max_iter_cont_exec)
                        maxTempAllowedContExec(task, p, rem_time)
                    else
                        optimalCooldown(task, p);

                const cool_dur = coolingTime(p, cool_to_temp, temp);
                time += 2 * p.power_mode_switching_time + cool_dur;
                temp = coolingTemp(p, temp, cool_dur);
                std.debug.assert(@abs(temp - cool_to_temp) < 0.1);
            }

            std.debug.print("was supposed to end in {} , time is : {}\n", .{ task.actual_finish_time.?, time });
            std.debug.assert(@abs(time - task.actual_finish_time.?) < 0.1);
            time = task.actual_finish_time.?; // sync with scheduler

            time = task.actual_finish_time.?;
            try sim.event_lists[p.pid].append(global.alloc, .{
                .task_id = null,
                .time = time,
            });
        }
        maxt = @max(maxt, time);
    }
    for (&sim.event_lists) |*evlist| {
        try evlist.append(global.alloc, .{ .task_id = null, .time = maxt + 1 });
    }

    for (sim.event_lists, 0..) |evlist, pid| {
        std.debug.print("proc {}\n", .{pid});
        for (evlist.items) |it| {
            std.debug.print("  --evt @{} : {any}\n", .{ it.time, it.task_id });
        }
    }

    return sim;
}
pub fn visualizeSchedule(dag_inp: TaskDAG, platform_inp: Platform) !void {
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
        var xarr = try ArrayList(f32).initCapacity(
            global.alloc,
            temp_sample_per_event * evlist.items.len,
        );
        var yarr = try ArrayList(f32).initCapacity(
            global.alloc,
            temp_sample_per_event * evlist.items.len,
        );
        defer mem_xy[0] = xarr.toOwnedSlice(global.alloc) catch unreachable;
        defer mem_xy[1] = yarr.toOwnedSlice(global.alloc) catch unreachable;

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
                try xarr.append(global.alloc, ttime);
                try yarr.append(global.alloc, @as(f32, @floatFromInt(pid)) +
                    (temp - TEMP_AMBIANT) / (proc.temp_limit - TEMP_AMBIANT));
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
        fn onDraw(ctx: *anyopaque, _: *plotting.Figure, ax: *plotting.Axes, plt: *plotting.Plot) void {
            ax.draw();
            const typed_ctx: *const Ctx = @ptrCast(@alignCast(ctx));
            _ = typed_ctx.dag;
            const platform = typed_ctx.platform;
            _ = typed_ctx.maxt;
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
                            std.fmt.bufPrint(&tidbuf, "t{}", .{tid}) catch unreachable;
                        ax.text(
                            (evt.time + nxt_evt.time) / 2,
                            @as(f32, @floatFromInt(pid)) + 0.5,
                            .{ .str = tidstr, .alignment = .{ .horizontal = .center, .vertical = .middle } },
                        );
                    }
                }
            }

            plt.aes.line_width = 2;
            for (platform.processors, graphs) |_, grp| {
                if (grp[0].len > 0)
                    plt.plot(grp[0], grp[1]);
            }

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
            .{ -1, 80 },
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
    test "tett" { // OK
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
            .{ -5, 6000 },
        );
    }
};

test {
    _ = testing;
}
