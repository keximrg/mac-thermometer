#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
rm -rf "$ROOT/.build"
echo "已清理 Thermometer 项目构建缓存：$ROOT/.build"
