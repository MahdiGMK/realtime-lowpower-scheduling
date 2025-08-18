const std = @import("std");
const base = @import("base.zig");
const TaskDAG = base.TaskDAG;
const Platform = base.Platform;
const Processor = base.Processor;
const ArrayList = @import("std").ArrayListUnmanaged;
const global = base.global;

/// stupid function -- stored in the oft field of node - eq 5
fn PCM(n: *TaskDAG.Node, platform: Platform, p: Processor) f32 {
    if (n.data.per_proc[p.pid].optimistic_finish_time) |pcm| return pcm;
    if (n.dependants.items.len == 0) return n.data.per_proc[p.pid].wcet;

    var res: f32 = 0;
    for (n.dependants.items) |it| {
        const nn, const e = it;
        var rs = std.math.inf(f32);
        for (platform.processors) |np| {
            rs = @min(
                rs,
                PCM(nn, platform, np) +
                    nn.data.per_proc[np.pid].wcet +
                    e.data_transfer / platform.communication_bw[p.pid][np.pid] +
                    platform.communication_lat[p.pid][np.pid],
            );
        }
        res = @max(res, rs);
    }

    n.data.per_proc[p.pid].optimistic_finish_time = res + n.data.per_proc[p.pid].wcet;
    return n.data.per_proc[p.pid].optimistic_finish_time.?;
}

/// eq 6
fn taskRank(n: *TaskDAG.Node, platform: Platform) f32 {
    var res: f32 = 0;
    for (platform.processors) |p| {
        res += PCM(n, platform, p);
    }
    return res / Platform.NPROC;
}

/// eq 7
fn laEFT(n: *TaskDAG.Node, platform: Platform, p: Processor) f32 {
    return base.effectiveStartTime(n, platform, p) +
        n.data.per_proc[p.pid].wcet +
        PCM(n, platform, p);
}

pub fn schedule(dag: *TaskDAG, platform: *Platform) !void {
    var task_list = try base.makeTaskList(dag);

    while (task_list.items.len > 0) {
        const task = base.extractBestTask(&task_list, platform.*, taskRank);

        std.log.info("selected task : {}\n", .{task.data.id});
        var optproc: u8 = undefined;
        var optest: f32 = undefined;
        var optlaeft = std.math.inf(f32);

        for (platform.processors) |proc| {
            std.log.info("--checking proc{}\n", .{proc.pid});
            const laeft = laEFT(task, platform.*, proc);
            std.log.info("  --la-EFT : {}\n", .{laeft});
            if (laeft <= optlaeft) {
                optproc = proc.pid;
                optest = base.effectiveStartTime(task, platform.*, proc);
                optlaeft = laeft;
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
