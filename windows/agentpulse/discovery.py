"""Session discovery, readers, and monitoring for Windows."""
import os
import glob
import json
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Optional, List, Dict, Tuple
from .models import AgentSource, AgentToolSpec, SessionStats, RequestRecord
from .tools import ToolRegistry, ToolScanner
from .parsers import (
    ClaudeParser, CodexParser, QoderParser, CodeBuddyParser,
    DeepSeekHarnessParser, OpenCodeSqliteReader
)

@dataclass
class SessionRef:
    path: str
    source: AgentSource
    modified: datetime
    is_subagent: bool = False

class SessionDiscovery:
    @staticmethod
    def get_home() -> str:
        return os.path.expanduser("~")

    @classmethod
    def is_under_session_roots(cls, spec: AgentToolSpec, path: str) -> bool:
        if not path:
            return False
        target = os.path.normcase(os.path.realpath(path))
        home = cls.get_home()
        for root in spec.session_roots:
            full_root = os.path.normcase(os.path.realpath(os.path.join(home, root)))
            if target == full_root or target.startswith(full_root + os.sep):
                return True
        return False

    @classmethod
    def sessions_for(cls, spec: AgentToolSpec, limit: int = 50) -> List[SessionRef]:
        home = cls.get_home()
        refs: List[SessionRef] = []
        source = AgentSource(id=spec.id)

        for root in spec.session_roots:
            full_root = os.path.normpath(os.path.join(home, root))
            if not os.path.exists(full_root):
                continue

            if spec.format in ("claudeCode", "codex", "codebuddy", "pi", "zcode", "antigravity", "qoder"):
                # Search for .jsonl files
                pattern = os.path.join(full_root, "**", "*.jsonl")
                for fpath in glob.iglob(pattern, recursive=True):
                    try:
                        mtime = os.path.getmtime(fpath)
                        mod_dt = datetime.fromtimestamp(mtime, tz=timezone.utc)
                        is_sub = "subagent" in fpath.lower() or "auto-review" in fpath.lower()
                        refs.append(SessionRef(path=fpath, source=source, modified=mod_dt, is_subagent=is_sub))
                    except Exception:
                        pass
            elif spec.format == "deepseekHarness":
                pattern = os.path.join(full_root, "*.json")
                for fpath in glob.iglob(pattern):
                    try:
                        mtime = os.path.getmtime(fpath)
                        mod_dt = datetime.fromtimestamp(mtime, tz=timezone.utc)
                        refs.append(SessionRef(path=fpath, source=source, modified=mod_dt))
                    except Exception:
                        pass
            elif spec.format == "opencodeDB":
                if os.path.isfile(full_root):
                    mtime = os.path.getmtime(full_root)
                    mod_dt = datetime.fromtimestamp(mtime, tz=timezone.utc)
                    refs.append(SessionRef(path=full_root, source=source, modified=mod_dt))

        # Sort newest first
        refs.sort(key=lambda r: r.modified, reverse=True)
        return refs[:limit]

class Readers:
    @classmethod
    def read_session(cls, ref: SessionRef) -> Tuple[SessionStats, List[RequestRecord]]:
        spec = ToolRegistry.spec(ref.source.id)
        fmt = spec.format if spec else None

        if fmt == "deepseekHarness":
            stats = DeepSeekHarnessParser.parse_file(ref.path)
            return (stats or SessionStats(source=ref.source, path=ref.path), [])

        if fmt == "opencodeDB":
            items = OpenCodeSqliteReader.read_db(ref.path, ref.source.id)
            if items:
                return (items[0], [])
            return (SessionStats(source=ref.source, path=ref.path), [])

        # JSONL based
        if fmt == "claudeCode":
            parser = ClaudeParser()
        elif fmt == "codex":
            parser = CodexParser()
        elif fmt == "qoder":
            parser = QoderParser()
        elif fmt in ("codebuddy", "pi", "zcode"):
            parser = CodeBuddyParser()
        else:
            parser = ClaudeParser()

        if not os.path.isfile(ref.path):
            return (SessionStats(source=ref.source, path=ref.path), [])

        try:
            with open(ref.path, "r", encoding="utf-8", errors="replace") as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        obj = json.loads(line)
                        if isinstance(obj, dict):
                            parser.consume(obj)
                    except Exception:
                        continue
        except Exception:
            pass

        stats = parser.acc.snapshot(source=ref.source, path=ref.path, context_window_override=None, estimate_context_window=True)
        return (stats, parser.acc.requests)

class Monitor:
    @classmethod
    def active_sessions(cls) -> List[SessionStats]:
        """Sessions modified within the last 10 minutes or currently waiting for model."""
        now = datetime.now(timezone.utc)
        active = []
        for dt in ToolScanner.scan():
            if not dt.supported:
                continue
            sessions = SessionDiscovery.sessions_for(dt.spec, limit=10)
            for ref in sessions:
                diff = (now - ref.modified).total_seconds()
                if diff <= 600:
                    stats, _ = Readers.read_session(ref)
                    active.append(stats)
                elif diff <= 3600:
                    # Check if waiting
                    stats, _ = Readers.read_session(ref)
                    if stats.waiting_since is not None:
                        active.append(stats)
        # Sort by latest activity or modified
        active.sort(key=lambda s: s.last_activity or datetime.min.replace(tzinfo=timezone.utc), reverse=True)
        return active

    @classmethod
    def latest_session(cls) -> Optional[SessionStats]:
        active = cls.active_sessions()
        if active:
            return active[0]
        # Fallback to absolute latest across all tools
        for dt in ToolScanner.scan():
            if not dt.supported:
                continue
            sessions = SessionDiscovery.sessions_for(dt.spec, limit=1)
            if sessions:
                stats, _ = Readers.read_session(sessions[0])
                return stats
        return None
