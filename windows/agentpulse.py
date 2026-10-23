#!/usr/bin/env python3
"""
AgentPulse · Windows Version
Agent 速度表 (Windows)

Usage:
  python agentpulse.py                  Launch HUD and background monitor
  python agentpulse.py --tools          List agent tools and session counts
  python agentpulse.py --dump-tool <id> [n] Dump stats for recent sessions
  python agentpulse.py --dump [files...]    Dump stats for specific log files
  python agentpulse.py --usage [7|30|90|all] [--tool <id>] Print token usage & costs
  python agentpulse.py --watch          Live terminal meter
  python agentpulse.py --web            Open web dashboard in browser
  python agentpulse.py --hud            Launch floating HUD only
  python agentpulse.py --demo           Run with demo data
"""
import sys
import os
import time
import argparse
from typing import Optional
import webbrowser
from datetime import datetime, timezone

# Add current folder to path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from agentpulse.models import SessionStats, RequestRecord, AgentSource
from agentpulse.format import Fmt
from agentpulse.tools import ToolRegistry, ToolScanner
from agentpulse.discovery import SessionDiscovery, SessionRef, Readers, Monitor
from agentpulse.usage import TokenUsageScanner, UsageAggregation, UsageRange
from agentpulse.web_dashboard import start_server
from agentpulse.hud import FloatingHUD
from agentpulse.tray import SystemTray

def print_stats(s: SessionStats, requests=None):
    print(f"== {s.source.display_name}  {s.project_name}  [{s.model or '?'}]")
    if s.uses_credits:
        print(f"   {s.turns} 轮 {s.steps} 步 · 最近5步 {Fmt.credits_number(s.display_recent_speed)} Credits/s · 最近一步 {Fmt.credits_number(s.display_last_speed)} Credits/s · 会话 {Fmt.credits_number(s.display_session_speed)} Credits/s")
        print(f"   实际 {Fmt.credits_number(s.credits)} Credits · 已知计费 {s.credit_requests} 次 · 缺失 {s.missing_credit_requests} 次 · 上下文 {Fmt.percent(s.context_fraction)}")
        for r in (requests or [])[-5:]:
            rate = (r.charged_credits / r.duration) if (r.has_request_start and r.duration >= 0.25 and r.charged_credits is not None) else None
            dur_str = Fmt.duration(r.duration if r.has_request_start else None)
            print(f"     credits={Fmt.credits_number(r.charged_credits)} billable={r.billable} dur={dur_str} rate={Fmt.credits_number(rate)} Credits/s")
        if s.speed_note:
            print(f"   注：{s.speed_note}")
        return

    print(f"   {s.turns} 轮 {s.steps} 步 · 最近5步 {Fmt.tps(s.recent_tps)} · 最近一步 {Fmt.tps(s.last_tps)} · 会话 {Fmt.tps(s.session_tps)}")
    print(f"   模型用时 {Fmt.duration(s.model_time)} · 工具用时 {Fmt.duration(s.tool_time)} · TTFT {Fmt.duration(s.avg_ttft) if s.ttft_available else 'n/a'}")
    print(f"   总 {Fmt.tokens(s.total_tokens)} · 缓存命中 {Fmt.percent(s.cache_hit_rate)} · 未缓存 {s.uncached_input} · 写缓存 {s.cache_write} · 读缓存 {s.cache_read} · 输出 {s.output_tokens}")
    ctx_total = Fmt.compact_tokens(s.context_window) if s.context_window else '?'
    est_str = " (估)" if s.context_window_is_estimate else ""
    print(f"   上下文 {Fmt.compact_tokens(s.context_tokens)} / {ctx_total}{est_str} = {Fmt.percent(s.context_fraction, digits=0)}")
    if s.waiting_since:
        now = datetime.now(timezone.utc)
        b = s.waiting_since if s.waiting_since.tzinfo else s.waiting_since.replace(tzinfo=timezone.utc)
        print(f"   生成中，已等待 {Fmt.short_elapsed((now - b).total_seconds())}")
    if s.speed_note:
        print(f"   注：{s.speed_note}")

    for r in (requests or [])[-5:]:
        tps = (r.output_tokens / r.decode_duration) if (r.has_request_start and r.output_tokens >= 20 and r.decode_duration >= 0.25) else None
        ttft_str = f"{r.ttft:.1f}s" if r.ttft is not None else "—"
        tps_str = f"{tps:.0f}" if tps is not None else "—"
        print(f"     out={r.output_tokens:6d}  dur={r.duration:6.1f}s  ttft={ttft_str}  tps={tps_str}  ctx={Fmt.compact_tokens(r.context_tokens)}")

