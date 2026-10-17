# RL-Screener — IRAC handoff (2026-10-17)

## Issue
MT5 Market Watch grade screener EA + mini Q-table idea test on 15m/1h/4h.
Central question: mini_idea_test.py imports features and mt5_data modules that are not in the repo.

## Rule
mini_idea_test.py docstring: test stretch-delta grade signal and beat baseline on held-out days. Doctrine: scalping-only; 5m CCI 30/100 burst entry; 1R=0.25% equity; max 4 concurrent; daily floor -3R; pyramid winners OK, add-to-losers banned.

## Application
3 commits 2026-08-16 (119efd1, 344391a, 245742c). Files: mini_idea_test.py (CCI_GATE=30, HOLD_BARS=8), MQL5/Experts/GradeScreener.mq5. Missing features.py, mt5_data.py -> script cannot run. Timeframes 15m+ not 5m.

## Conclusion
Status: incomplete/broken. Blocker: missing modules; no results.
Next: 1) Commit features.py and mt5_data.py. 2) Run test on 5m to match doctrine.
