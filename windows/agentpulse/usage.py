"""Token usage scanner and aggregation matching TokenUsage.swift."""
import os
import glob
import json
from datetime import datetime, timezone, timedelta, date
from dataclasses import dataclass, field
from typing import Optional, List, Dict, Set, Tuple
from .models import TokenTotals, CostEstimate, AgentSource
from .pricing import ModelPricingTable
from .tools import ToolRegistry, ToolScanner
from .discovery import SessionDiscovery, SessionRef, Readers

class UsageRange:
    WEEK = "week"
    MONTH = "month"
    QUARTER = "quarter"
    ALL = "all"

    @classmethod
    def title(cls, r: str) -> str:
        if r == cls.WEEK: return "近 7 天"
        if r == cls.MONTH: return "近 30 天"
        if r == cls.QUARTER: return "近 90 天"
        return "全部"

    @classmethod
    def days(cls, r: str) -> Optional[int]:
        if r == cls.WEEK: return 7
        if r == cls.MONTH: return 30
        if r == cls.QUARTER: return 90
        return None

    @classmethod
    def start_date(cls, r: str, now: Optional[datetime] = None) -> Optional[datetime]:
        d = cls.days(r)
        if d is None:
            return None
        now_dt = now or datetime.now(timezone.utc)
        today = datetime(now_dt.year, now_dt.month, now_dt.day, tzinfo=timezone.utc)
        return today - timedelta(days=d - 1)

@dataclass
class UsageEvent:
    source_id: str
    session_key: str
    day: datetime
    model: Optional[str]
    totals: TokenTotals

@dataclass
class UsageModel:
    model: Optional[str]
    display_name: str
    totals: TokenTotals
    cost: CostEstimate

@dataclass
class UsageTool:
    source: AgentSource
    totals: TokenTotals
    session_count: int
    cost: CostEstimate

@dataclass
class UsageDayBucket:
    start: datetime
    axis_label: str
    tooltip_title: str
    totals: TokenTotals

@dataclass
class UsageSummary:
    totals: TokenTotals
    tools: List[UsageTool]
    models: List[UsageModel]
    cost: CostEstimate
    buckets: List[UsageDayBucket]
    session_count: int
    period_days: int

class TokenUsageScanner:
    def __init__(self):
        self.cache: Dict[str, Tuple[float, List[UsageEvent]]] = {}

    def scan(self, since: Optional[datetime] = None, source_id: Optional[str] = None) -> List[UsageEvent]:
        events: List[UsageEvent] = []
        for dt in ToolScanner.scan():
            if not dt.supported:
                continue
            if source_id and dt.spec.id != source_id:
                continue

            sessions = SessionDiscovery.sessions_for(dt.spec, limit=5000)
            for ref in sessions:
                if since and ref.modified < since:
                    continue

                stats, requests = Readers.read_session(ref)
                if not requests:
                    # Single bucket from stats
                    d = ref.modified
                    day_dt = datetime(d.year, d.month, d.day, tzinfo=timezone.utc)
                    tot = TokenTotals(
                        output=stats.output_tokens,
                        uncached_input=stats.uncached_input,
                        cache_read=stats.cache_read,
                        cache_write=stats.cache_write,
                        requests=stats.steps,
                        credits=stats.credits,
                        credit_requests=stats.credit_requests,
                        missing_credit_requests=stats.missing_credit_requests
                    )
                    events.append(UsageEvent(
                        source_id=dt.spec.id,
                        session_key=ref.path,
                        day=day_dt,
                        model=stats.model,
                        totals=tot
                    ))
                    continue

                # Aggregate requests per day and model
                buckets: Dict[Tuple[date, Optional[str]], TokenTotals] = {}
                for r in requests:
                    if since and r.end < since:
                        continue
                    d = r.end.date()
                    m = r.model or stats.model
                    key = (d, m)
                    if key not in buckets:
                        buckets[key] = TokenTotals()
                    buckets[key].add_record(r)

                for (d, m), tot in buckets.items():
                    day_dt = datetime(d.year, d.month, d.day, tzinfo=timezone.utc)
                    events.append(UsageEvent(
                        source_id=dt.spec.id,
                        session_key=ref.path,
                        day=day_dt,
                        model=m,
                        totals=tot
                    ))
        return events

