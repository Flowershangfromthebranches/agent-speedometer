"""Parsers for all supported agent tool session logs."""
from datetime import datetime, timezone
import json
import os
import sqlite3
import uuid
from typing import Optional, List, Dict, Any, Tuple
from .models import (
    RequestRecord, StepSpeed, RateLimitWindow, SessionStats,
    AgentSource, BoundaryKind
)

class J:
    @staticmethod
    def int_val(v: Any) -> int:
        try:
            return int(v) if v is not None else 0
        except (ValueError, TypeError):
            return 0

    @staticmethod
    def float_val(v: Any) -> Optional[float]:
        try:
            if v is None:
                return None
            val = float(v)
            return val if val >= 0 else None
        except (ValueError, TypeError):
            return None

    @staticmethod
    def str_val(v: Any) -> Optional[str]:
        return str(v) if isinstance(v, (str, int, float)) else None

    @staticmethod
    def dict_val(v: Any) -> Optional[Dict[str, Any]]:
        return v if isinstance(v, dict) else None

    @staticmethod
    def date_val(v: Any) -> Optional[datetime]:
        if v is None:
            return None
        if isinstance(v, (int, float)):
            # Epoch milliseconds or seconds
            secs = v / 1000.0 if v > 1e11 else float(v)
            try:
                return datetime.fromtimestamp(secs, tz=timezone.utc)
            except Exception:
                return None
        if isinstance(v, str):
            s = v.strip()
            # Fast parse ISO8601 UTC
            if s.endswith("Z"):
                s = s[:-1] + "+00:00"
            try:
                return datetime.fromisoformat(s)
            except Exception:
                return None
        return None

