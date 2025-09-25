#!/usr/bin/env python3
"""
# Socket Snoop - Realtime Socket Monitoring, @OR(ϵ)SOURCES

## Overview

The Socket Monitoring Tool is a powerful and lightweight solution designed for system administrators who need real-time insights into socket-level network activity on their systems. By leveraging eBPF, this tool provides detailed logs of connection states, including source and destination IP addresses, ports, process IDs (PIDs), and associated commands (COMM), as well as TCP state transitions.

FEATURES:
Captures TCP state changes (inet_sock_set_state tracepoint).
Monitors key TCP connection states like SYN_SENT, FIN_WAIT, and TIME_WAIT.
Tracks TCP retransmissions (tcp_retransmit_skb tracepoint), a key indicator of network issues.
Logs the process ID (PID) and command name (COMM) associated with each connection.
Logs connection details (source/destination IP and port, process ID, and state) to /var/log/socket_monitor.log.
Skips noisy or invalid entries, like connections with IP 0.0.0.0.
Maps TCP states to human-readable descriptions.
Formats IP addresses for readability.
Uses perf_buffer for real-time event handling.
Can run continuously and provide live updates via the console and log file.

Real-Time Logging: Captures and logs socket connections as they occur.
Detailed Insights: Provides source and destination IP addresses, ports, PIDs, command names, and TCP states.
Formatted Output: Logs are time-stamped and categorized (e.g., Opened Connection, Closed Connection, Established Connection).
Lightweight and Efficient: Runs efficiently using eBPF without significant performance overhead.

BENEFITS:
Simplifies network monitoring by highlighting key details often buried in more complex tools.
Reduces the need for deep packet analysis with tools like tcpdump or wireshark.
Enhances operational awareness for system administrators managing critical infrastructure.

LIMITATIONS:
IP4 only (wip)
Need to add Dynamic Filters / pid/ip/ports
Enhance Error Handling
Perfomance Tuning

## Use Cases

Security Monitoring: Detect suspicious or unauthorized network activity.
Performance Debugging: Identify network latency or dropped connections by observing TCP states.
Audit Logging: Maintain a comprehensive record of all socket-level network interactions.
Real-Time Monitoring: Observe live network activity without the complexity of tools like tcpdump or wireshark. In addition, no network frames are captured so it's perfect for high security networks.

## Install
For the script version simply ensure you have python 3.11+

pip install bcc
python3 /root/scripts/socket-snoop.py

or as a service 

cat <<EOF > /etc/systemd/system/sockets-monitor.service
[Unit]
Description=Socket Monitoring Service
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /root/scripts/sockets.py  #edit to taste
Restart=on-failure
StandardOutput=syslog
StandardError=syslog
SyslogIdentifier=sockets-monitor
WorkingDirectory=/root/scripts/  #edit to taste
User=root
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF

and

systemctl daemon-reload
systemctl enable sockets-monitor
systemctl start sockets-monitor
systemctl status sockets-monitor


### Log Examples

Sample: /var/log/socket_monitor.log

Dec 30 2024 22:05:25.454 State Change: SRC=10.100.10.150:39134 DST=10.100.10.202:8000 PID=30512 COMM=audacious STATE=Connection Closing (FIN_WAIT1)
Dec 30 2024 22:05:25.455 State Change: SRC=10.100.10.150:39134 DST=10.100.10.202:8000 PID=30512 COMM=audacious STATE=Connection Closed
Dec 30 2024 22:05:25.455 State Change: SRC=10.100.10.150:0 DST=10.100.10.202:8000 PID=30512 COMM=audacious STATE=Connection Opening (SYN_SENT)
Dec 30 2024 22:05:25.455 State Change: SRC=10.100.10.150:39136 DST=10.100.10.202:8000 PID=0 COMM=swapper/4 STATE=Connection Established
Dec 30 2024 22:05:25.836 State Change: SRC=10.100.10.150:39136 DST=10.100.10.202:8000 PID=30512 COMM=audacious STATE=Connection Closing (FIN_WAIT1)
Dec 30 2024 22:05:25.836 State Change: SRC=10.100.10.150:39136 DST=10.100.10.202:8000 PID=30512 COMM=audacious STATE=Connection Closed
Dec 30 2024 22:05:25.836 State Change: SRC=10.100.10.150:0 DST=10.100.10.202:8000 PID=30512 COMM=audacious STATE=Connection Opening (SYN_SENT)
Dec 30 2024 22:05:25.836 State Change: SRC=10.100.10.150:39148 DST=10.100.10.202:8000 PID=0 COMM=swapper/6 STATE=Connection Established
Dec 30 2024 22:05:28.180 State Change: SRC=10.100.10.150:39148 DST=10.100.10.202:8000 PID=30512 COMM=audacious STATE=Connection Closing (FIN_WAIT1)
Dec 30 2024 22:05:28.180 State Change: SRC=10.100.10.150:39148 DST=10.100.10.202:8000 PID=30512 COMM=audacious STATE=Connection Closed
Dec 30 2024 22:05:28.180 State Change: SRC=10.100.10.150:0 DST=10.100.10.202:8000 PID=30512 COMM=audacious STATE=Connection Opening (SYN_SENT)
Dec 30 2024 22:05:28.180 State Change: SRC=10.100.10.150:41994 DST=10.100.10.202:8000 PID=0 COMM=swapper/7 STATE=Connection Established
Dec 30 2024 22:05:28.315 State Change: SRC=10.100.10.150:0 DST=10.100.10.202:8000 PID=30512 COMM=pool-audacious STATE=Connection Opening (SYN_SENT)
Dec 30 2024 22:05:28.316 State Change: SRC=10.100.10.150:42006 DST=10.100.10.202:8000 PID=0 COMM=swapper/5 STATE=Connection Established
Dec 30 2024 22:05:28.592 State Change: SRC=10.100.10.150:42006 DST=10.100.10.202:8000 PID=30512 COMM=pool-audacious STATE=Connection Closing (FIN_WAIT1)
Dec 30 2024 22:05:28.592 State Change: SRC=10.100.10.150:42006 DST=10.100.10.202:8000 PID=30512 COMM=pool-audacious STATE=Connection Closed
Dec 30 2024 22:05:32.526 State Change: SRC=10.100.10.150:53046 DST=185.199.108.133:443 PID=3678 COMM=Chrome_ChildIOT STATE=Connection Closing (FIN_WAIT1)
Dec 30 2024 22:05:32.526 State Change: SRC=10.100.10.150:34984 DST=185.199.108.154:443 PID=3678 COMM=Chrome_ChildIOT STATE=Connection Closing (FIN_WAIT1)
Dec 30 2024 22:05:32.526 State Change: SRC=10.100.10.150:34994 DST=185.199.108.154:443 PID=3678 COMM=Chrome_ChildIOT STATE=Connection Closing (FIN_WAIT1)

### Breakdown's

Example 1:
Dec 30 2024 13:44:03.309 Connection Established: SRC=10.100.10.150:59660 DST=104.18.34.222:443 PID=0 COMM=swapper/7

*  Timestamp: Dec 30 2024 13:44:03.309
*  Event Type: Connection Established
*  Source (SRC): 10.100.10.150 (source IP) and 59660 (source port)
*  Destination (DST): 104.18.34.222 (destination IP) and 443 (destination port)
*  Process ID (PID): 0 (kernel-managed thread)
*  Command Name (COMM): swapper/7 (kernel idle thread for CPU core 7)

Example 2:

Dec 30 2024 13:44:03.345 Connection Opening (SYN_SENT): SRC=10.100.10.150:0 DST=35.244.154.8:443 PID=3382 COMM=Chrome_ChildIOT

*  Timestamp: Dec 30 2024 13:44:03.345
*  Event Type: Connection Opening (SYN_SENT)
*  Source (SRC): 10.100.10.150 (source IP) and 0 (port not yet assigned as connection is opening)
*  Destination (DST): 35.244.154.8 (destination IP) and 443 (destination port)
*  Process ID (PID): 3382 (user-space process ID)
*  Command Name (COMM): Chrome_ChildIOT (child process of Chrome browser)

Example 3:

Monitoring socket connections with enhanced metrics. Logs will be written to /var/log/socket_monitor.log
Dec 30 2024 22:00:46.334 State Change: SRC=10.100.10.150:22 DST=10.100.10.197:62382 PID=0 COMM=swapper/0 STATE=Connection Closing (CLOSE_WAIT)
Dec 30 2024 22:00:46.337 State Change: SRC=10.100.10.150:22 DST=10.100.10.197:62382 PID=43190 COMM=sshd-session STATE=Connection Closing (LAST_ACK)
Dec 30 2024 22:00:46.350 State Change: SRC=10.100.10.150:22 DST=10.100.10.197:62382 PID=0 COMM=swapper/0 STATE=Connection Closed
Dec 30 2024 22:00:46.372 State Change: SRC=10.100.10.150:22 DST=10.100.10.197:62383 PID=0 COMM=swapper/3 STATE=Connection Closing (CLOSE_WAIT)
Dec 30 2024 22:00:46.375 State Change: SRC=10.100.10.150:22 DST=10.100.10.197:62383 PID=43194 COMM=sshd-session STATE=Connection Closing (LAST_ACK)
Dec 30 2024 22:00:46.377 State Change: SRC=10.100.10.150:22 DST=10.100.10.197:62383 PID=0 COMM=swapper/3 STATE=Connection Closed
Dec 30 2024 22:00:47.799 State Change: SRC=10.100.10.150:22 DST=10.100.10.197:62407 PID=0 COMM=swapper/5 STATE=Connection Established
Dec 30 2024 22:00:47.929 State Change: SRC=10.100.10.150:22 DST=10.100.10.197:62408 PID=0 COMM=swapper/7 STATE=Connection Established

Connection Report:

Stopping monitoring...

Connection Lifecycles:
Connection: 10.100.10.150:22 -> 10.100.10.197:62382
  Dec 30 2024 22:00:46.334: Connection Closing (CLOSE_WAIT)
  Dec 30 2024 22:00:46.337: Connection Closing (LAST_ACK)
  Dec 30 2024 22:00:46.350: Connection Closed
Connection: 10.100.10.150:22 -> 10.100.10.197:62383
  Dec 30 2024 22:00:46.372: Connection Closing (CLOSE_WAIT)
  Dec 30 2024 22:00:46.375: Connection Closing (LAST_ACK)
  Dec 30 2024 22:00:46.377: Connection Closed
Connection: 10.100.10.150:22 -> 10.100.10.197:62407
  Dec 30 2024 22:00:47.799: Connection Established
Connection: 10.100.10.150:22 -> 10.100.10.197:62408
  Dec 30 2024 22:00:47.929: Connection Established

The following is an example output of the tool monitoring SSH connections (SRC=10.100.10.150:22) between a server and a client (DST=10.100.10.197):

A connection lifecycle starts with an Established state, 
transitions through CLOSE_WAIT, 
and eventually reaches Closed.
Each state change is associated with the process managing it (e.g., sshd-session or swapper).
"""

