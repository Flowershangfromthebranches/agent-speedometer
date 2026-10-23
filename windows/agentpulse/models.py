"""Data structures for AgentPulse."""
from dataclasses import dataclass, field
from datetime import datetime, timezone
from enum import Enum
from typing import Optional, List, Dict, Set, Any

class BoundaryKind(Enum):
    PROMPT = "prompt"
    TOOL = "tool"

@dataclass
class RequestRecord:
    id: str
    model: Optional[str]
    start: datetime
    end: datetime
    start_kind: Optional[BoundaryKind] = None
    first_output: Optional[datetime] = None
    output_tokens: int = 0
    uncached_input: int = 0
    cache_read: int = 0
    cache_write: int = 0
    cache_write_1h: int = 0
    context_tokens: int = 0
    credits: Optional[float] = None
    original_credits: Optional[float] = None
    billable: Optional[bool] = None
    has_request_start: bool = True

    @property
    def charged_credits(self) -> Optional[float]:
        if self.billable is None:
            return None
        if not self.billable:
            return 0.0
        return self.credits

    @property
    def duration(self) -> float:
        return max(0.0, (self.end - self.start).total_seconds())

    @property
    def ttft(self) -> Optional[float]:
        if self.first_output is None:
            return None
        t = (self.first_output - self.start).total_seconds()
        return t if t >= 0 else None

    @property
    def decode_duration(self) -> float:
        if self.first_output and self.first_output >= self.start and self.first_output <= self.end:
            return max(0.0, (self.end - self.first_output).total_seconds())
        return self.duration

    @property
    def total_tokens(self) -> int:
        return self.output_tokens + self.uncached_input + self.cache_read + self.cache_write

@dataclass
class StepSpeed:
    step: int
    output_tokens: int
    duration: float
    completed_at: datetime
    credits: Optional[float] = None

    @property
    def tps(self) -> float:
        return (self.output_tokens / self.duration) if self.duration > 0 else 0.0

    @property
    def rate(self) -> float:
        if self.credits is not None:
            return (self.credits / self.duration) if self.duration > 0 else 0.0
        return self.tps

@dataclass
class RateLimitWindow:
    used_percent: float
    window_minutes: int
    resets_at: Optional[datetime] = None

@dataclass
class AgentToolSpec:
    id: str
    name: str
    symbol: str = "terminal"
    apps: List[str] = field(default_factory=list)
    clis: List[str] = field(default_factory=list)
    data_paths: List[str] = field(default_factory=list)
    format: Optional[str] = None
    session_roots: List[str] = field(default_factory=list)
    note: Optional[str] = None

@dataclass(frozen=True)
class AgentSource:
    id: str

    @property
    def display_name(self) -> str:
        from .tools import ToolRegistry
        spec = ToolRegistry.spec(self.id)
        return spec.name if spec else self.id

    @property
    def symbol(self) -> str:
        from .tools import ToolRegistry
        spec = ToolRegistry.spec(self.id)
        return spec.symbol if spec else "terminal"

@dataclass
class DetectedTool:
    spec: AgentToolSpec
    has_app: bool
    has_cli: bool
    has_data: bool

    @property
    def id(self) -> str:
        return self.spec.id

    @property
    def supported(self) -> bool:
        return self.spec.format is not None

    @property
    def install_kinds(self) -> str:
        k = []
        if self.has_app:
            k.append("桌面端")
        if self.has_cli:
            k.append("CLI")
        if not k:
            k.append("有本地数据")
        return " · ".join(k)

