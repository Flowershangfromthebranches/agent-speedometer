"""Formatting utilities matching AgentPulse macOS Fmt."""
from datetime import datetime, timezone
import math

class Fmt:
    @staticmethod
    def credits_number(value: float) -> str:
        if value is None or not math.isfinite(value) or value < 0:
            return "—"
        if value == 0:
            return "0"
        if value < 0.0001:
            return "<0.0001"
        return f"{value:.4f}" if value < 1 else f"{value:.2f}"

    @staticmethod
    def compact_tokens(n: int) -> str:
        if n is None:
            return "—"
        d = float(n)
        if n >= 1_000_000_000:
            return f"{d / 1e9:.1f}B"
        if n >= 1_000_000:
            return f"{d / 1e6:.1f}M"
        if n >= 10_000:
            return f"{d / 1e3:.0f}K"
        if n >= 1_000:
            return f"{d / 1e3:.1f}K"
        return str(n)

    @staticmethod
    def tokens(n: int) -> str:
        if n is None:
            return "— tok"
        return f"{n:,} tok"

    @staticmethod
    def tps(v: float) -> str:
        if v is None or not math.isfinite(v):
            return "— tok/s"
        return f"{v:.0f} tok/s" if v >= 100 else f"{v:.1f} tok/s"

    @staticmethod
    def tps_number(v: float) -> str:
        if v is None or not math.isfinite(v):
            return "—"
        return f"{v:.0f}" if v >= 100 else f"{v:.1f}"

    @staticmethod
    def percent(f: float, digits: int = 1) -> str:
        if f is None or not math.isfinite(f):
            return "—"
        return f"{f * 100:.{digits}f}%"

    @staticmethod
    def usd(v: float) -> str:
        if v is None or not math.isfinite(v) or v < 0:
            return "—"
        if v == 0:
            return "$0.00"
        if v < 0.01:
            return "<$0.01"
        if v < 10:
            return "$" + f"{v:.2f}"
        if v < 1000:
            return "$" + f"{v:.1f}"
        if v < 10_000:
            return "$" + f"{v:.0f}"
        return "$" + f"{v / 1000:.1f}K"

    @staticmethod
    def duration(t: float) -> str:
        if t is None or not math.isfinite(t):
            return "—"
        if t < 60:
            return f"{t:.1f}秒"
        s = int(round(t))
        if s < 3600:
            return f"{s // 60}分{s % 60}秒"
        return f"{s // 3600}小时{(s % 3600) // 60}分"

    @staticmethod
    def short_elapsed(t: float) -> str:
        s = max(0, int(t))
        return f"{s}s" if s < 60 else f"{s // 60}m{s % 60}s"

    @staticmethod
    def relative(d: datetime) -> str:
        now = datetime.now(timezone.utc)
        if d.tzinfo is None:
            d = d.replace(tzinfo=timezone.utc)
        s = int((now - d).total_seconds())
        if s < 60:
            return "刚刚"
        if s < 3600:
            return f"{s // 60} 分钟前"
        if s < 86400:
            return f"{s // 3600} 小时前"
        return f"{s // 86400} 天前"
