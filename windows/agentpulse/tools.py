"""Agent tools registry and scanner with Windows support."""
import os
import sys
from typing import Optional, List, Dict
from .models import AgentToolSpec, AgentSource, DetectedTool

class ToolRegistry:
    NO_USAGE = "本地日志不记录 token 用量，无法计算速度"
    NO_LOCAL_DATA = "没有在本机找到可读取的会话记录"
    NOT_ADAPTED = "暂未适配（本机没有该工具的会话样本）"

    all: List[AgentToolSpec] = [
        # Supported: local logs carry token usage.
        AgentToolSpec(id="claude", name="Claude Code", symbol="sparkle",
                      apps=["Claude.exe", "Claude", "Claude.app"], clis=["claude", "claude.cmd"],
                      data_paths=[".claude/projects"], format="claudeCode", session_roots=[".claude/projects"]),
        AgentToolSpec(id="codex", name="Codex", symbol="chevron.left.forwardslash.chevron.right",
                      apps=["Codex.exe", "Codex", "Codex.app"], clis=["codex", "codex.cmd"],
                      data_paths=[".codex/sessions"], format="codex", session_roots=[".codex/sessions"]),
        AgentToolSpec(id="deepseek-harness", name="DeepSeek Harness", symbol="fish",
                      apps=["DeepSeek Harness.exe", "DeepSeek Harness.app"], clis=["dsh", "dsh.cmd"],
                      data_paths=[".dsh"], format="deepseekHarness",
                      session_roots=[".dsh/storages/session_projcache/sessions"]),
        AgentToolSpec(id="opencode", name="opencode", symbol="curlybraces",
                      apps=["OpenCode.exe", "OpenCode.app"], clis=["opencode", "opencode.cmd"],
                      data_paths=[".local/share/opencode", "AppData/Local/opencode"],
                      format="opencodeDB", session_roots=[".local/share/opencode/opencode.db", "AppData/Local/opencode/opencode.db"]),
        AgentToolSpec(id="mimocode", name="MiMo Code", symbol="curlybraces",
                      clis=["mimo", "mimocode", "mimo.cmd"],
                      data_paths=[".local/share/mimocode", "AppData/Local/mimocode"],
                      format="opencodeDB", session_roots=[".local/share/mimocode/mimocode.db", "AppData/Local/mimocode/mimocode.db"]),
        AgentToolSpec(id="codebuddy", name="CodeBuddy", symbol="person.2",
                      apps=["CodeBuddy.exe", "CodeBuddy CN.exe", "CodeBuddy.app"],
                      clis=["codebuddy", "codebuddy.cmd"],
                      data_paths=[".codebuddy", ".codebuddycn"],
                      format="codebuddy", session_roots=[".codebuddy/projects", ".codebuddycn/projects"]),
        AgentToolSpec(id="workbuddy", name="WorkBuddy", symbol="briefcase",
                      apps=["WorkBuddy.exe", "WorkBuddy.app"], data_paths=[".workbuddy"],
                      format="codebuddy", session_roots=[".workbuddy/projects"]),
        AgentToolSpec(id="workbuddy-ai", name="WorkBuddy AI", symbol="wand.and.stars",
                      apps=["WorkBuddy AI.exe", "WorkBuddy AI.app"], data_paths=[".workbuddy-ai"],
                      format="codebuddy", session_roots=[".workbuddy-ai/projects"]),
        AgentToolSpec(id="stepcode", name="StepCode", symbol="figure.walk",
                      clis=["stepcode", "stepcode.cmd"], data_paths=[".stepcode"],
                      format="pi", session_roots=[".stepcode/agent/sessions"]),
        AgentToolSpec(id="pi", name="pi", symbol="number",
                      clis=["pi", "pi.cmd"], data_paths=[".pi/agent"],
                      format="pi", session_roots=[".pi/agent/sessions"]),
        AgentToolSpec(id="zcode", name="ZCode", symbol="z.square",
                      apps=["ZCode.exe", "ZCode.app"], clis=["zcode", "zcode.cmd"],
                      data_paths=[".zcode"], format="zcode", session_roots=[".zcode/cli/rollout"]),
        AgentToolSpec(id="antigravity", name="Antigravity", symbol="arrow.up.circle",
                      apps=["Antigravity.exe", "Antigravity.app"], clis=["agy", "antigravity", "agy.cmd"],
                      data_paths=[".gemini/antigravity", ".gemini/antigravity-cli"],
                      format="antigravity",
                      session_roots=[".gemini/antigravity-cli/brain", ".gemini/antigravity/brain"]),

        # Qoder & Qoder CN
        AgentToolSpec(id="qoder", name="Qoder", symbol="q.square",
                      apps=["Qoder.exe", "Qoder.app"], clis=["qodercli", "qoder", "qodercli.cmd"],
                      data_paths=[".qoder", ".qoderwork", ".qoder-cli",
                                  "AppData/Roaming/Qoder", "AppData/Local/Programs/Qoder",
                                  "Library/Application Support/com.qoder.app.stable"],
                      format="qoder", session_roots=[".qoder/projects", ".qoderwork/projects"]),
        AgentToolSpec(id="qoder-cn", name="Qoder CN", symbol="q.square",
                      apps=["Qoder CN.exe", "Qoder CN.app"], clis=["qoderclicn", "qoderclicn.cmd"],
                      data_paths=[".qoder-cn", ".qoderworkcn",
                                  "AppData/Roaming/Qoder CN", "AppData/Local/Programs/Qoder CN",
                                  "Library/Application Support/com.qodercn.app.stable"],
                      format="qoder", session_roots=[".qoder-cn/projects", ".qoderworkcn/projects"]),

        # Detected only
        AgentToolSpec(id="gemini-cli", name="Gemini CLI", symbol="diamond", clis=["gemini", "gemini.cmd"],
                      data_paths=[".gemini/tmp"], note=NOT_ADAPTED),
        AgentToolSpec(id="qwen", name="Qwen Code", symbol="q.circle", clis=["qwen", "qwen.cmd"],
                      data_paths=[".qwen"], note=NOT_ADAPTED),
        AgentToolSpec(id="iflow", name="iFlow CLI", symbol="wind", clis=["iflow", "iflow.cmd"],
                      data_paths=[".iflow"], note=NOT_ADAPTED),
        AgentToolSpec(id="kimi", name="Kimi", symbol="moon",
                      apps=["Kimi.exe", "Kimi.app"], clis=["kimi", "kimi.cmd"],
                      data_paths=[".kimi", "AppData/Roaming/kimi-desktop", "Library/Application Support/kimi-desktop"],
                      note=NO_USAGE),
        AgentToolSpec(id="commandcode", name="Command Code", symbol="command",
                      apps=["Command Code.exe", "Command Code.app"], clis=["commandcode"],
                      data_paths=[".commandcode"], note=NO_USAGE),
        AgentToolSpec(id="grok", name="Grok CLI", symbol="xmark.circle",
                      apps=["Grok Bot.exe", "Grok Bot.app"], clis=["grok", "grok.cmd"],
                      data_paths=[".grok"], note="本地日志只记录每轮汇总用量，无法计算实时速度"),
        AgentToolSpec(id="cursor", name="Cursor", symbol="cursorarrow",
                      apps=["Cursor.exe", "Cursor.app"], clis=["cursor-agent"],
                      data_paths=[".cursor", ".local/share/cursor-agent", "AppData/Local/Programs/cursor"],
                      note=NO_LOCAL_DATA),
        AgentToolSpec(id="trae", name="Trae", symbol="t.square",
                      apps=["Trae.exe", "Trae CN.exe", "Trae.app", "Trae CN.app"],
                      clis=["trae", "trae-cli", "trae.cmd"],
                      data_paths=[".trae", ".trae-cn", ".traecli", "AppData/Roaming/Trae"],
                      note=NO_LOCAL_DATA),
        AgentToolSpec(id="kiro", name="Kiro", symbol="k.square",
                      apps=["Kiro.exe", "Kiro.app"], clis=["kiro"],
                      data_paths=[".kiro"], note=NO_LOCAL_DATA),
        AgentToolSpec(id="windsurf", name="Windsurf", symbol="wind",
                      apps=["Windsurf.exe", "Windsurf.app"],
                      data_paths=[".windsurf", ".codeium", "AppData/Roaming/Windsurf"],
                      note=NO_LOCAL_DATA),
        AgentToolSpec(id="copilot", name="GitHub Copilot CLI", symbol="airplane",
                      clis=["copilot", "copilot.cmd"], data_paths=[".copilot"], note=NO_LOCAL_DATA),
        AgentToolSpec(id="factory", name="Factory Droid", symbol="gearshape.2",
                      clis=["droid"], data_paths=[".factory"], note=NO_LOCAL_DATA),
        AgentToolSpec(id="crush", name="Crush", symbol="heart",
                      clis=["crush"], data_paths=[".crush"], note=NO_LOCAL_DATA),
        AgentToolSpec(id="goose", name="Goose", symbol="bird",
                      clis=["goose", "goose.cmd"], data_paths=[".goose"], note=NO_LOCAL_DATA),
        AgentToolSpec(id="devin", name="Devin", symbol="d.square",
                      apps=["Devin.exe", "Devin.app"], clis=["devin"],
                      data_paths=[".devin", ".local/share/devin"], note=NO_LOCAL_DATA),
        AgentToolSpec(id="minimax", name="MiniMax Code", symbol="m.square",
                      apps=["MiniMax Code.exe", "MiniMax Code.app"],
                      data_paths=[".minimax", ".mavis"], note=NO_LOCAL_DATA),
        AgentToolSpec(id="aider", name="Aider", symbol="a.square",
                      clis=["aider", "aider.exe"], data_paths=[".aider"], note=NO_LOCAL_DATA),
        AgentToolSpec(id="cline", name="Cline", symbol="c.square",
                      clis=["cline"], data_paths=[".cline"], note=NO_LOCAL_DATA),
        AgentToolSpec(id="openhands", name="OpenHands", symbol="hand.raised",
                      clis=["openhands"], data_paths=[".openhands"], note=NO_LOCAL_DATA),
    ]

    _by_id: Dict[str, AgentToolSpec] = {s.id: s for s in all}

    @classmethod
    def spec(cls, tool_id: str) -> Optional[AgentToolSpec]:
        return cls._by_id.get(tool_id)

    @classmethod
    def source_for_path(cls, path: str) -> Optional[AgentSource]:
        home = os.path.expanduser("~")
        norm_path = os.path.normpath(path)
        for s in cls.all:
            if not s.format:
                continue
            for r in s.session_roots:
                full_root = os.path.normpath(os.path.join(home, r))
                if norm_path.startswith(full_root):
                    return AgentSource(id=s.id)
        return None