import argparse
import hashlib
import os
import sys
from datetime import datetime
from collections import deque

def parse_args():
    p = argparse.ArgumentParser(description="Enhanced Socket Monitoring Script")
    p.add_argument("--pid", type=int, default=None, help="Filter by PID")
    p.add_argument("--src-ip", type=str, default=None, help="Filter by source IPv4")
    p.add_argument("--dst-ip", type=str, default=None, help="Filter by destination IPv4")
    p.add_argument("--src-port", type=int, default=None, help="Filter by source port")
    p.add_argument("--dst-port", type=int, default=None, help="Filter by destination port")
    p.add_argument("--active-only", action="store_true", help="Only established connections")
    p.add_argument("--log-file", default=os.environ.get("SOCKET_SNOOP_LOG", "/var/log/socket_monitor.log"))
    return p.parse_args()

BPF_PROGRAM = r"""
#include <uapi/linux/ptrace.h>
#include <uapi/linux/in.h>
#include <linux/tcp.h>
#include <linux/sched.h>
#include <bcc/proto.h>

struct data_t {
    u32 pid;
    u32 ppid;
    char comm[TASK_COMM_LEN];
    u32 src_ip;
    u32 dst_ip;
    u16 src_port;
    u16 dst_port;
    int state;
    char event[16];
    u32 uid;
};
BPF_PERF_OUTPUT(events);

TRACEPOINT_PROBE(sock, inet_sock_set_state) {
    if (args->family != AF_INET)
        return 0;

    struct data_t data = {};
    u64 pid_tgid = bpf_get_current_pid_tgid();
    data.pid = pid_tgid >> 32;
    data.uid = bpf_get_current_uid_gid();
    bpf_get_current_comm(&data.comm, sizeof(data.comm));

    // parent PID (verifier-safe)
    struct task_struct *task = (struct task_struct *)bpf_get_current_task();
    u32 ppid = 0;
    if (task && task->real_parent) {
        bpf_probe_read_kernel(&ppid, sizeof(ppid), &task->real_parent->tgid);
    }
    data.ppid = ppid;

    // Debian 13 (BCC 0.31) uses __u8[4] for saddr/daddr in this tracepoint
    data.src_ip = ((u32)args->saddr[0] << 24) |
                  ((u32)args->saddr[1] << 16) |
                  ((u32)args->saddr[2] <<  8) |
                  ((u32)args->saddr[3]);
    data.dst_ip = ((u32)args->daddr[0] << 24) |
                  ((u32)args->daddr[1] << 16) |
                  ((u32)args->daddr[2] <<  8) |
                  ((u32)args->daddr[3]);

    data.src_port = ntohs(args->sport);
    data.dst_port = ntohs(args->dport);
    data.state = args->newstate;

    __builtin_strncpy(data.event, "State Change", sizeof(data.event));
    events.perf_submit(args, &data, sizeof(data));
    return 0;
}
"""