def cmd_tools():
    for t in ToolScanner.scan():
        count_str = f"{len(SessionDiscovery.sessions_for(t.spec, limit=10000))} 个会话" if t.supported else (t.spec.note or "")
        sym = "✓" if t.supported else "·"
        print(f"{sym} {t.spec.name:<20} {t.install_kinds:<14} {count_str}")

def cmd_dump_tool(tool_id: str, count: int = 3):
    spec = ToolRegistry.spec(tool_id)
    if not spec:
        print(f"未知工具: {tool_id}")
        return
    sessions = SessionDiscovery.sessions_for(spec, limit=count)
    if not sessions:
        print(f"未找到 {spec.name} 的会话记录")
        return
    for ref in sessions:
        t0 = time.time()
        stats, requests = Readers.read_session(ref)
        print_stats(stats, requests)
        sub_str = "子代理 · " if ref.is_subagent else ""
        print(f"   {sub_str}{Fmt.relative(ref.modified)} · 解析 {time.time() - t0:.2f}s\n")

def cmd_dump(paths: list):
    if not paths:
        latest = Monitor.latest_session()
        if latest:
            print_stats(latest)
            return
        print("未指定日志路径且未发现活跃会话")
        return
    for p in paths:
        source = ToolRegistry.source_for_path(p)
        if not source:
            # Fallback to claude or codex based on filename
            src_id = "codex" if "rollout" in p else "claude"
            source = AgentSource(id=src_id)
        ref = SessionRef(path=p, source=source, modified=datetime.now(timezone.utc))
        stats, requests = Readers.read_session(ref)
        print_stats(stats, requests)

def cmd_usage(range_arg: str = "30", tool_id: Optional[str] = None):
    arg = range_arg.lower()
    r = UsageRange.ALL if arg == "all" else (UsageRange.WEEK if (int(arg) if arg.isdigit() else 30) <= 7 else (UsageRange.MONTH if (int(arg) if arg.isdigit() else 30) <= 30 else UsageRange.QUARTER))
    scanner = TokenUsageScanner()
    started = time.time()
    events = scanner.scan(since=UsageRange.start_date(r), source_id=tool_id)
    summary = UsageAggregation.summary(events, r, tool_id=tool_id)
    elapsed = time.time() - started

    print(f"== 用量统计 · {UsageRange.title(r)} · {summary.session_count} 个会话 · {summary.totals.requests} 次请求 · 用时 {elapsed:.1f}s")
    if summary.totals.total > 0 or not summary.totals.has_credit_data:
        print(f"   总 {Fmt.tokens(summary.totals.total)} · 输出 {Fmt.tokens(summary.totals.output)} · 输入 {Fmt.tokens(summary.totals.input)} · 缓存命中 {Fmt.percent(summary.totals.cache_hit_rate)}")
        print(f"   估算费用 {Fmt.usd(summary.cost.usd)} · 已计价 {Fmt.tokens(summary.cost.priced_tokens)} · 未匹配价格 {Fmt.tokens(summary.cost.unpriced_tokens)}")
    else:
        print("   Token 估算未启用：没有经过验证的换算规则")

    for t in summary.tools:
        if t.totals.has_credit_data:
            print(f"   {t.source.display_name}: 实际 {Fmt.credits_number(t.totals.credits)} Credits · {t.totals.credit_requests} 次有计费记录 · {t.totals.missing_credit_requests} 次缺失 · 平均 {Fmt.credits_number(t.totals.credit_rate)} Credits/s")
            if t.totals.total == 0:
                continue
        print(f"   {t.source.display_name}: 总 {Fmt.compact_tokens(t.totals.total)} · 输出 {Fmt.compact_tokens(t.totals.output)} · 未缓存 {Fmt.compact_tokens(t.totals.uncached_input)} · 读缓存 {Fmt.compact_tokens(t.totals.cache_read)} · 写缓存 {Fmt.compact_tokens(t.totals.cache_write)} · {t.totals.requests} 次请求 · {t.session_count} 个会话 · {Fmt.usd(t.cost.usd)}")

    for m in summary.models[:12]:
        cost_str = "价格未知" if m.cost.unpriced_tokens > 0 else Fmt.usd(m.cost.usd)
        print(f"   [模型] {m.display_name} ({m.model or 'unknown'}): {Fmt.compact_tokens(m.totals.total)} tok · {cost_str}")