class SessionAccumulator:
    def __init__(self):
        self.requests: List[RequestRecord] = []
        self.turns: int = 0
        self.last_boundary: Optional[datetime] = None
        self.last_boundary_kind: Optional[BoundaryKind] = None
        self.last_activity: Optional[datetime] = None
        self.model: Optional[str] = None
        self.cwd: Optional[str] = None
        self.title: Optional[str] = None
        self.context_window: Optional[int] = None
        self.rate_limit_primary: Optional[RateLimitWindow] = None
        self.rate_limit_secondary: Optional[RateLimitWindow] = None
        self.speed_note: Optional[str] = None
        self.reported_context_fraction: Optional[float] = None

    def boundary(self, ts: datetime, kind: BoundaryKind):
        if self.last_boundary is None or ts >= self.last_boundary:
            self.last_boundary = ts
            self.last_boundary_kind = kind
        self.touch(ts)

    def end_turn(self, ts: datetime):
        self.last_boundary = None
        self.last_boundary_kind = None
        self.touch(ts)

    def touch(self, ts: datetime):
        if self.last_activity is None or ts > self.last_activity:
            self.last_activity = ts

    def pending_start(self, fallback: datetime) -> Tuple[datetime, Optional[BoundaryKind]]:
        prev_end = self.requests[-1].end if self.requests else None
        if self.last_boundary is not None and (prev_end is None or self.last_boundary >= prev_end):
            return (self.last_boundary, self.last_boundary_kind)
        return (prev_end if prev_end else fallback, None)

    @staticmethod
    def usable_for_speed(r: RequestRecord) -> bool:
        return r.has_request_start and r.output_tokens >= 20 and r.decode_duration >= 0.25

    def snapshot(self, source: AgentSource, path: str, context_window_override: Optional[int] = None,
                 estimate_context_window: bool = False) -> SessionStats:
        from .tools import ToolRegistry
        s = SessionStats(source=source, path=path)
        s.speed_note = self.speed_note
        s.reported_context_fraction = self.reported_context_fraction
        s.cwd = self.cwd
        s.title = self.title
        s.model = self.model or (self.requests[-1].model if self.requests else None)
        s.turns = self.turns
        s.steps = len(self.requests)
        s.last_activity = self.last_activity
        s.rate_limit_primary = self.rate_limit_primary
        s.rate_limit_secondary = self.rate_limit_secondary

        out_sum = 0
        dur_sum = 0.0
        ttft_sum = 0.0
        ttft_n = 0
        prev_req: Optional[RequestRecord] = None

        spec = ToolRegistry.spec(source.id)
        is_qoder = (spec and spec.format == "qoder")

        for r in self.requests:
            if r.charged_credits is not None:
                s.credits = (s.credits or 0.0) + r.charged_credits
                s.credit_requests += 1
            elif is_qoder:
                s.missing_credit_requests += 1

            if r.original_credits is not None:
                s.original_credits = (s.original_credits or 0.0) + r.original_credits

            s.uncached_input += r.uncached_input
            s.cache_read += r.cache_read
            s.cache_write += r.cache_write
            s.output_tokens += r.output_tokens
            s.model_time += r.duration

            if r.ttft is not None and r.ttft < 600:
                ttft_sum += r.ttft
                ttft_n += 1

            if r.start_kind == BoundaryKind.TOOL and prev_req is not None:
                gap = (r.start - prev_req.end).total_seconds()
                if 0 < gap < 3600:
                    s.tool_time += gap

            if self.usable_for_speed(r):
                out_sum += r.output_tokens
                dur_sum += r.decode_duration

            prev_req = r

        if dur_sum > 0:
            s.session_tps = out_sum / dur_sum
        if ttft_n > 0:
            s.avg_ttft = ttft_sum / float(ttft_n)
            s.ttft_available = True

        speedy = [r for r in self.requests if self.usable_for_speed(r)]
        indexed_speedy = [(i, r) for i, r in enumerate(self.requests) if self.usable_for_speed(r)]
        s.step_speeds = [
            StepSpeed(step=i + 1, output_tokens=r.output_tokens, duration=r.decode_duration, completed_at=r.end)
            for i, r in indexed_speedy[-40:]
        ]
        if speedy:
            last = speedy[-1]
            if last.decode_duration > 0:
                s.last_tps = last.output_tokens / last.decode_duration
        recent = speedy[-5:]
        r_dur = sum(r.decode_duration for r in recent)
        if r_dur > 0:
            s.recent_tps = sum(r.output_tokens for r in recent) / r_dur

        credit_steps = [
            (i, r) for i, r in enumerate(self.requests)
            if r.charged_credits is not None and r.has_request_start and r.duration >= 0.25
        ]
        s.credit_step_speeds = [
            StepSpeed(step=i + 1, output_tokens=r.output_tokens, duration=r.duration,
                      completed_at=r.end, credits=r.charged_credits)
            for i, r in credit_steps[-40:]
        ]
        def credit_rate(recs: List[RequestRecord]) -> Optional[float]:
            duration = sum(r.duration for r in recs)
            if duration > 0:
                return sum((r.charged_credits or 0.0) for r in recs) / duration
            return None

        if s.credit_step_speeds:
            s.last_credit_rate = s.credit_step_speeds[-1].rate
        s.recent_credit_rate = credit_rate([r for _, r in credit_steps[-5:]])
        s.session_credit_rate = credit_rate([r for _, r in credit_steps])

        if self.requests:
            s.context_tokens = self.requests[-1].context_tokens

        if self.context_window:
            s.context_window = self.context_window
        elif context_window_override:
            s.context_window = context_window_override
        elif estimate_context_window:
            max_seen = max((r.context_tokens for r in self.requests), default=0)
            m_lower = (s.model or "").lower()
            s.context_window = 1_000_000 if ("[1m]" in m_lower or max_seen > 200_000) else 200_000
            s.context_window_is_estimate = True

        if self.last_boundary is not None:
            if not self.requests or self.last_boundary > self.requests[-1].end:
                now = datetime.now(timezone.utc)
                b = self.last_boundary if self.last_boundary.tzinfo else self.last_boundary.replace(tzinfo=timezone.utc)
                if (now - b).total_seconds() < 15 * 60:
                    s.waiting_since = self.last_boundary

        return s