TCP_STATES = {
    1: "Connection Established",
    2: "Connection Opening (SYN_SENT)",
    3: "Connection Opening (SYN_RECV)",
    4: "Connection Closing (FIN_WAIT1)",
    5: "Connection Closing (FIN_WAIT2)",
    6: "Connection Closed (TIME_WAIT)",
    7: "Connection Closed",
    8: "Connection Closing (CLOSE_WAIT)",
    9: "Connection Closing (LAST_ACK)",
    10: "Listening for Connections",
    11: "Connection Closing (CLOSING)",
}

def format_ip(ip_u32: int) -> str:
    return ".".join(str((ip_u32 >> s) & 0xFF) for s in (24, 16, 8, 0))

def connection_id(src_ip, src_port, dst_ip, dst_port) -> str:
    unique = f"{src_ip}:{src_port}->{dst_ip}:{dst_port}"
    return hashlib.md5(unique.encode()).hexdigest()

def main():
    if os.uname().sysname.lower() != "linux":
        print("This tool requires Linux (eBPF/BCC).", file=sys.stderr)
        sys.exit(1)

    args = parse_args()

    log_file = args.log_file
    try:
        if not os.path.exists(log_file):
            with open(log_file, "w") as f:
                f.write("Enhanced Socket Monitoring Log\n" + "=" * 60 + "\n")
    except PermissionError:
        print(f"Warning: cannot write to {log_file}; falling back to ./socket_monitor.log", file=sys.stderr)
        log_file = "./socket_monitor.log"

    from bcc import BPF   # lazy import so tests don’t need bcc
    b = BPF(text=BPF_PROGRAM)

    metrics = {
        "active_connections": 0,
        "closing_connections": 0,
        "closed_connections": 0,
    }
    recent_events = deque(maxlen=2000)

    def handle_event(cpu, data, size):
        event = b["events"].event(data)
        state_str = TCP_STATES.get(event.state, "UNKNOWN STATE")
        timestamp = datetime.now().strftime("%b %d %Y %H:%M:%S.%f")[:-3]

        src_ip = format_ip(event.src_ip)
        dst_ip = format_ip(event.dst_ip)

        if args.pid and event.pid != args.pid: return
        if args.src_ip and src_ip != args.src_ip: return
        if args.dst_ip and dst_ip != args.dst_ip: return
        if args.src_port and event.src_port != args.src_port: return
        if args.dst_port and event.dst_port != args.dst_port: return
        if args.active_only and event.state != 1: return

        if event.state == 1:
            metrics["active_connections"] += 1
        elif event.state in (4,5,8,9,11):
            metrics["closing_connections"] += 1
        elif event.state in (6,7):
            if metrics["active_connections"] > 0:
                metrics["active_connections"] -= 1
            metrics["closed_connections"] += 1

        event_key = (src_ip, int(event.src_port), dst_ip, int(event.dst_port),
                     int(event.pid), int(event.state))
        if event_key in recent_events:
            return
        recent_events.append(event_key)

        entry = {
            "timestamp": timestamp,
            "event": event.event.decode(errors="ignore"),
            "src_ip": src_ip,
            "dst_ip": dst_ip,
            "src_port": int(event.src_port),
            "dst_port": int(event.dst_port),
            "protocol": "TCP",
            "state": state_str,
            "connection_id": connection_id(src_ip, int(event.src_port), dst_ip, int(event.dst_port)),
            "metrics": dict(metrics),
            "pid": int(event.pid),
            "ppid": int(event.ppid),
            "uid": int(event.uid),
            "comm": event.comm.decode(errors="ignore"),
        }

        print(entry)
        try:
            with open(log_file, "a") as f:
                f.write(str(entry) + "\n")
        except Exception as e:
            print(f"Log write failed: {e}", file=sys.stderr)

    b["events"].open_perf_buffer(handle_event)
    print(f"Monitoring socket connections. Logging to {log_file}")
    try:
        while True:
            b.perf_buffer_poll()
    except KeyboardInterrupt:
        print("\nStopping monitoring...")

if __name__ == "__main__":
    main()