class UsageAggregation:
    @classmethod
    def summary(cls, events: List[UsageEvent], range_type: str, tool_id: Optional[str] = None,
                now: Optional[datetime] = None) -> UsageSummary:
        now_dt = now or datetime.now(timezone.utc)
        today = datetime(now_dt.year, now_dt.month, now_dt.day, tzinfo=timezone.utc)
        lower = UsageRange.start_date(range_type, now=now_dt)

        filtered = [
            e for e in events
            if (tool_id is None or e.source_id == tool_id)
            and (lower is None or e.day >= lower)
            and e.day <= today
        ]

        totals = TokenTotals()
        tool_totals: Dict[str, TokenTotals] = {}
        tool_sessions: Dict[str, Set[str]] = {}
        model_totals: Dict[str, TokenTotals] = {}
        sessions: Set[str] = set()

        canonical_cache: Dict[str, str] = {}
        def canonical(m: Optional[str]) -> str:
            if not m: return ""
            if m in canonical_cache: return canonical_cache[m]
            k = ModelPricingTable.canonical_key(m) or m
            canonical_cache[m] = k
            return k

        for e in filtered:
            m_key = canonical(e.model)
            totals.add(e.totals)
            if e.source_id not in tool_totals:
                tool_totals[e.source_id] = TokenTotals()
                tool_sessions[e.source_id] = set()
            tool_totals[e.source_id].add(e.totals)
            tool_sessions[e.source_id].add(e.session_key)

            if m_key not in model_totals:
                model_totals[m_key] = TokenTotals()
            model_totals[m_key].add(e.totals)
            sessions.add(e.session_key)

        total_cost = CostEstimate()
        models: List[UsageModel] = []
        for key, t in model_totals.items():
            if t.total > 0:
                est = ModelPricingTable.estimate(t, key if key else None)
                total_cost.add(est)
                models.append(UsageModel(
                    model=key if key else None,
                    display_name=ModelPricingTable.display_name(key if key else None),
                    totals=t,
                    cost=est
                ))
        models.sort(key=lambda m: (m.cost.usd, m.totals.total), reverse=True)

        tools: List[UsageTool] = []
        for tid, t in tool_totals.items():
            t_cost = CostEstimate()
            # Estimate cost for this tool across its models
            for e in filtered:
                if e.source_id == tid:
                    t_cost.add(ModelPricingTable.estimate(e.totals, canonical(e.model)))
            tools.append(UsageTool(
                source=AgentSource(id=tid),
                totals=t,
                session_count=len(tool_sessions.get(tid, set())),
                cost=t_cost
            ))
        tools.sort(key=lambda t: t.totals.total, reverse=True)

        # Day buckets
        days_count = UsageRange.days(range_type) or 30
        buckets: List[UsageDayBucket] = []
        day_map: Dict[date, TokenTotals] = {}
        for e in filtered:
            d = e.day.date()
            if d not in day_map:
                day_map[d] = TokenTotals()
            day_map[d].add(e.totals)

        for i in range(days_count):
            day_date = (today - timedelta(days=days_count - 1 - i)).date()
            day_start = datetime(day_date.year, day_date.month, day_date.day, tzinfo=timezone.utc)
            t = day_map.get(day_date, TokenTotals())
            axis_lbl = day_date.strftime("%m-%d")
            tip_title = day_date.strftime("%Y-%m-%d")
            buckets.append(UsageDayBucket(start=day_start, axis_label=axis_lbl, tooltip_title=tip_title, totals=t))

        return UsageSummary(
            totals=totals,
            tools=tools,
            models=models,
            cost=total_cost,
            buckets=buckets,
            session_count=len(sessions),
            period_days=days_count
        )