def cmd_watch():
    print("[2J[H", end="")
    print("AgentPulse 速度表 · 实时监控 (按 Ctrl+C 退出)")
    try:
        while True:
            stats = Monitor.latest_session()
            print("[H", end="")
            now_str = datetime.now().strftime("%H:%M:%S")
            print(f"=== AgentPulse · {now_str} ===")
            if stats:
                print(f"工具: {stats.source.display_name} | 项目: {stats.project_name} | 模型: {stats.model or '?'}")
                speed_str = f"{stats.display_recent_speed:.1f} {stats.speed_unit}" if stats.display_recent_speed else "—"
                print(f"速度: {speed_str:<18} | 总 Token: {Fmt.compact_tokens(stats.total_tokens):<10} | 上下文: {Fmt.percent(stats.context_fraction):<8}")
                if stats.waiting_since:
                    print("状态: [32m● 模型生成中…[0m")
                else:
                    print("状态: ○ 等待下一轮输入")
            else:
                print("未检测到活跃会话...")
            time.sleep(1.0)
    except KeyboardInterrupt:
        print("\n已退出监控。")

def main():
    parser = argparse.ArgumentParser(description="AgentPulse · Agent 速度表 (Windows 版)")
    parser.add_argument("--tools", action="store_true", help="列出检测到的 agent 工具与会话数")
    parser.add_argument("--dump-tool", nargs="+", help="输出某个工具最近的会话统计")
    parser.add_argument("--dump", nargs="*", help="输出指定日志文件的会话统计")
    parser.add_argument("--usage", nargs="?", const="30", help="输出指定时间跨度的 token 用量与费用")
    parser.add_argument("--tool", help="搭配 --usage 指定只统计某工具")
    parser.add_argument("--watch", action="store_true", help="终端实时 tok/s 速度表")
    parser.add_argument("--web", action="store_true", help="启动并在浏览器中打开仪表盘")
    parser.add_argument("--hud", action="store_true", help="只启动桌面置顶悬浮条")
    parser.add_argument("--demo", action="store_true", help="加载演示数据")
    args = parser.parse_args()

    if args.tools:
        cmd_tools()
        return

    if args.dump_tool:
        tool_id = args.dump_tool[0]
        cnt = int(args.dump_tool[1]) if len(args.dump_tool) > 1 else 3
        cmd_dump_tool(tool_id, cnt)
        return

    if args.dump is not None:
        cmd_dump(args.dump)
        return

    if args.usage is not None:
        cmd_usage(args.usage, tool_id=args.tool)
        return

    if args.watch:
        cmd_watch()
        return

    if args.web:
        url = start_server(port=18989, open_browser=True)
        print(f"Web 仪表盘已启动: {url}")
        print("按 Ctrl+C 退出")
        try:
            while True: time.sleep(1)
        except KeyboardInterrupt:
            return

    # Default or --hud: Launch background web server + Desktop Floating HUD
    url = start_server(port=18989, open_browser=False)
    print(f"AgentPulse Windows 版已启动。")
    print(f"桌面悬浮条已显示，设置仪表盘地址: {url}")

    def open_dash():
        webbrowser.open(url)

    hud = FloatingHUD(on_open_settings=open_dash)
    tray = SystemTray(
        on_open_hud=lambda: hud.root.after(0, hud.root.deiconify),
        on_open_dashboard=open_dash,
        on_exit=lambda: hud.root.after(0, hud.root.quit)
    )
    tray.start()
    hud.run()

if __name__ == "__main__":
    main()