@dataclass
class SessionStats:
    source: AgentSource
    path: str
    cwd: Optional[str] = None
    title: Optional[str] = None
    model: Optional[str] = None
    turns: int = 0
    steps: int = 0
    last_tps: Optional[float] = None
    recent_tps: Optional[float] = None
    session_tps: Optional[float] = None
    step_speeds: List[StepSpeed] = field(default_factory=list)
    credits: Optional[float] = None
    original_credits: Optional[float] = None
    credit_requests: int = 0
    missing_credit_requests: int = 0
    recent_credit_rate: Optional[float] = None
    last_credit_rate: Optional[float] = None
    session_credit_rate: Optional[float] = None
    credit_step_speeds: List[StepSpeed] = field(default_factory=list)
    reported_context_fraction: Optional[float] = None
    avg_ttft: Optional[float] = None
    ttft_available: bool = False
    model_time: float = 0.0
    tool_time: float = 0.0
    uncached_input: int = 0
    cache_read: int = 0
    cache_write: int = 0
    output_tokens: int = 0
    context_tokens: int = 0
    context_window: Optional[int] = None
    context_window_is_estimate: bool = False
    waiting_since: Optional[datetime] = None
    last_activity: Optional[datetime] = None
    rate_limit_primary: Optional[RateLimitWindow] = None
    rate_limit_secondary: Optional[RateLimitWindow] = None
    speed_note: Optional[str] = None

    @property
    def total_tokens(self) -> int:
        return self.uncached_input + self.cache_read + self.cache_write + self.output_tokens

    @property
    def uses_credits(self) -> bool:
        from .tools import ToolRegistry
        spec = ToolRegistry.spec(self.source.id)
        return spec.format == "qoder" if spec else False

    @property
    def speed_unit(self) -> str:
        return "Credits/s" if self.uses_credits else "tok/s"

    @property
    def speed_title(self) -> str:
        return "Credits 消耗速度" if self.uses_credits else "输出速度"

    @property
    def display_recent_speed(self) -> Optional[float]:
        return self.recent_credit_rate if self.uses_credits else self.recent_tps

    @property
    def display_last_speed(self) -> Optional[float]:
        return self.last_credit_rate if self.uses_credits else self.last_tps

    @property
    def display_session_speed(self) -> Optional[float]:
        return self.session_credit_rate if self.uses_credits else self.session_tps

    @property
    def display_step_speeds(self) -> List[StepSpeed]:
        return self.credit_step_speeds if self.uses_credits else self.step_speeds

    @property
    def cache_hit_rate(self) -> Optional[float]:
        total_in = self.uncached_input + self.cache_read + self.cache_write
        return (self.cache_read / total_in) if total_in > 0 else None

    @property
    def context_fraction(self) -> Optional[float]:
        if self.reported_context_fraction is not None:
            return self.reported_context_fraction
        if self.context_window and self.context_window > 0:
            return min(1.0, self.context_tokens / self.context_window)
        return None

    @property
    def project_name(self) -> str:
        if self.cwd:
            import os
            base = os.path.basename(os.path.normpath(self.cwd))
            if base:
                return base
        if self.title:
            return self.title
        import os
        return os.path.splitext(os.path.basename(self.path))[0]

@dataclass
class TokenTotals:
    output: int = 0
    uncached_input: int = 0
    cache_read: int = 0
    cache_write: int = 0
    cache_write_1h: int = 0
    requests: int = 0
    credits: Optional[float] = None
    credit_requests: int = 0
    missing_credit_requests: int = 0
    timed_credits: float = 0.0
    credit_duration: float = 0.0

    @property
    def total(self) -> int:
        return self.output + self.uncached_input + self.cache_read + self.cache_write

    @property
    def input(self) -> int:
        return self.uncached_input + self.cache_read + self.cache_write

    @property
    def cache_hit_rate(self) -> Optional[float]:
        return (self.cache_read / self.input) if self.input > 0 else None

    @property
    def credit_rate(self) -> Optional[float]:
        return (self.timed_credits / self.credit_duration) if self.credit_duration > 0 else None

    @property
    def has_credit_data(self) -> bool:
        return self.credit_requests > 0 or self.missing_credit_requests > 0

    def add(self, other: "TokenTotals"):
        self.output += other.output
        self.uncached_input += other.uncached_input
        self.cache_read += other.cache_read
        self.cache_write += other.cache_write
        self.cache_write_1h += other.cache_write_1h
        self.requests += other.requests
        if other.credits is not None:
            self.credits = (self.credits or 0.0) + other.credits
        self.credit_requests += other.credit_requests
        self.missing_credit_requests += other.missing_credit_requests
        self.timed_credits += other.timed_credits
        self.credit_duration += other.credit_duration

    def add_record(self, r: RequestRecord):
        self.output += max(0, r.output_tokens)
        self.uncached_input += max(0, r.uncached_input)
        self.cache_read += max(0, r.cache_read)
        self.cache_write += max(0, r.cache_write)
        self.cache_write_1h += max(0, min(r.cache_write_1h, r.cache_write))
        self.requests += 1
        if r.charged_credits is not None:
            self.credits = (self.credits or 0.0) + r.charged_credits
            self.credit_requests += 1
            if r.has_request_start and r.duration >= 0.25:
                self.timed_credits += r.charged_credits
                self.credit_duration += r.duration
        elif r.credits is None:
            pass

@dataclass
class CostEstimate:
    usd: float = 0.0
    priced_tokens: int = 0
    unpriced_tokens: int = 0

    @property
    def total_tokens(self) -> int:
        return self.priced_tokens + self.unpriced_tokens

    @property
    def is_complete(self) -> bool:
        return self.unpriced_tokens == 0

    def add(self, other: "CostEstimate"):
        self.usd += other.usd
        self.priced_tokens += other.priced_tokens
        self.unpriced_tokens += other.unpriced_tokens
