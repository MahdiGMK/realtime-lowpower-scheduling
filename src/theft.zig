const std = @import("std");
const base = @import("base.zig");
const TaskDAG = base.TaskDAG;
const Platform = base.Platform;
const Processor = base.Processor;
const ArrayList = @import("std").ArrayListUnmanaged;
const global = base.global;

var rank_mem: std.AutoHashMap(*const TaskDAG.Node, f32) = undefined;
var total_avg_lat = undefined;
var total_avg_bw = undefined;
fn taskRank(task: *const TaskDAG.Node, platform: Platform) f32 {
    if (rank_mem.get(task)) |rnk| return rnk;
    var mx: f32 = 0;
    for (task.dependants.items) |dep| {
        const nd, const com = dep;
        mx = @max(
            mx,
            com.data_transfer / total_avg_bw + total_avg_lat +
                taskRank(nd, platform),
        );
    }
    const res = base.avgWCET(task.data) + mx;
    rank_mem.put(task, res);
    return res;
}

pub fn schedule(dag: *TaskDAG, platform: *Platform) !void {
    // initial
    total_avg_bw = 0;
    total_avg_lat = 0;
    for (0..Platform.NPROC) |pid| {
        total_avg_bw += base.avgCommunicationBW(platform, pid);
        total_avg_lat += base.avgCommunicationLat(platform, pid);
    }
    total_avg_bw /= Platform.NPROC;
    total_avg_lat /= Platform.NPROC;
    rank_mem = .init(global.alloc);
    defer rank_mem.deinit();

    var task_list = try base.makeTaskList(dag);
    while (task_list.items.len > 0) {
        const task = base.extractBestTask(&task_list, platform, taskRank);

        std.log.info("selected task : {}\n", .{task.data.id});
        var opteft = std.math.inf(f32);
        var optproc: u8 = undefined;
        var optest: f32 = undefined;
        for (platform.processors) |proc| {
            std.log.info("--checking proc{}\n", .{proc.pid});
            // eq 5
            const est = base.effectiveStartTime(task, platform, proc);
            // eq 6
            const eft = est + task.data.per_proc[proc.pid].wcet;
            std.log.info("  --EST : {}\n", .{est});
            std.log.info("  --EFT : {}\n", .{eft});
            if (eft <= opteft) {
                opteft = eft;
                optproc = proc.pid;
                optest = est;
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
