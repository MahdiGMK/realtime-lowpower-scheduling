const std = @import("std");
const base = @import("base.zig");
const TaskDAG = base.TaskDAG;
const Platform = base.Platform;
const Processor = base.Processor;
const ArrayList = @import("std").ArrayListUnmanaged;
const global = base.global;

var makespan1: f32 = 0;
var avglat: f32 = 0;
var avgbw: f32 = 0;
var dlt_buf: std.AutoHashMap(*TaskDAG.Node, f32) = undefined;
fn DLT(task: *TaskDAG.Node) f32 {
    var mx: f32 = 0;
    for (task.dependants.items) |nd| {
        const avgcom = avglat + nd.@"1".data_transfer / avgbw;
        mx = @max(mx, nd.@"0".data.actual_start_time.? - avgcom);
    }
    return makespan1 - mx;
}
fn taskRank(task: *TaskDAG.Node, platform: Platform) f32 {
    _ = platform;
    return dlt_buf.get(task).?;
}

pub fn schedule(dag: *TaskDAG, platform: *Platform) !void {
    avgbw = base.avgCommunicationBW(platform.*);
    avglat = base.avgCommunicationLat(platform.*);

    try @import("tpeft.zig").schedule(dag, platform);
    makespan1 = 0;
    for (dag.nodes.items) |nd| makespan1 = @max(makespan1, nd.data.actual_finish_time.?);

    dlt_buf = .init(global.alloc);
    defer dlt_buf.deinit();
    for (dag.nodes.items) |*nd| try dlt_buf.put(nd, DLT(nd));
    // some extraction logic
    //
    base.resetSchedule(dag, platform);

    var task_list = try base.makeTaskList(dag);
    while (task_list.items.len > 0) {
        const task = base.extractBestTask(&task_list, platform.*, taskRank);
        var optproc: u8 = undefined;
        var optest: f32 = undefined;
        var optfunc = std.math.inf(f32);

        for (platform.processors) |proc| {
            std.log.info("--checking proc{}\n", .{proc.pid});
            const est = base.effectiveStartTime(task, platform.*, proc);
            const opt = est + dlt_buf.get(task).?;
            std.log.info("  --OPT : {}\n", .{opt});
            if (opt <= optfunc) {
                optproc = proc.pid;
                optest = est;
                optfunc = opt;
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
