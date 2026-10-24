#!/bin/bash
# 跑中文段标转换的用例（与 scripts/fix_section_tags.py 对齐）。
set -euo pipefail
cd "$(dirname "$0")/.."
/usr/bin/xcrun swiftc -O gui/Sources/LocalMusic/SectionTags.swift Tools/test-section-tags/main.swift -o /tmp/cs-test-section-tags
/tmp/cs-test-section-tags
