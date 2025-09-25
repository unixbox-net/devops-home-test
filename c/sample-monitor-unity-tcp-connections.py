#!/usr/bin/env python3

"""
unity_tcp_monitor.py – Unity Server TCP Connection Tracer

This BCC/eBPF-based tool traces incoming **TCP connections** to a Unity game server
on a **specific port (default: 7777)** and reports remote IPs, ports, and resolves
the PID of the Unity server listener. The tracing occurs at the kernel level and
is filtered for `TCP_ESTABLISHED` states only, ensuring only successful connections
are reported.

---

Summary

• Target Port:
    - Hardcoded to Unity server TCP port `7777`
• Tracepoint:
    - Hooks `tcp_set_state()` to ensure connections are fully negotiated
• Trigger Condition:
    - Fires only when TCP state becomes `TCP_ESTABLISHED`
• Reported Data:
    - Remote client IP and port
    - Server port
    - PID of the Unity server (resolved via `ss -ntpln`)
• Safety:
    - Uses `bpf_probe_read_kernel()` for verified safe access
    - User-space `ss` is used instead of unreliable kernel PID tracking

---

Use Cases

• Real-time audit of Unity client connection attempts
• Troubleshoot firewall/NAT or dropped client connections
• Monitor connection counts during performance/load tests
• ‍Validate Unity server accept behavior in multiplayer scenarios
• Correlate PID with container, systemd unit, or resource usage

---

Implementation Notes

• Why `tcp_set_state()`?
    - Guarantees the socket is in a stable state
    - Safer and later in connection lifecycle than `inet_csk_accept()`

• Why is PID resolved in user-space?
    - `tcp_set_state()` may run in kernel context or softirq
    - Kernel context lacks access to reliable `task_struct` → `pid`
    - So we run `ss -ntpln` once at startup and extract the `pid=` field

• IPv4 only:
    - Uses `inet_ntop(AF_INET)` for simplicity
    - Can be extended to support IPv6 with minimal changes

---

Example Output

Testing: 

remote:
nc -vz 10.200.0.183 7777

shows:
Monitoring fully established TCP connections on Unity port 7777...

[CONNECTED] Unity:7777 <= 10.100.10.150:43896 (pid 2987)
[CONNECTED] Unity:7777 <= 10.100.10.150:43906 (pid 2987)
[CONNECTED] Unity:7777 <= 10.100.10.150:43910 (pid 2987)
[CONNECTED] Unity:7777 <= 10.100.10.150:43912 (pid 2987)

---
"""

from bcc import BPF
import socket
import struct
import subprocess

PORT = 7777
TCP_ESTABLISHED = 1

bpf_text = f"""
#include <uapi/linux/ptrace.h>
#include <net/sock.h>
#include <bcc/proto.h>

struct data_t {{
    u32 saddr;
    u32 daddr;
    u16 sport;
    u16 dport;
}};
BPF_PERF_OUTPUT(events);

int trace_tcp_state(struct pt_regs *ctx, struct sock *sk, int state) {{
    if (state != {TCP_ESTABLISHED})
        return 0;

    u16 sport = 0, dport = 0;
    bpf_probe_read_kernel(&sport, sizeof(sport), &sk->__sk_common.skc_num);
    bpf_probe_read_kernel(&dport, sizeof(dport), &sk->__sk_common.skc_dport);
    dport = ntohs(dport);
    if (sport != {PORT})
        return 0;

    struct data_t data = {{
        .sport = sport,
        .dport = dport
    }};
    bpf_probe_read_kernel(&data.saddr, sizeof(data.saddr), &sk->__sk_common.skc_rcv_saddr);
    bpf_probe_read_kernel(&data.daddr, sizeof(data.daddr), &sk->__sk_common.skc_daddr);

    events.perf_submit(ctx, &data, sizeof(data));
    return 0;
}}
"""

def ip(addr):
    return socket.inet_ntop(socket.AF_INET, struct.pack("I", addr))

def find_unity_pid():
    try:
        output = subprocess.getoutput("ss -ntpln")
        for line in output.splitlines():
            if f":{PORT} " in line and "pid=" in line:
                return line.split("pid=")[1].split(",")[0]
    except:
        pass
    return "?"

unity_pid = find_unity_pid()

def handle_event(cpu, data, size):
    e = b["events"].event(data)
    d_ip = ip(e.daddr)
    print(f"[CONNECTED] Unity:{e.sport} <= {d_ip}:{e.dport} (pid {unity_pid})")

b = BPF(text=bpf_text)
b.attach_kprobe(event="tcp_set_state", fn_name="trace_tcp_state")

print(f"Monitoring fully established TCP connections on Unity port {PORT}...\n")
b["events"].open_perf_buffer(handle_event)

try:
    while True:
        b.perf_buffer_poll()
except KeyboardInterrupt:
    print("Monitor stopped.")
