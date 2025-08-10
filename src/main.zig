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

fn tett(t: Task, p: Processor, cur_time: f32, temp_ini: f32) struct { fin_t: f32, temp_fin: f32 } {
    var allowed_exec_time = maximumDurationOfContExecution(t, p, temp_ini);
    const wcet = t.per_proc[p.pid].wcet;
    const tss = t.per_proc[p.pid].steady_state_temp;
    if (wcet <= allowed_exec_time) return .{
        .fin_t = cur_time + wcet,
        .temp_fin = heatingTemp(p, tss, temp_ini, wcet),
    };
    var rem_exec_time = wcet - allowed_exec_time;
    var cur_t = cur_time + allowed_exec_time;
    const idle_t = coolingTime(p, p.temp_cutoff, p.temp_limit);
    allowed_exec_time = maximumDurationOfContExecution(t, p, p.temp_cutoff);
    std.debug.print("{}\n", .{allowed_exec_time});

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
    return .{ .fin_t = cur_t, .temp_fin = p.temp_limit };
}

const TMDS_Error = error{NoEntryPoint};
fn tmds(graph: *TaskDAG, platform: *Platform) !void {
    const entry = blk: {
        for (graph.nodes.items) |*nd| {
            if (nd.dependencies.items.len == 0) break :blk nd;
        }
        return TMDS_Error.NoEntryPoint;
    };
    var task_list = std.ArrayList(*TaskDAG.Node).init(global.alloc);
    try task_list.append(entry);
    while (task_list.items.len > 0) {
        const task = blk: {
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
            break :blk tsk;
        };
        var optproc: u8 = undefined;
        var opttemp: f32 = undefined;
        var optstrt: f32 = undefined;
        var optcompl = std.math.inf(f32);
        for (platform.processors) |proc| {
            const sttime = effectiveStartTime(task, platform.*, proc);
            const temp_estim = coolingTemp(proc, proc.temp_cur, sttime - proc.avail);
            const estim = tett(task.data, proc, sttime, temp_estim);
            const schedule_compl_time = estim.fin_t + estim.fin_t + optimisticFinishTime(task, platform.*, proc);
            if (optcompl > schedule_compl_time) {
                optcompl = schedule_compl_time;
                opttemp = estim.temp_fin;
                optstrt = sttime;
                optproc = proc.pid;
            }
        }
        task.data.allocated_pid = optproc;
        task.data.actual_start_time = optstrt;
        task.data.actual_finish_time = optcompl;
        platform.processors[optproc].avail = optcompl;
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
fn simulateSchedule(dag: TaskDAG, platform: Platform) !Simulation {
    var sim = Simulation{ .event_lists = undefined };
    for (&sim.event_lists) |*e| {
        e.* = try .initCapacity(global.alloc, 1);
        try e.append(.{ .task_id = null, .time = -1 });
    }

    var proc_tasks = std.ArrayList(Task).init(global.alloc);
    defer proc_tasks.deinit();

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

                if (dur >= rem_time - 0.001) break;

                try sim.event_lists[p.pid].append(.{
                    .task_id = null,
                    .time = time,
                });

                const cool_dur = coolingTime(p, p.temp_cutoff, temp);
                time += cool_dur;
                temp = coolingTemp(p, temp, cool_dur);
                std.debug.assert(@abs(temp - p.temp_cutoff) < 0.1);
            }

            std.debug.print("was supposed to end in {}\n", .{task.actual_finish_time.?});
            std.debug.assert(@abs(time - task.actual_finish_time.?) < 0.1);

            time = task.actual_finish_time.?;
            try sim.event_lists[p.pid].append(.{
                .task_id = null,
                .time = time,
            });
        }
    }

    return sim;
}
fn visualizeSchedule(dag_inp: TaskDAG, platform_inp: Platform) !void {
    const Ctx = struct { dag: *const TaskDAG, platform: *const Platform, maxt: f32 };
    const sim = try simulateSchedule(dag_inp, platform_inp);
    _ = sim; // autofix

    const Static = struct {
        fn onDraw(ctx: *anyopaque, fig: *plotting.Figure, ax: *plotting.Axes, plt: *plotting.Plot) void {
            _ = fig; // autofix
            ax.draw();
            const typed_ctx: *const Ctx = @ptrCast(@alignCast(ctx));
            const dag = typed_ctx.dag;
            const platform = typed_ctx.platform;
            const maxt = typed_ctx.maxt;

            for (dag.nodes.items) |it| {
                plotting.rect(
                    ax,
                    plt.vg,
                    it.data.actual_start_time.?,
                    @as(f32, @floatFromInt(it.data.allocated_pid.?)) + 0.95,
                    it.data.actual_finish_time.? - it.data.actual_start_time.?,
                    0.9,
                    plotting.Color.green,
                );
            }

            const time_sample_count = 1000;
            for (platform.processors) |p| {
                var time: f32 = 0;
                var temp: f32 = TEMP_AMBIANT;
                var xx: [time_sample_count]f32 = undefined;
                var yy: [time_sample_count]f32 = undefined;
                xx[0] = time;
                yy[0] = temp;
                const delta_time = maxt / time_sample_count;
                var is_active = true;
                for (xx[1..], yy[1..], yy[0 .. yy.len - 1]) |*x, *y, py| {
                    _ = py; // autofix
                    time += delta_time;
                    x.* = time;
                    temp = if (is_active) heatingTemp(
                        p,
                        dag.nodes.items[1].data.per_proc[p.pid].steady_state_temp,
                        temp,
                        delta_time,
                    ) else coolingTemp(p, temp, delta_time);
                    if (temp > p.temp_limit) is_active = false;
                    if (temp < p.temp_cutoff) is_active = true;
                    y.* = (temp - TEMP_AMBIANT) / (p.temp_limit - TEMP_AMBIANT) + @as(f32, @floatFromInt(p.pid));
                }
                plt.aes.line_width = 5;
                plt.plot(&xx, &yy);
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
    const testing_task = Task{
        .id = 0,
        .per_proc = .{
            .{ .wcet = 1000 / 2, .steady_state_temp = 90 }, // p0
            .{ .wcet = 1000 / 2, .steady_state_temp = 80 }, // p1
            .{ .wcet = 3000 / 2, .steady_state_temp = 50 }, // p2
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
    test "tmds" {
        var platform = testing_platform;
        var dag = TaskDAG.init();
        try dag.appendNode(testing_task);
        try dag.appendNode(testing_task);
        try dag.appendNode(testing_task);
        try dag.connectNodes(0, 1, .{ .data_transfer = 100 });
        try dag.connectNodes(0, 2, .{ .data_transfer = 100 });
        // try dag.connectNodes(1, 2, .{ .data_transfer = 1 });

        try tmds(&dag, &platform);

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
