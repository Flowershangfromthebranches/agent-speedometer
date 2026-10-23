"""Core unit tests for AgentPulse Windows engine."""
import os
import sys
import unittest
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
from datetime import datetime, timezone, timedelta
from agentpulse.models import RequestRecord, TokenTotals, SessionStats, AgentSource
from agentpulse.format import Fmt
from agentpulse.pricing import ModelPricingTable
from agentpulse.parsers import ClaudeParser, CodexParser, QoderParser
from agentpulse.tools import ToolRegistry, ToolScanner

class TestAgentPulseCore(unittest.TestCase):
    def test_format_helpers(self):
        self.assertEqual(Fmt.tokens(1000), "1,000 tok")
        self.assertEqual(Fmt.compact_tokens(1500000), "1.5M")
        self.assertEqual(Fmt.compact_tokens(25000), "25K")
        self.assertEqual(Fmt.tps(120.4), "120 tok/s")
        self.assertEqual(Fmt.tps(85.34), "85.3 tok/s")
        self.assertEqual(Fmt.usd(12.345), "$12.3")
        self.assertEqual(Fmt.usd(8.456), "$8.46")
        self.assertEqual(Fmt.credits_number(0.12345), "0.1235")
        self.assertEqual(Fmt.credits_number(1.5), "1.50")

    def test_pricing_normalization_and_estimate(self):
        key = ModelPricingTable.canonical_key("anthropic/claude-3-5-sonnet-20241022")
        self.assertEqual(key, "claude-3-5-sonnet")
        price = ModelPricingTable.price("claude-3-5-sonnet")
        self.assertIsNotNone(price)
        self.assertEqual(price.input, 3.0)
        self.assertEqual(price.output, 15.0)

        tot = TokenTotals(output=1000, uncached_input=2000, cache_read=5000, cache_write=1000)
        cost = ModelPricingTable.estimate(tot, "claude-3-5-sonnet")
        # 2000*3/1M + 1000*15/1M + 5000*0.3/1M + 1000*3.75/1M = 0.006 + 0.015 + 0.0015 + 0.00375 = 0.02625
        self.assertAlmostEqual(cost.usd, 0.02625, places=4)

    def test_claude_parser(self):
        parser = ClaudeParser()
        t0 = datetime(2026, 10, 23, 10, 0, 0, tzinfo=timezone.utc)
        t1 = datetime(2026, 10, 23, 10, 0, 5, tzinfo=timezone.utc)
        parser.consume({
            "type": "user",
            "timestamp": t0.isoformat(),
            "message": {"content": "Hello"}
        })
        parser.consume({
            "type": "assistant",
            "timestamp": t1.isoformat(),
            "message": {
                "id": "msg_001",
                "model": "claude-3-5-sonnet-20241022",
                "usage": {
                    "input_tokens": 500,
                    "cache_read_input_tokens": 200,
                    "output_tokens": 150
                }
            }
        })
        stats = parser.acc.snapshot(source=AgentSource(id="claude"), path="test.jsonl")
        self.assertEqual(stats.turns, 1)
        self.assertEqual(stats.steps, 1)
        self.assertEqual(stats.output_tokens, 150)
        # Speed: 150 tokens / 5s = 30 tok/s
        self.assertAlmostEqual(stats.recent_tps, 30.0, places=1)

    def test_codex_parser_ttft(self):
        parser = CodexParser()
        t0 = datetime(2026, 10, 23, 10, 0, 0, tzinfo=timezone.utc)
        t_first = datetime(2026, 10, 23, 10, 0, 1, tzinfo=timezone.utc) # 1s TTFT
        t_end = datetime(2026, 10, 23, 10, 0, 3, tzinfo=timezone.utc)   # 2s decode
        parser.consume({
            "type": "event_msg",
            "timestamp": t0.isoformat(),
            "payload": {"type": "task_started", "model_context_window": 200000}
        })
        parser.consume({
            "type": "event_msg",
            "timestamp": t_end.isoformat(),
            "payload": {
                "type": "item_completed",
                "item": {
                    "type": "agent_message",
                    "started_at_ms": t_first.timestamp() * 1000.0
                }
            }
        })
        parser.consume({
            "type": "token_usage_record",
            "timestamp": t_end.isoformat(),
            "payload": {
                "response_id": "resp_001",
                "usage": {"input_tokens": 1000, "output_tokens": 100, "cached_input_tokens": 800}
            }
        })
        stats = parser.acc.snapshot(source=AgentSource(id="codex"), path="rollout-001.jsonl")
        self.assertEqual(stats.steps, 1)
        self.assertTrue(stats.ttft_available)
        self.assertAlmostEqual(stats.avg_ttft, 1.0, places=2)
        # Decode duration: 2s (t_end - t_first). Speed: 100 / 2 = 50 tok/s
        self.assertAlmostEqual(stats.recent_tps, 50.0, places=1)

    def test_qoder_parser(self):
        parser = QoderParser()
        t0 = datetime(2026, 10, 23, 10, 0, 0, tzinfo=timezone.utc)
        t1 = datetime(2026, 10, 23, 10, 0, 10, tzinfo=timezone.utc)
        parser.consume({
            "type": "user",
            "timestamp": t0.isoformat(),
            "message": {"content": "Help"}
        })
        parser.consume({
            "type": "assistant",
            "timestamp": t1.isoformat(),
            "message": {
                "id": "qoder_req_1",
                "model": "gfmodel",
                "usage": {
                    "input_tokens": 300,
                    "output_tokens": 100,
                    "credits": 2.5,
                    "billable": True,
                    "context_usage_ratio": 0.45
                }
            }
        })
        stats = parser.acc.snapshot(source=AgentSource(id="qoder-cn"), path="qoder.jsonl")
        self.assertTrue(stats.uses_credits)
        self.assertAlmostEqual(stats.credits, 2.5, places=2)
        # Rate: 2.5 credits / 10s = 0.25 Credits/s
        self.assertAlmostEqual(stats.recent_credit_rate, 0.25, places=2)
        self.assertAlmostEqual(stats.reported_context_fraction, 0.45, places=2)

if __name__ == "__main__":
    unittest.main()
