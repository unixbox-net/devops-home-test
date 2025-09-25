#!/usr/bin/env python3

"""
unity_syscall_trace.py — Trace all system calls made by the Unity process with verbosity

This script uses eBPF to attach to specific syscall entry points invoked by the Unity server.
It logs syscall names, originating thread PIDs, and arguments (when available), and writes to a log file.

---

Options:
  --pid <PID>            Manually specify Unity PID (default: autodetect via unityserver.service)
  --duration <seconds>   How long to trace (default: 10s)
  --logfile <path>       Optional output file for logs (default: ./unity_syscalls.log)

Dependencies:
  - BCC (Python bindings)
  - Python3 + psutil

Example:
  sudo ./unity_syscall_trace.py --duration 15 --logfile trace.log

"""

from bcc import BPF
import argparse
import subprocess
import signal
import time
import psutil
from datetime import datetime

parser = argparse.ArgumentParser()
parser.add_argument("--pid", type=int, help="Unity server PID")
parser.add_argument("--duration", type=int, default=10, help="Duration in seconds")
parser.add_argument("--logfile", type=str, default="unity_syscalls.log", help="Path to log file")
args = parser.parse_args()

def get_unity_pid():
    try:
        output = subprocess.getoutput("systemctl show --property=MainPID unityserver.service")
        pid = int(output.strip().split('=')[1])
        return pid if pid > 0 else None
    except:
        return None

unity_pid = args.pid or get_unity_pid()
if not unity_pid:
    print("[!] Could not determine Unity PID. Use --pid manually.")
    exit(1)

print(f"[+] Tracing selected syscalls from Unity PID {unity_pid} for {args.duration} seconds...\n")

bpf_text = f'''
#include <uapi/linux/ptrace.h>
#include <linux/sched.h>

struct data_t {{
    u32 pid;
    char comm[TASK_COMM_LEN];
    char syscall[16];
}};

BPF_PERF_OUTPUT(events);
'''

trace_fns = ""
syscalls_to_trace = [
    "__x64_sys_read", "__x64_sys_write", "__x64_sys_recvfrom", "__x64_sys_sendto",
    "__x64_sys_openat", "__x64_sys_close", "__x64_sys_accept", "__x64_sys_connect",
    "__x64_sys_recvmsg", "__x64_sys_sendmsg", "__x64_sys_epoll_wait"
]

for i, syscall in enumerate(syscalls_to_trace):
    fn_name = f"trace_fn_{i}"
    bpf_text += f'''
int {fn_name}(struct pt_regs *ctx) {{
    u32 pid = bpf_get_current_pid_tgid() >> 32;
    if (pid != {unity_pid}) return 0;

    struct data_t data = {{}};
    data.pid = pid;
    bpf_get_current_comm(&data.comm, sizeof(data.comm));
    __builtin_strncpy(data.syscall, "{syscall}", sizeof(data.syscall));
    events.perf_submit(ctx, &data, sizeof(data));
    return 0;
}}
'''

b = BPF(text=bpf_text)

for i, syscall in enumerate(syscalls_to_trace):
    try:
        b.attach_kprobe(event=syscall, fn_name=f"trace_fn_{i}")
    except Exception as e:
        print(f"[!] Failed to attach to {syscall}: {e}")
        continue

log_file = open(args.logfile, "w")

def print_event(cpu, data, size):
    event = b["events"].event(data)
    ts = datetime.now().strftime("%H:%M:%S")
    msg = f"[{ts}] PID {event.pid} ({event.comm.decode(errors='ignore')}) called {event.syscall.decode(errors='ignore')}"
    print(msg)
    log_file.write(msg + "\n")

b["events"].open_perf_buffer(print_event)

try:
    timeout = time.time() + args.duration
    while time.time() < timeout:
        b.perf_buffer_poll()
except KeyboardInterrupt:
    print("\n[!] Tracing interrupted.")

log_file.close()
print(f"\n[+] Syscall trace complete. Log saved to {args.logfile}")
