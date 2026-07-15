#!/usr/bin/env python3
"""
kiro-cli の /usage 出力を stdin から受け取り、
RunCat Neo カスタムメトリクス JSON を stdout に出力する。
"""

import re
import json
import sys
from datetime import datetime, timezone

raw = sys.stdin.read()

# ANSI 除去
ansi_pattern = re.compile(r'\x1b\[[0-9;?]*[A-Za-z]|\x1b\].*?\x07')
text = ansi_pattern.sub('', raw)
# kiro-cli プロンプト装飾除去
text = text.replace('λ↯', '')
text = re.sub(r'[\x00-\x08\x0b\x0c\x0e-\x1f]', '', text)

metrics = []
plan_name = "Kiro"
credits_used = 0.0
credits_total = 0.0
credits_percent = 0.0
bonus_used = None
bonus_total = None
bonus_expiry_days = None
resets_at = None
matched_percent = False
matched_credits = False

# --- プラン名パース ---
plan_match = re.search(r'\|\s*(KIRO\s+\w+)', text)
if plan_match:
    plan_name = plan_match.group(1).strip()

new_plan_match = re.search(r'Plan:\s*(.+)', text)
if new_plan_match:
    plan_line = new_plan_match.group(1).strip().split('\n')[0].strip()
    if plan_line:
        plan_name = plan_line

estimated_match = re.search(r'Estimated Usage\s*\|[^\n|]*\|\s*([A-Z][A-Z0-9 ]+)', text)
if estimated_match:
    plan_name = estimated_match.group(1).strip()


def format_plan_name(name):
    words = name.split()
    result = []
    for w in words:
        if w.upper() == "KIRO":
            result.append("Kiro")
        else:
            result.append(w.capitalize() if w.isupper() else w)
    return " ".join(result)


plan_name = format_plan_name(plan_name)

# --- クレジット % パース ---
# "████...█ X%" or just "X%" at end of progress bar line
pct_match = re.search(r'(\d+)%', text)
if pct_match:
    credits_percent = float(pct_match.group(1))
    matched_percent = True

# --- クレジット使用量パース ---
# "(X.XX of Y covered in plan)"
credits_match = re.search(r'\((\d+\.?\d*)\s+of\s+(\d+)\s+covered', text)
if credits_match:
    credits_used = float(credits_match.group(1))
    credits_total = float(credits_match.group(2))
    matched_credits = True

if not matched_percent and matched_credits and credits_total > 0:
    credits_percent = (credits_used / credits_total) * 100.0

# If we have credits info, recalculate percent from it (more accurate)
if matched_credits and credits_total > 0:
    credits_percent = (credits_used / credits_total) * 100.0

# --- ボーナスクレジット ---
bonus_match = re.search(r'Bonus credits:\s*(\d+\.?\d*)/(\d+)', text)
if bonus_match:
    bonus_used = float(bonus_match.group(1))
    bonus_total = float(bonus_match.group(2))

expiry_match = re.search(r'expires in (\d+) days?', text)
if expiry_match:
    bonus_expiry_days = int(expiry_match.group(1))

# --- リセット日 ---
reset_match = re.search(r'resets on (\d{4}-\d{2}-\d{2}|\d{2}/\d{2})', text)
if reset_match:
    resets_at = reset_match.group(1)

# --- Overages ---
overages_status = None
overage_credits = None
overage_cost = None

overages_match = re.search(r'(?i)Overages:\s*([^\n]+)', text)
if overages_match:
    overages_status = overages_match.group(1).strip()

overage_credits_match = re.search(r'(?i)Credits used:\s*(\d+\.?\d*)', text)
if overage_credits_match:
    overage_credits = float(overage_credits_match.group(1))

overage_cost_match = re.search(r'(?i)Est\.\s*cost:\s*\$?(\d+\.?\d*)\s*USD', text)
if overage_cost_match:
    overage_cost = float(overage_cost_match.group(1))

# --- メトリクス組み立て ---
metrics.append({
    "title": "Plan",
    "formattedValue": plan_name
})

if matched_percent or matched_credits:
    if matched_credits:
        metrics.append({
            "title": "Credits",
            "formattedValue": f"{credits_used:.1f}/{credits_total:.0f}",
            "normalizedValue": round(min(credits_percent / 100.0, 1.0), 4)
        })
    else:
        metrics.append({
            "title": "Credits",
            "formattedValue": f"{credits_percent:.1f}%",
            "normalizedValue": round(min(credits_percent / 100.0, 1.0), 4)
        })

if bonus_used is not None and bonus_total is not None and bonus_total > 0:
    bonus_pct = (bonus_used / bonus_total) * 100.0
    bonus_label = "Bonus"
    if bonus_expiry_days is not None:
        bonus_label = f"Bonus ({bonus_expiry_days}d)"
    metrics.append({
        "title": bonus_label,
        "formattedValue": f"{bonus_used:.1f}/{bonus_total:.0f}",
        "normalizedValue": round(min(bonus_pct / 100.0, 1.0), 4)
    })

if resets_at:
    metrics.append({
        "title": "Resets",
        "formattedValue": resets_at
    })

if overages_status and overages_status.lower() != "disabled":
    if overage_credits is not None:
        ov_label = f"{overage_credits:.1f} credits"
        if overage_cost is not None:
            ov_label += f" (~${overage_cost:.2f})"
        metrics.append({
            "title": "Overage",
            "formattedValue": ov_label
        })

# --- metricsBarValue ---
bar_value = None
if matched_credits:
    bar_value = f"{credits_percent:.0f}%"
elif matched_percent:
    bar_value = f"{credits_percent:.0f}%"

# --- 出力 ---
snapshot = {
    "title": "Kiro",
    "symbol": "sparkles",
    "metrics": metrics,
    "lastUpdatedDate": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
}
if bar_value:
    snapshot["metricsBarValue"] = bar_value

print(json.dumps(snapshot, ensure_ascii=False))
