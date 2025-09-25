#!/usr/bin/env python3
"""
pidtree_trace.py

Description:
------------
Traces process execution in real-time using eBPF to detect which processes
spawn others. Useful for container visibility, attack forensics, and process
lineage tracking.

Example:
--------
sudo ./pidtree_trace.py
sudo ./pidtree_trace.py --filter container1
"""

from bcc import BPF
import os
import time
import subprocess
import psutil
import argparse
import signal

bpf_text = """
#include <linux/sched.h>
#include <uapi/linux/ptrace.h>

struct data_t {
    u32 ppid;
    u32 pid;
    char comm[16];
};

BPF_PERF_OUTPUT(events);

int trace_exec(struct pt_regs *ctx, struct task_struct *p) {
    struct data_t data = {};
    data.pid = p->pid;
    data.ppid = p->real_parent->pid;
    bpf_get_current_comm(&data.comm, sizeof(data.comm));
    events.perf_submit(ctx, &data, sizeof(data));
    return 0;
}
"""

parser = argparse.ArgumentParser()
parser.add_argument("--log", action="store_true", help="Print raw log format")
parser.add_argument("--filter", type=str, help="Filter by container name or PID")
args = parser.parse_args()

b = BPF(text=bpf_text)
b.attach_kprobe(event="do_execve", fn_name="trace_exec")

def get_pid_container_map():
    pid_map = {}
    for pid in psutil.pids():
        try:
            with open(f"/proc/{pid}/cgroup") as f:
                for line in f:
                    if "docker" in line or "kubepods" in line:
                        cid = line.strip().split('/')[-1]
                        name = subprocess.getoutput(f"docker ps --filter id={cid} --format '{{{{.Names}}}}'")
                        if name:
                            pid_map[pid] = name
                        else:
                            pid_map[pid] = cid[:12]
        except:
            continue
    return pid_map

def handler(cpu, data, size):
    event = b["events"].event(data)
    pid = event.pid
    ppid = event.ppid
    comm = event.comm.decode()

    pid_map = get_pid_container_map()
    container = pid_map.get(pid, "host")

    if args.filter and args.filter not in container and args.filter != str(pid):
        return

    if args.log:
        print(f"[PROC] container={container} pid={pid} ppid={ppid} comm={comm}")
    else:
        print(f"{container:<20} {pid:<6} <- {ppid:<6} {comm}")

print(f"{'Container':<20} {'PID':<6} {'<- PPID':<10} CMD")

signal.signal(signal.SIGINT, lambda x, y: exit(0))
b["events"].open_perf_buffer(handler)

while True:
    b.perf_buffer_poll()
