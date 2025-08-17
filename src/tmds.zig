const std = @import("std");
const base = @import("base.zig");
const TaskDAG = base.TaskDAG;
const Platform = base.Platform;
const ArrayList = @import("std").ArrayListUnmanaged;
const global = base.global;

fn taskRank(n: *TaskDAG.Node, platform: Platform) f32 {
    var res: f32 = 0;
    for (platform.processors) |p| {
        res += base.optimisticFinishTime(n, platform, p);
    }
    return res / Platform.NPROC;
}
pub fn tmds(dag: *TaskDAG, platform: *Platform) !void {
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
        var opttemp: f32 = undefined;
        var optstrt: f32 = undefined;
        var optfin: f32 = undefined;
        var optcompl = std.math.inf(f32);
        for (platform.processors) |proc| {
            std.log.info("--checking proc{}\n", .{proc.pid});
            const sttime = base.effectiveStartTime(task, platform.*, proc);
            std.log.info("  --start-time : {}\n", .{sttime});
            const temp_estim = base.coolingTemp(proc, proc.temp_cur, sttime - proc.avail);
            std.log.info("  --start-temp : {}\n", .{temp_estim});
            const estim = base.tett(task.data, proc, sttime, temp_estim);
            std.log.info("  --end-temp : {}\n", .{estim.fin_temp});
            std.log.info("  --end-time : {}\n", .{estim.fin_t});

            const optimistic_dependant_completion =
                base.optimisticFinishTime(task, platform.*, proc) -
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
                try task_list.append(global.alloc, nd);
            }
        }
    }
}