class ToolScanner:
    @staticmethod
    def get_app_dirs() -> List[str]:
        home = os.path.expanduser("~")
        dirs = []
        if sys.platform == "win32":
            local_app_data = os.environ.get("LOCALAPPDATA", os.path.join(home, "AppData", "Local"))
            app_data = os.environ.get("APPDATA", os.path.join(home, "AppData", "Roaming"))
            prog_files = os.environ.get("ProgramFiles", r"C:\Program Files")
            prog_files_x86 = os.environ.get("ProgramFiles(x86)", r"C:\Program Files (x86)")
            dirs.extend([
                os.path.join(local_app_data, "Programs"),
                local_app_data,
                app_data,
                prog_files,
                prog_files_x86,
            ])
        else:
            dirs.extend(["/Applications", os.path.join(home, "Applications")])
        return dirs

    @staticmethod
    def get_bin_dirs() -> List[str]:
        home = os.path.expanduser("~")
        dirs = []
        path_env = os.environ.get("PATH", "")
        sep = ";" if sys.platform == "win32" else ":"
        for p in path_env.split(sep):
            if p.strip():
                dirs.append(p.strip())
        if sys.platform == "win32":
            app_data = os.environ.get("APPDATA", os.path.join(home, "AppData", "Roaming"))
            local_app_data = os.environ.get("LOCALAPPDATA", os.path.join(home, "AppData", "Local"))
            dirs.extend([
                os.path.join(app_data, "npm"),
                os.path.join(local_app_data, "pnpm"),
                os.path.join(home, ".cargo", "bin"),
                os.path.join(home, ".bun", "bin"),
                os.path.join(home, ".local", "bin"),
                os.path.join(home, "bin"),
            ])
        else:
            dirs.extend([
                "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
                os.path.join(home, ".local", "bin"),
                os.path.join(home, "bin"),
                os.path.join(home, ".bun", "bin"),
                os.path.join(home, ".npm-global", "bin"),
                os.path.join(home, ".cargo", "bin"),
            ])
        return dirs

    @classmethod
    def scan(cls) -> List[DetectedTool]:
        home = os.path.expanduser("~")
        app_dirs = cls.get_app_dirs()
        bin_dirs = cls.get_bin_dirs()

        results = []
        for spec in ToolRegistry.all:
            has_app = False
            for app in spec.apps:
                for ad in app_dirs:
                    target = os.path.join(ad, app)
                    if os.path.exists(target):
                        has_app = True
                        break
                if has_app:
                    break

            has_cli = False
            for cli in spec.clis:
                for bd in bin_dirs:
                    target = os.path.join(bd, cli)
                    if os.path.isfile(target):
                        has_cli = True
                        break
                    if sys.platform == "win32" and not cli.lower().endswith((".exe", ".cmd", ".bat")):
                        for ext in [".exe", ".cmd", ".bat"]:
                            if os.path.isfile(target + ext):
                                has_cli = True
                                break
                    if has_cli:
                        break
                if has_cli:
                    break

            has_data = False
            for dp in spec.data_paths:
                full_path = os.path.join(home, os.path.normpath(dp))
                if os.path.exists(full_path):
                    has_data = True
                    break

            if has_app or has_cli or has_data:
                results.append(DetectedTool(spec=spec, has_app=has_app, has_cli=has_cli, has_data=has_data))

        # Sort: supported first, then alphabetical by name
        results.sort(key=lambda t: (0 if t.supported else 1, t.spec.name.lower()))
        return results
