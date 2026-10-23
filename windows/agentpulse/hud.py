"""Desktop Floating HUD for Windows using Tkinter and Win32 APIs."""
import sys
import os
import tkinter as tk
from tkinter import ttk
import threading
import time
from typing import Optional, Callable
from .models import SessionStats
from .format import Fmt
from .discovery import Monitor

class FloatingHUD:
    """Always-on-top, draggable, dark glass floating HUD bar."""

    def __init__(self, on_open_settings: Optional[Callable[[], None]] = None):
        self.root = tk.Tk()
        self.root.title("AgentPulse")
        self.on_open_settings = on_open_settings

        # Window styling
        self.root.overrideredirect(True)
        self.root.attributes("-topmost", True)
        try:
            self.root.attributes("-alpha", 0.92)
        except Exception:
            pass

        # Windows specific window styles (Toolwindow + NoActivate)
        self._apply_win32_styles()

        # State
        self.current_stats: Optional[SessionStats] = None
        self._drag_start_x = 0
        self._drag_start_y = 0

        # Build UI
        self._setup_ui()

        # Bind dragging
        self.hud_frame.bind("<ButtonPress-1>", self._start_drag)
        self.hud_frame.bind("<B1-Motion>", self._on_drag)

        # Right click menu
        self._setup_menu()

        # Initial position: top right of screen
        screen_w = self.root.winfo_screenwidth()
        self.root.geometry(f"+{screen_w - 380}+40")

    def _apply_win32_styles(self):
        if sys.platform == "win32":
            try:
                import ctypes
                hwnd = self.root.winfo_id()
                GWL_EXSTYLE = -20
                WS_EX_TOOLWINDOW = 0x00000080
                WS_EX_NOACTIVATE = 0x08000000
                user32 = ctypes.windll.user32
                style = user32.GetWindowLongW(hwnd, GWL_EXSTYLE)
                style |= WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE
                user32.SetWindowLongW(hwnd, GWL_EXSTYLE, style)
            except Exception:
                pass

    def _setup_ui(self):
        # Dark theme colors matching DeepSeek harness / macOS HUD
        self.bg_color = "#16181d"
        self.border_color = "#2a2e37"
        self.text_primary = "#f0f2f5"
        self.text_secondary = "#8e95a5"
        self.accent_green = "#22c55e"
        self.accent_blue = "#3b82f6"
        self.accent_amber = "#f59e0b"

        self.root.configure(bg=self.border_color)

        self.hud_frame = tk.Frame(self.root, bg=self.bg_color, padx=12, pady=6)
        self.hud_frame.pack(padx=1, pady=1)

        # 1. Model / Tool section
        self.tool_lbl = tk.Label(
            self.hud_frame, text="✦ AgentPulse", font=("Segoe UI", 10, "bold"),
            fg=self.accent_blue, bg=self.bg_color, cursor="hand2"
        )
        self.tool_lbl.pack(side=tk.LEFT, padx=(0, 10))

        # Divider
        tk.Label(self.hud_frame, text="|", fg=self.border_color, bg=self.bg_color).pack(side=tk.LEFT, padx=4)

        # 2. Speed section
        self.speed_lbl = tk.Label(
            self.hud_frame, text="— tok/s", font=("Segoe UI", 10, "bold"),
            fg=self.accent_green, bg=self.bg_color
        )
        self.speed_lbl.pack(side=tk.LEFT, padx=8)

        # Divider
        tk.Label(self.hud_frame, text="|", fg=self.border_color, bg=self.bg_color).pack(side=tk.LEFT, padx=4)

        # 3. Tokens section
        self.tokens_lbl = tk.Label(
            self.hud_frame, text="▤ 0 tok", font=("Segoe UI", 9),
            fg=self.text_primary, bg=self.bg_color
        )
        self.tokens_lbl.pack(side=tk.LEFT, padx=8)

        # Divider
        tk.Label(self.hud_frame, text="|", fg=self.border_color, bg=self.bg_color).pack(side=tk.LEFT, padx=4)

        # 4. Context section
        self.context_lbl = tk.Label(
            self.hud_frame, text="◔ 0%", font=("Segoe UI", 9),
            fg=self.text_secondary, bg=self.bg_color
        )
        self.context_lbl.pack(side=tk.LEFT, padx=(8, 4))

        # Close / Settings button
        self.opt_btn = tk.Label(
            self.hud_frame, text="⚙", font=("Segoe UI", 10),
            fg=self.text_secondary, bg=self.bg_color, cursor="hand2"
        )
        self.opt_btn.pack(side=tk.LEFT, padx=(6, 0))
        self.opt_btn.bind("<Button-1>", lambda e: self._open_settings())

    def _setup_menu(self):
        self.menu = tk.Menu(self.root, tearoff=0, bg="#20222a", fg="#ffffff", activebackground="#3b82f6")
        self.menu.add_command(label="打开设置与 Token 消耗…", command=self._open_settings)
        self.menu.add_separator()
        self.menu.add_command(label="刷新会话", command=self.update_stats)
        self.menu.add_command(label="退出 AgentPulse", command=self.root.quit)

        def show_menu(event):
            self.menu.post(event.x_root, event.y_root)

        self.hud_frame.bind("<Button-3>", show_menu)
        for child in self.hud_frame.winfo_children():
            child.bind("<Button-3>", show_menu)

    def _open_settings(self):
        if self.on_open_settings:
            self.on_open_settings()

    def _start_drag(self, event):
        self._drag_start_x = event.x
        self._drag_start_y = event.y

    def _on_drag(self, event):
        x = self.root.winfo_x() + (event.x - self._drag_start_x)
        y = self.root.winfo_y() + (event.y - self._drag_start_y)
        self.root.geometry(f"+{x}+{y}")

    def update_stats(self, stats: Optional[SessionStats] = None):
        if stats is None:
            stats = Monitor.latest_session()
        self.current_stats = stats

        if not stats:
            self.tool_lbl.config(text="✦ 等待会话…", fg=self.text_secondary)
            self.speed_lbl.config(text="— tok/s", fg=self.text_secondary)
            self.tokens_lbl.config(text="▤ 0 tok")
            self.context_lbl.config(text="◔ 0%")
            return

        model_name = stats.model or stats.source.display_name
        if len(model_name) > 16:
            model_name = model_name[:14] + "…"
        self.tool_lbl.config(text=f"✦ {model_name}", fg=self.accent_blue)

        # Speed
        if stats.uses_credits:
            sp = stats.display_recent_speed
            sp_text = f"{Fmt.credits_number(sp)} Credits/s" if sp is not None else "— Credits/s"
            self.speed_lbl.config(text=sp_text, fg=self.accent_green if sp else self.text_secondary)
            self.tokens_lbl.config(text=f"▤ {Fmt.credits_number(stats.credits)} Cr")
        else:
            sp = stats.recent_tps or stats.last_tps
            sp_text = Fmt.tps(sp)
            self.speed_lbl.config(text=sp_text, fg=self.accent_green if sp else self.text_secondary)
            self.tokens_lbl.config(text=f"▤ {Fmt.compact_tokens(stats.total_tokens)}")

        # Context
        frac = stats.context_fraction
        frac_text = Fmt.percent(frac, digits=0) if frac is not None else "—%"
        self.context_lbl.config(text=f"◔ {frac_text}")

    def start_polling(self, interval_sec: float = 1.0):
        def loop():
            while True:
                time.sleep(interval_sec)
                try:
                    stats = Monitor.latest_session()
                    self.root.after(0, self.update_stats, stats)
                except Exception:
                    pass

        t = threading.Thread(target=loop, daemon=True)
        t.start()

    def run(self):
        self.update_stats()
        self.start_polling()
        self.root.mainloop()