class ClaudeParser:
    def __init__(self):
        self.acc = SessionAccumulator()

    def consume(self, o: Dict[str, Any]):
        cwd = J.str_val(o.get("cwd"))
        if cwd and self.acc.cwd is None:
            self.acc.cwd = cwd
        msg_type = J.str_val(o.get("type"))
        if msg_type == "custom-title":
            t = J.str_val(o.get("customTitle"))
            if t: self.acc.title = t
            return
        if o.get("isSidechain") is True:
            return
        ts = J.date_val(o.get("timestamp"))
        if not ts:
            return

        if msg_type == "user":
            if o.get("isMeta") is True or o.get("isCompactSummary") is True:
                return
            msg = J.dict_val(o.get("message")) or {}
            content = msg.get("content")
            first_text = None
            blocks = None
            if isinstance(content, str):
                first_text = content
            elif isinstance(content, list):
                blocks = content
                if blocks and isinstance(blocks[0], dict):
                    first_text = J.str_val(blocks[0].get("text"))

            if first_text and first_text.startswith("[Request interrupted"):
                self.acc.end_turn(ts)
            elif blocks and any(isinstance(b, dict) and b.get("type") == "tool_result" for b in blocks):
                self.acc.boundary(ts, BoundaryKind.TOOL)
            elif blocks is not None or first_text is not None:
                self.acc.turns += 1
                self.acc.boundary(ts, BoundaryKind.PROMPT)

        elif msg_type == "assistant":
            if o.get("isApiErrorMessage") is True:
                self.acc.end_turn(ts)
                return
            msg = J.dict_val(o.get("message"))
            if not msg:
                return
            model = J.str_val(msg.get("model"))
            if model == "<synthetic>":
                return
            req_id = J.str_val(msg.get("id")) or J.str_val(o.get("requestId")) or J.str_val(o.get("uuid")) or str(uuid.uuid4())
            u = J.dict_val(msg.get("usage")) or {}
            inp = J.int_val(u.get("input_tokens"))
            c_read = J.int_val(u.get("cache_read_input_tokens"))
            c_write = J.int_val(u.get("cache_creation_input_tokens"))
            c_write_1h = J.int_val((J.dict_val(u.get("cache_creation")) or {}).get("ephemeral_1h_input_tokens"))
            out = J.int_val(u.get("output_tokens"))
            self.acc.touch(ts)
            if model:
                self.acc.model = model

            is_cont = bool(self.acc.requests and self.acc.requests[-1].id == req_id)
            if is_cont:
                r = self.acc.requests.pop()
                r.end = max(r.end, ts)
            else:
                start, kind = self.acc.pending_start(fallback=ts)
                r = RequestRecord(id=req_id, model=model, start=start, start_kind=kind, first_output=None, end=ts)

            r.output_tokens = max(r.output_tokens, out)
            r.uncached_input = inp
            r.cache_write = c_write
            r.cache_write_1h = min(c_write_1h, c_write)
            r.cache_read = c_read
            r.context_tokens = inp + c_read + c_write
            self.acc.requests.append(r)

class CodexParser:
    def __init__(self):
        self.acc = SessionAccumulator()
        self.pending_start: Optional[Tuple[datetime, Optional[BoundaryKind]]] = None
        self.pending_first_output: Optional[datetime] = None
        self.saw_usage_record = False

    def consume(self, o: Dict[str, Any]):
        ts = J.date_val(o.get("timestamp"))
        if not ts:
            return
        m_type = J.str_val(o.get("type"))
        p = J.dict_val(o.get("payload")) or {}

        if m_type == "session_meta":
            cwd = J.str_val(p.get("cwd"))
            if cwd: self.acc.cwd = cwd
        elif m_type == "turn_context":
            m = J.str_val(p.get("model"))
            if m: self.acc.model = m
            cwd = J.str_val(p.get("cwd"))
            if cwd: self.acc.cwd = cwd
        elif m_type == "token_usage_record":
            self.saw_usage_record = True
            self._close_request(ts, J.str_val(p.get("response_id")), J.dict_val(p.get("usage")))
        elif m_type == "response_item":
            item_type = J.str_val(p.get("type"))
            if item_type in ("function_call_output", "custom_tool_call_output", "local_shell_call_output", "tool_search_output"):
                self.acc.boundary(ts, BoundaryKind.TOOL)
            elif item_type in ("message", "reasoning", "function_call", "custom_tool_call", "local_shell_call", "web_search_call", "tool_search_call"):
                self._output(ts, None)
        elif m_type == "event_msg":
            evt_type = J.str_val(p.get("type"))
            if evt_type in ("task_complete", "turn_aborted"):
                self.acc.end_turn(ts)
                self.pending_start = None
                self.pending_first_output = None
            elif evt_type == "task_started":
                self.acc.turns += 1
                self.acc.boundary(ts, BoundaryKind.PROMPT)
                w = p.get("model_context_window")
                if isinstance(w, (int, float)):
                    self.acc.context_window = int(w)
            elif evt_type == "item_completed":
                item = J.dict_val(p.get("item")) or {}
                if item.get("type") in ("reasoning", "agent_message"):
                    started_ms = J.float_val(item.get("started_at_ms"))
                    precise = datetime.fromtimestamp(started_ms / 1000.0, tz=timezone.utc) if started_ms else None
                    self._output(ts, precise)

    def _output(self, ts: datetime, precise: Optional[datetime]):
        if self.pending_start is None:
            self.pending_start = self.acc.pending_start(fallback=ts)
        if self.pending_first_output is None:
            self.pending_first_output = precise or ts
        self.acc.touch(ts)

    def _close_request(self, ts: datetime, resp_id: Optional[str], usage: Optional[Dict[str, Any]]):
        u = usage or {}
        inp = J.int_val(u.get("input_tokens"))
        out = J.int_val(u.get("output_tokens"))
        cached = J.int_val(u.get("cached_input_tokens"))
        start, kind = self.pending_start or self.acc.pending_start(fallback=ts)
        r = RequestRecord(
            id=resp_id or str(uuid.uuid4()),
            model=self.acc.model,
            start=start,
            start_kind=kind,
            first_output=self.pending_first_output,
            end=ts,
            output_tokens=out,
            uncached_input=max(0, inp - cached),
            cache_read=cached,
            context_tokens=inp
        )
        self.acc.requests.append(r)
        self.pending_start = None
        self.pending_first_output = None
        self.acc.touch(ts)

