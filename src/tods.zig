const std = @import("std");
const base = @import("base.zig");
const Task = base.Task;
const TaskDAG = base.TaskDAG;
const Platform = base.Platform;
const Processor = base.Processor;
const ArrayList = @import("std").ArrayListUnmanaged;
const global = base.global;

var avglat: f32 = undefined;
var avgbw: f32 = undefined;

var urv_mem: std.AutoHashMap(*const TaskDAG.Node, f32) = undefined;
fn urv(task: *const TaskDAG.Node) !f32 {
    if (urv_mem.get(task)) |val| return val;

    var res: f32 = 0;
    for (0..Platform.NPROC) |pid| res += task.data.per_proc[pid].wcet;
    res /= Platform.NPROC;

    var mx: f32 = 0;
    for (task.dependants.items) |nd| {
        mx = @max(mx, avglat + nd.@"1".data_transfer / avgbw + try urv(nd.@"0"));
    }
    res += mx;

    try urv_mem.put(task, res);
    return res;
}
fn taskRank(task: *const TaskDAG.Node, platform: Platform) f32 {
    _ = platform; // autofix
    return (urv(task) catch @panic("OOM"));
}
fn energyConsumptionEst(task: Task, proc: Processor) f32 {
    return task.per_proc[proc.pid].wcet * task.per_proc[proc.pid].steady_state_temp;
}
fn internalSchedule(dag: *TaskDAG, platform: *Platform, odq: []const usize, l: usize) !void {
    base.resetSchedule(dag, platform);

    var task_list = try base.makeTaskList(dag);
    while (task_list.items.len > 0) {
        const task = base.extractBestTask(&task_list, platform.*, taskRank);
        var optproc: u8 = undefined;
        var optest: f32 = undefined;
        var optfunc = std.math.inf(f32);

        if (task.dependants.items.len >= odq[l]) {
            // in range
            // assuming R==1 => we should minimize "finish_time(task, proc)"
            for (platform.processors) |proc| {
                const est = base.effectiveStartTime(task, platform.*, proc);
                const eft = est + task.data.per_proc[proc.pid].wcet;
                if (eft <= optfunc) {
                    optproc = proc.pid;
                    optest = est;
                    optfunc = eft;
                }
            }
        } else {
            // out of range
            // assuming energyConsumptionEst corrolates with energyConsumption
            // => we should minimize energyConsumptionEst
            for (platform.processors) |proc| {
                const estim = energyConsumptionEst(task.data, proc);
                if (estim <= optfunc) {
                    optfunc = estim;
                    optest = base.effectiveStartTime(task, platform.*, proc);
                    optproc = proc.pid;
                }
            }
        }

        const proc: *Processor = &platform.processors[optproc];
        const temp_est = base.coolingTemp(proc.*, proc.temp_cur, optest - proc.avail);
        const thermal_est = base.tett(task.data, proc.*, optest, temp_est);
        task.data.allocated_pid = optproc;
        task.data.actual_start_time = optest;
        task.data.actual_finish_time = thermal_est.fin_t;
        proc.temp_cur = thermal_est.fin_temp;
        proc.avail = thermal_est.fin_t;

        try task.markAsSolved(&task_list);
    }
}
pub fn schedule(dag: *TaskDAG, platform: *Platform) !void {
    avgbw = base.avgCommunicationBW(platform.*);
    avglat = base.avgCommunicationLat(platform.*);

    urv_mem = .init(global.alloc);
    defer urv_mem.deinit();

    const odq = try global.alloc.alloc(usize, dag.nodes.items.len);
    defer global.alloc.free(odq);

    for (dag.nodes.items, odq) |*nd, *od| od.* = nd.dependants.items.len;
    std.mem.sort(usize, odq, void{}, std.sort.desc(usize));

    var best_l: usize = undefined;
    var best_makespan = std.math.inf(f32);
    for (0..odq.len) |l| {
        try internalSchedule(dag, platform, odq, l);

        var mkspan: f32 = 0;
        for (dag.nodes.items) |nd| mkspan = @max(mkspan, nd.data.actual_finish_time.?);

        if (mkspan <= best_makespan) {
            best_makespan = mkspan;
            best_l = l;
        }
    }

    try internalSchedule(dag, platform, odq, best_l);
}
