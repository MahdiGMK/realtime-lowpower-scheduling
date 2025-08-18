const std = @import("std");
const base = @import("base.zig");
const TaskDAG = base.TaskDAG;
const Platform = base.Platform;
const Processor = base.Processor;
const ArrayList = @import("std").ArrayListUnmanaged;
const global = base.global;

/// OCT with an extra wcet - eq 7
const optimisticFinishTime = base.optimisticFinishTime;

/// rank_OCT - eq 8
const taskRank = base.taskRankOptimisticFinishTime;

/// EST - eq 5
const effectiveStartTime = base.effectiveStartTime;

/// EFT - eq 6 - redundant
// fn earliestFinishTime(node: *const TaskDAG.Node, platform: Platform, proc: Processor) f32 {
//     return effectiveStartTime(node, platform, proc) + node.data.per_proc[proc.pid].wcet;
// }

/// O_EFT - eq 9
fn optimisticEFT(node: *const TaskDAG.Node, platform: Platform, proc: Processor) f32 {
    return effectiveStartTime(node, platform, proc) +
        optimisticFinishTime(node, platform, proc);
}

pub fn schedule(dag: *TaskDAG, platform: *Platform) !void {
    var task_list = ArrayList(*TaskDAG.Node).empty;
    for (dag.nodes.items) |*nd|
        if (nd.dependencies.items.len == 0)
            try task_list.append(global.alloc, nd);
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
        var optest: u8 = undefined;
        var optoeft: u8 = std.math.inf(f32);

        for (platform.processors) |proc| {
            std.log.info("--checking proc{}\n", .{proc.pid});
            const oeft = optimisticEFT(task, platform.*, proc);
            std.log.info("  --opt-EFT : {}\n", .{oeft});
            if (oeft <= optoeft) {
                optproc = proc.pid;
                optest = effectiveStartTime(task, platform.*, proc);
                optoeft = oeft;
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

        for (task.dependants.items) |it| {
            const nd, _ = it;
            nd.solved_deps += 1;
            if (nd.solved_deps == nd.dependencies.items.len) {
                try task_list.append(global.alloc, nd);
            }
        }
    }
}