class QoderParser:
    def __init__(self, include_sidechains: bool = False):
        self.acc = SessionAccumulator()
        self.acc.speed_note = (
            "Credits/s = 实际计费 Credits ÷ 请求耗时（含等待）；请求结束后更新，"
            "不代表输出 token 速度。未计费请求按 0 统计，缺失计费字段不计入；未启用未经验证的 token 换算。"
        )
        self.indices: Dict[str, int] = {}
        self.include_sidechains = include_sidechains

    def consume(self, object_dict: Dict[str, Any]):
        if not self.include_sidechains and object_dict.get("isSidechain") is True:
            return
        if self.acc.cwd is None and object_dict.get("cwd"):
            self.acc.cwd = J.str_val(object_dict.get("cwd"))
        if object_dict.get("type") == "custom-title":
            t = J.str_val(object_dict.get("customTitle"))
            if t: self.acc.title = t
            return
        ts = J.date_val(object_dict.get("timestamp"))
        if not ts:
            return
        self.acc.touch(ts)

        msg_type = J.str_val(object_dict.get("type"))
        message = J.dict_val(object_dict.get("message")) or {}

        if msg_type == "user":
            if object_dict.get("isMeta") is True or object_dict.get("isCompactSummary") is True:
                return
            blocks = message.get("content")
            tool_result = False
            if isinstance(blocks, list):
                tool_result = any(isinstance(b, dict) and b.get("type") == "tool_result" for b in blocks)
            if not tool_result:
                self.acc.turns += 1
            self.acc.boundary(ts, BoundaryKind.TOOL if tool_result else BoundaryKind.PROMPT)

        elif msg_type == "system":
            if J.str_val(object_dict.get("subtype")) == "turn_duration":
                self.acc.end_turn(ts)

        elif msg_type == "assistant":
            if object_dict.get("isApiErrorMessage") is True:
                return
            usage = J.dict_val(message.get("usage"))
            if not usage:
                return
            req_id = (
                J.str_val(usage.get("request_id"))
                or J.str_val(message.get("id"))
                or J.str_val(object_dict.get("uuid"))
            )
            if not req_id:
                return
            model = J.str_val(message.get("model"))
            if model and model != "<synthetic>":
                self.acc.model = model

            existing_idx = self.indices.get(req_id)
            if existing_idx is not None:
                request = self.acc.requests[existing_idx]
                request.end = max(request.end, ts)
            else:
                cand = self.acc.last_boundary
                start = cand if (cand and cand <= ts and (not self.acc.requests or cand >= self.acc.requests[-1].end)) else None
                request = RequestRecord(
                    id=req_id,
                    model=self.acc.model,
                    start=min(start or ts, ts),
                    start_kind=self.acc.last_boundary_kind,
                    first_output=None,
                    end=ts
                )
                request.has_request_start = (start is not None)

            request.model = J.str_val(message.get("model")) or request.model
            request.output_tokens = J.int_val(usage.get("output_tokens"))
            request.uncached_input = J.int_val(usage.get("input_tokens"))
            request.cache_read = J.int_val(usage.get("cache_read_input_tokens"))
            request.cache_write = J.int_val(usage.get("cache_creation_input_tokens"))
            request.context_tokens = request.uncached_input + request.cache_read + request.cache_write
            c = J.float_val(usage.get("credits"))
            if c is not None: request.credits = c
            orig_c = J.float_val(usage.get("original_credits"))
            if orig_c is not None: request.original_credits = orig_c

            b_val = usage.get("billable")
            if isinstance(b_val, bool):
                request.billable = b_val

            ratio = J.float_val(usage.get("context_usage_ratio"))
            if ratio is not None:
                self.acc.reported_context_fraction = min(1.0, ratio)

            if existing_idx is not None:
                self.acc.requests[existing_idx] = request
            else:
                self.indices[req_id] = len(self.acc.requests)
                self.acc.requests.append(request)

            if J.str_val(message.get("stop_reason")) not in ("tool_use", None):
                self.acc.end_turn(ts)

