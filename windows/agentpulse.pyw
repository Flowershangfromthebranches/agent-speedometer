#!/usr/bin/env pythonw
"""Silent GUI entry point for Windows (no console window)."""
import os
import runpy
import sys

here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, here)

if __name__ == "__main__":
    runpy.run_path(os.path.join(here, "agentpulse.py"), run_name="__main__")
