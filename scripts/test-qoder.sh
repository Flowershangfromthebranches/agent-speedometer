#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p .build/qoder-check
cp scripts/qoder-check.swift .build/qoder-check/main.swift
xcrun swiftc -module-cache-path .build/module-cache \
  Sources/AgentPulse/{Model,Format,Tools,Parsers,MoreParsers,QoderParser,Readers,ModelPricing,TokenUsage}.swift \
  .build/qoder-check/main.swift -o .build/qoder-check/check
.build/qoder-check/check