class CodeBuddyParser:
    def __init__(self):
        self.acc = SessionAccumulator()

    def consume(self, o: Dict[str, Any]):
        if self.acc.cwd is None and o.get("cwd"):
            self.acc.cwd = J.str_val(o.get("cwd"))
        ts = J.date_val(o.get("timestamp"))
        if not ts: return
        msg_type = J.str_val(o.get("type"))
        if msg_type == "function_call_result":
            self.acc.boundary(ts, BoundaryKind.TOOL)
            return
        if msg_type == "message" and J.str_val(o.get("role")) == "user":
            self.acc.turns += 1
            self.acc.boundary(ts, BoundaryKind.PROMPT)
            return

        pd = J.dict_val(o.get("providerData"))
        pu = J.dict_val(pd.get("usage")) if pd else None
        mu = J.dict_val((J.dict_val(o.get("message")) or {}).get("usage"))
        out_raw = (pu.get("outputTokens") if pu else None) or (mu.get("output_tokens") if mu else None)
        if out_raw is None:
            if msg_type: self.acc.touch(ts)
            return

        inp = J.int_val((pu.get("inputTokens") if pu else None) or (mu.get("input_tokens") if mu else None))
        cached = 0
        if pu and isinstance(pu.get("inputTokensDetails"), list) and pu["inputTokensDetails"]:
            cached = J.int_val(pu["inputTokensDetails"][0].get("cached_tokens"))
        elif mu:
            cached = J.int_val(mu.get("cache_read_input_tokens"))

        if pd and pd.get("model"):
            self.acc.model = J.str_val(pd.get("model"))

        start, kind = self.acc.pending_start(fallback=ts)
        r = RequestRecord(
            id=J.str_val(o.get("id")) or str(uuid.uuid4()),
            model=self.acc.model,
            start=start,
            start_kind=kind,
            first_output=None,
            end=ts,
            output_tokens=J.int_val(out_raw),
            cache_read=cached,
            uncached_input=max(0, inp - cached),
            context_tokens=inp
        )
        self.acc.requests.append(r)
        self.acc.touch(ts)

class DeepSeekHarnessParser:
    @staticmethod
    def parse_file(path: str) -> Optional[SessionStats]:
        try:
            with open(path, "r", encoding="utf-8") as f:
                data = json.load(f)
            stats = data.get("stats") or {}
            source = AgentSource(id="deepseek-harness")
            s = SessionStats(source=source, path=path)
            s.model = J.str_val(data.get("model")) or "DeepSeek"
            s.title = J.str_val(data.get("title"))
            s.cwd = J.str_val(data.get("cwd"))
            s.turns = J.int_val(stats.get("turns"))
            s.steps = J.int_val(stats.get("steps"))
            s.output_tokens = J.int_val(stats.get("output_tokens"))
            s.uncached_input = J.int_val(stats.get("input_tokens"))
            s.cache_read = J.int_val(stats.get("cache_read_tokens"))
            dec_time = J.float_val(stats.get("decode_duration")) or 0.0
            if dec_time > 0 and s.output_tokens > 0:
                s.session_tps = s.output_tokens / dec_time
                s.recent_tps = s.session_tps
                s.last_tps = s.session_tps
            return s
        except Exception:
            return None

class OpenCodeSqliteReader:
    @staticmethod
    def read_db(db_path: str, tool_id: str) -> List[SessionStats]:
        if not os.path.isfile(db_path):
            return []
        results = []
        try:
            uri = f"file:{db_path}?mode=ro&immutable=1"
            conn = sqlite3.connect(uri, uri=True)
            cursor = conn.cursor()
            # Query session list
            cursor.execute("SELECT id, title, created_at, updated_at FROM session ORDER BY updated_at DESC LIMIT 50")
            rows = cursor.fetchall()
            source = AgentSource(id=tool_id)
            for row in rows:
                sid, title, created_at, updated_at = row[0], row[1], row[2], row[3]
                s = SessionStats(source=source, path=f"{db_path}#{sid}", title=title)
                # Query messages for this session
                cursor.execute(
                    "SELECT role, tokens, created_at FROM message WHERE session_id = ? ORDER BY created_at ASC",
                    (sid,)
                )
                m_rows = cursor.fetchall()
                s.turns = sum(1 for m in m_rows if m[0] == "user")
                s.steps = sum(1 for m in m_rows if m[0] == "assistant")
                results.append(s)
            conn.close()
        except Exception:
            pass
        return results
