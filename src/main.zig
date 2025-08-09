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
    temp_cur: f32 = temp_ambiant,
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
const temp_ambiant = 25;
const Platform = struct {
    const NPROC = 3;
    processors: [NPROC]Processor,
    communication_bw: [NPROC][NPROC]f32,
};
var platform: Platform = undefined;
const Task = struct {
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

fn optimisticFinishTime(n: *TaskDAG.Node, p: Processor) f32 {
    if (n.data.per_proc[p.pid].optimistic_finish_time) |oft| return oft;
    if (n.dependants.items.len == 0) return n.data.per_proc[p.pid].wcet;

    var res: f32 = 0;
    for (n.dependants.items) |it| {
        const nn, const e = it;
        var rs = std.math.inf(f32);
        for (platform.processors) |np| {
            rs = @min(
                rs,
                optimisticFinishTime(nn, np) +
                    e.data_transfer / platform.communication_bw[p.pid][np.pid],
            );
        }
        res = @max(res, rs);
    }

    n.data.per_proc[p.pid].optimistic_finish_time = res + n.data.per_proc[p.pid].wcet;
    return n.data.per_proc[p.pid].optimistic_finish_time.?;
}
fn taskRank(n: *TaskDAG.Node) f32 {
    var res: f32 = 0;
    for (platform.processors) |p| {
        res += optimisticFinishTime(n, p);
    }
    return res / Platform.NPROC;
}
fn effectiveStartTime(n: *TaskDAG.Node, p: Processor) f32 {
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
fn maximumDurationOfContExecution(t: Task, p: Processor, temp_ini: f32) f32 {
    const temp_steady = t.per_proc[p.pid].steady_state_temp;
    if (temp_steady < temp_ini) {
        return std.math.inf(f32);
    }
    const res: f32 = -1.0 / p.thermB() * @log((p.temp_limit - temp_steady) / (temp_ini - temp_steady));
    std.debug.print("{} {} {} {} => {}\n", .{ p.thermB(), p.temp_limit, temp_steady, temp_ini, res });
    return res;
}

fn coolingTime(p: Processor, temp_fin: f32, temp_ini: f32) f32 { // OK
    return -1.0 / p.thermB() * @log((temp_fin - temp_ambiant) / (temp_ini - temp_ambiant));
}

fn heatingTemp(p: Processor, temp_fin: f32, temp_ini: f32, duration: f32) f32 { // OK
    return temp_fin + (temp_ini - temp_fin) * @exp(-p.thermB() * duration);
}

fn coolingTemp(p: Processor, temp_ini: f32, duration: f32) f32 { // OK
    return heatingTemp(p, temp_ambiant, temp_ini, duration);
}

fn numberOfCollingIntervals(t: Task, p: Processor, temp_est: f32) usize {
    return (t.per_proc[p.pid].wcet - maximumDurationOfContExecution(t, p, temp_est)) /
        maximumDurationOfContExecution(t, p, p.temp_cutoff);
}

fn maxTempAllowedContExec(t: Task, p: Processor, rem_exec_time: f32) f32 {
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
fn tmds(graph: *TaskDAG) !void {
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
                const r = taskRank(t);
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
            const sttime = effectiveStartTime(task, proc);
            const temp_estim = coolingTemp(proc, proc.temp_cur, sttime - proc.avail);
            const estim = tett(task.data, proc, sttime, temp_estim);
            const schedule_compl_time = estim.fin_t + estim.fin_t + optimisticFinishTime(task, proc);
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
const MAX_BW = 1e6;
pub fn main() !void {
    // Platform.NPROC = 3
    platform = .{ .processors = .{
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
        .per_proc = .{
            .{ .wcet = 1, .steady_state_temp = 90 }, // p0
            .{ .wcet = 2, .steady_state_temp = 80 }, // p1
            .{ .wcet = 4, .steady_state_temp = 50 }, // p2
        },
    });
    try task_dag.appendNode(Task{ // t1
        .per_proc = .{
            .{ .wcet = 1, .steady_state_temp = 90 }, // p0
            .{ .wcet = 2, .steady_state_temp = 80 }, // p1
            .{ .wcet = 4, .steady_state_temp = 50 }, // p2
        },
    });
    try task_dag.appendNode(Task{ // t2
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
    try tmds(&task_dag);

    // results :
    for (task_dag.nodes.items, 0..) |nd, tid| {
        std.debug.print(
            "task_{} : from {d}s to {d}s on proc_{}\n",
            .{ tid, nd.data.actual_start_time.?, nd.data.actual_finish_time.?, nd.data.allocated_pid.? },
        );
    }
}

const testing = struct {
    const task = Task{
        .per_proc = .{
            .{ .wcet = 1, .steady_state_temp = 90 }, // p0
            .{ .wcet = 2, .steady_state_temp = 80 }, // p1
            .{ .wcet = 4, .steady_state_temp = 50 }, // p2
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
    test "maximumDurationOfContExecution" {}
};

test {
    _ = testing;
}
