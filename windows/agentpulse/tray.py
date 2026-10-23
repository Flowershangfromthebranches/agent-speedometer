"""System Tray integration for Windows."""
import os
import threading
from typing import Optional, Callable

class SystemTray:
    def __init__(self, on_open_hud: Optional[Callable[[], None]] = None,
                 on_open_dashboard: Optional[Callable[[], None]] = None,
                 on_exit: Optional[Callable[[], None]] = None):
        self.on_open_hud = on_open_hud
        self.on_open_dashboard = on_open_dashboard
        self.on_exit = on_exit
        self._icon = None

    def start(self):
        try:
            import pystray
            from PIL import Image, ImageDraw

            # Create simple green pulse tray icon in memory
            image = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
            draw = ImageDraw.Draw(image)
            draw.ellipse((8, 8, 56, 56), fill="#22c55e", outline="#16a34a", width=3)
            draw.polygon([(26, 32), (32, 20), (38, 44), (44, 32)], fill="#ffffff")

            menu = pystray.Menu(
                pystray.MenuItem("打开悬浮条", lambda: self.on_open_hud() if self.on_open_hud else None),
                pystray.MenuItem("打开设置与 Token 消耗…", lambda: self.on_open_dashboard() if self.on_open_dashboard else None),
                pystray.Menu.SEPARATOR,
                pystray.MenuItem("退出 AgentPulse", lambda: self._quit())
            )
            self._icon = pystray.Icon("AgentPulse", image, "AgentPulse 速度表", menu)
            t = threading.Thread(target=self._icon.run, daemon=True)
            t.start()
        except Exception:
            # Pystray not installed or headless; HUD still works standalone
            pass

    def _quit(self):
        if self._icon:
            self._icon.stop()
        if self.on_exit:
            self.on_exit()
