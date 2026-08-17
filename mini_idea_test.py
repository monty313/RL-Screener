"""Quick idea test for S3 (15m / 1h / 4h): grade expectancy, then tiny tabular Q.

This is not the full agent. It answers: does stretch-delta grade have signal
on this symbol, and can a 20-state Q-table beat a dumb baseline on held-out days?
"""

from __future__ import annotations

import argparse
import sys

import MetaTrader5 as mt5
import numpy as np
import pandas as pd

from features import rates_to_df
from mt5_data import account_line, connect, fetch_rates, shutdown

BB_N = 20
CCI_N = 14
CCI_GATE = 30
HOLD_BARS = 8
STOP_SIGMA = 1.0
TRAIN_FRAC = 0.70
EPISODES = 8
SEED = 7


def zscore(close: pd.Series, n: int = BB_N) -> pd.Series:
    mu = close.rolling(n).mean()
    sd = close.rolling(n).std(ddof=0)
    return (close - mu) / sd.replace(0.0, np.nan)


def cci(df: pd.DataFrame, n: int = CCI_N) -> pd.Series:
    tp = (df["high"] + df["low"] + df["close"]) / 3.0
    sma = tp.rolling(n).mean()
    mad = (tp - sma).abs().rolling(n).mean()
    return (tp - sma) / (0.015 * mad.replace(0.0, np.nan))


def flip_gate(close: pd.Series, z: pd.Series, shift: int = 4) -> pd.Series:
    dma = close.rolling(BB_N).mean().shift(shift)
    bull = (z > 0) & (close > dma)
    bear = (z < 0) & (close < dma)
    return bull | bear


def fetch_h4(symbol: str, count: int) -> pd.DataFrame:
    rates = mt5.copy_rates_from_pos(symbol, mt5.TIMEFRAME_H4, 0, count)
    if rates is None or len(rates) == 0:
        raise RuntimeError(f"No H4 data for {symbol}")
    return rates_to_df(rates)


def asof_last(base: pd.DataFrame, other: pd.DataFrame, cols: list[str]) -> pd.DataFrame:
    left = base[["time"]].sort_values("time")
    right = other[["time", *cols]].sort_values("time")
    merged = pd.merge_asof(left, right, on="time", direction="backward")
    return merged


def build_s3(m15: pd.DataFrame, h1: pd.DataFrame, h4: pd.DataFrame) -> pd.DataFrame:
    l = m15.copy()
    n = h1.copy()
    f = h4.copy()
    l["z"] = zscore(l["close"])
    n["z"] = zscore(n["close"])
    f["z"] = zscore(f["close"])
    l["sigma"] = l["close"].rolling(BB_N).std(ddof=0)
    f["cci"] = cci(f)
    n["gate"] = flip_gate(n["close"], n["z"])
    f["gate"] = flip_gate(f["close"], f["z"])

    out = l[["time", "open", "high", "low", "close", "z", "sigma"]].rename(
        columns={"z": "z_l", "sigma": "sigma_l"}
    )
    out = out.merge(
        asof_last(out, n, ["z", "gate"]).rename(columns={"z": "z_n", "gate": "gate_n"}),
        on="time",
        how="left",
    )
    out = out.merge(
        asof_last(out, f, ["z", "gate", "cci"]).rename(
            columns={"z": "z_f", "gate": "gate_f", "cci": "cci_f"}
        ),
        on="time",
        how="left",
    )
    out["align"] = np.sign(out["z_f"]) == np.sign(out["z_n"])
    out["align"] = out["align"] & (out["z_f"] != 0) & (out["z_n"] != 0)
    out["cci_ok"] = out["cci_f"].abs() >= CCI_GATE
    out["legal"] = out["align"] & out["gate_n"] & out["gate_f"] & out["cci_ok"]
    out["dz"] = out["z_f"] - out["z_l"]
    out["grade"] = np.where(out["legal"], np.sign(out["z_f"]) * out["dz"], 0.0)
    out["shell_l"] = out["z_l"].round().clip(-4, 4)
    out["shell_n"] = out["z_n"].round().clip(-4, 4)
    out["shell_f"] = out["z_f"].round().clip(-4, 4)
    out["dir"] = np.sign(out["z_f"])
    return out.dropna().reset_index(drop=True)


def label_forward(df: pd.DataFrame, hold: int, stop_sigma: float) -> pd.DataFrame:
    close = df["close"].to_numpy()
    high = df["high"].to_numpy()
    low = df["low"].to_numpy()
    sigma = df["sigma_l"].to_numpy()
    direction = df["dir"].to_numpy()
    n = len(df)
    r_mult = np.full(n, np.nan)
    win = np.full(n, np.nan)
    for i in range(n - hold):
        d = direction[i]
        if d == 0 or not np.isfinite(sigma[i]) or sigma[i] <= 0:
            continue
        entry = close[i]
        stop_dist = stop_sigma * sigma[i]
        pnl = 0.0
        stopped = False
        for j in range(1, hold + 1):
            if d > 0:
                if low[i + j] <= entry - stop_dist:
                    pnl = -stop_dist
                    stopped = True
                    break
                pnl = high[i + j] - entry
            else:
                if high[i + j] >= entry + stop_dist:
                    pnl = -stop_dist
                    stopped = True
                    break
                pnl = entry - low[i + j]
        if not stopped:
            pnl = d * (close[i + hold] - entry)
        r_mult[i] = pnl / stop_dist
        win[i] = 1.0 if r_mult[i] > 0 else 0.0
    out = df.copy()
    out["r"] = r_mult
    out["win"] = win
    return out.dropna(subset=["r"]).reset_index(drop=True)


def summarize(df: pd.DataFrame, title: str) -> None:
    print(f"\n{title}")
    print("-" * 64)
    if df.empty:
        print("  no rows")
        return
    print(
        f"  n={len(df):5d}  mean R={df['r'].mean():+.3f}  "
        f"win={100 * df['win'].mean():.1f}%  "
        f"median R={df['r'].median():+.3f}"
    )


def grade_buckets(df: pd.DataFrame) -> None:
    legal = df[df["legal"]].copy()
    print("\nGrade quintiles on legal setups (direction = sign of far HTF)")
    print("-" * 64)
    if len(legal) < 50:
        print("  not enough legal rows")
        return
    legal["q"] = pd.qcut(legal["grade"], 5, labels=["Q1 low", "Q2", "Q3", "Q4", "Q5 high"], duplicates="drop")
    rows = []
    for name, g in legal.groupby("q", observed=True):
        rows.append(
            [
                str(name),
                len(g),
                f"{g['r'].mean():+.3f}",
                f"{100 * g['win'].mean():.1f}%",
                f"{g['grade'].mean():+.2f}",
            ]
        )
    print(f"  {'bucket':<10} {'n':>6} {'mean R':>8} {'win':>7} {'avg grade':>10}")
    for row in rows:
        print(f"  {row[0]:<10} {row[1]:6d} {row[2]:>8} {row[3]:>7} {row[4]:>10}")
    q = legal.groupby("q", observed=True)["r"].mean()
    if "Q1 low" in q.index and "Q5 high" in q.index:
        spread = float(q.loc["Q5 high"] - q.loc["Q1 low"])
        verdict = "PASS" if spread > 0 else "FAIL"
        print(f"\n  Q5 - Q1 mean R = {spread:+.3f}  ->  {verdict} (need Q5 > Q1)")


def take_nonoverlap(df: pd.DataFrame, hold: int) -> pd.DataFrame:
    """Keep the first legal bar, skip until the hold expires."""
    legal = df[df["legal"]].sort_values("time")
    kept = []
    next_ok = None
    for row in legal.itertuples(index=False):
        ts = row.time
        if next_ok is not None and ts < next_ok:
            continue
        kept.append(row)
        next_ok = ts + pd.Timedelta(minutes=15 * hold)
    if not kept:
        return legal.iloc[0:0]
    return pd.DataFrame(kept)


def nonoverlap_report(df: pd.DataFrame) -> None:
    one = take_nonoverlap(df, HOLD_BARS)
    print("\nNon-overlapping legal entries (one trade at a time)")
    print("-" * 64)
    if len(one) < 30:
        print(f"  only {len(one)} trades")
        return
    print(
        f"  n={len(one):5d}  mean R={one['r'].mean():+.3f}  "
        f"win={100 * one['win'].mean():.1f}%  "
        f"median R={one['r'].median():+.3f}"
    )
    one = one.copy()
    one["q"] = pd.qcut(
        one["grade"], 5, labels=["Q1 low", "Q2", "Q3", "Q4", "Q5 high"], duplicates="drop"
    )
    print(f"  {'bucket':<10} {'n':>6} {'mean R':>8} {'win':>7}")
    means = {}
    for name, g in one.groupby("q", observed=True):
        means[str(name)] = g["r"].mean()
        print(
            f"  {str(name):<10} {len(g):6d} {g['r'].mean():>+8.3f} "
            f"{100 * g['win'].mean():5.1f}%"
        )
    if "Q1 low" in means and "Q5 high" in means:
        spread = means["Q5 high"] - means["Q1 low"]
        print(f"\n  Q5 - Q1 (non-overlap) = {spread:+.3f}")


def cost_haircut(df: pd.DataFrame) -> None:
    legal = df[df["legal"]]
    sig = legal["sigma_l"].median()
    if not np.isfinite(sig) or sig <= 0:
        return
    # EURUSD: 0.00010 = 1 pip. Round-trip 1.2 pips as a harsh demo-to-live haircut.
    pip = 0.00010
    spread = 1.2 * pip
    cost_r = spread / (STOP_SIGMA * sig)
    print("\nSpread haircut (rough)")
    print("-" * 64)
    print(f"  median 15m sigma = {sig:.5f}   1.2 pip / 1-sigma stop = {cost_r:.3f} R")
    q5 = legal.loc[legal["grade"] >= legal["grade"].quantile(0.8), "r"].mean()
    print(f"  overlapping top-grade mean R after cost ~ {q5 - cost_r:+.3f}")
    print("  If non-overlap Q5 is near this cost, the live edge is gone.")


def state_id(row: pd.Series) -> int:
    align = 1 if row["align"] else 0
    gate = 1 if bool(row["gate_n"] and row["gate_f"] and row["cci_ok"]) else 0
    if not np.isfinite(row["grade"]):
        bucket = 0
    elif row["grade"] <= 0:
        bucket = 0
    elif row["grade"] < 1:
        bucket = 1
    elif row["grade"] < 2:
        bucket = 2
    else:
        bucket = 3
    return align * 8 + gate * 4 + bucket


def train_q(train: pd.DataFrame) -> np.ndarray:
    rng = np.random.default_rng(SEED)
    q = np.zeros((16, 2), dtype=float)
    visits = np.zeros((16, 2), dtype=float)
    idx = train.index.to_numpy().copy()
    for _ in range(EPISODES):
        rng.shuffle(idx)
        for i in idx:
            row = train.loc[i]
            s = state_id(row)
            a = int(rng.integers(0, 2))
            reward = 0.0 if a == 0 else float(row["r"])
            visits[s, a] += 1
            alpha = 1.0 / visits[s, a]
            q[s, a] += alpha * (reward - q[s, a])
    return q


def policy_r(df: pd.DataFrame, q: np.ndarray) -> pd.Series:
    rewards = []
    for i in range(len(df)):
        s = state_id(df.iloc[i])
        a = int(np.argmax(q[s]))
        rewards.append(0.0 if a == 0 else float(df.iloc[i]["r"]))
    return pd.Series(rewards, index=df.index)


def eval_policies(train: pd.DataFrame, test: pd.DataFrame) -> None:
    print("\nMini tabular Q  (16 states x skip/take)")
    print("-" * 64)
    q = train_q(train)
    q_r = policy_r(test, q)
    always = test.loc[test["legal"], "r"]
    random_take = test["r"].where(np.random.default_rng(SEED).random(len(test)) < 0.15, 0.0)
    print(f"  train bars {len(train)}   test bars {len(test)}")
    print(f"  Q-table on test          mean R/bar {q_r.mean():+.4f}   trades {(q_r != 0).sum()}")
    print(
        f"  Always take legal        mean R/bar {always.sum() / len(test):+.4f}   "
        f"trades {len(always)}"
    )
    print(
        f"  Random 15% take          mean R/bar {random_take.mean():+.4f}   "
        f"trades {(random_take != 0).sum()}"
    )
    beat_always = q_r.mean() > (always.sum() / len(test))
    print(
        "\n  Q vs always-legal  ->  "
        + ("PASS (Q more selective or better)" if beat_always else "FAIL (no edge over taking every legal setup)")
    )


def main() -> None:
    parser = argparse.ArgumentParser(description="Mini S3 idea test: grade + tabular Q")
    parser.add_argument("--symbol", default="EURUSD")
    parser.add_argument("--m15-bars", type=int, default=8000)
    parser.add_argument("--hold", type=int, default=HOLD_BARS)
    args = parser.parse_args()

    print("=" * 64)
    print(f"MINI IDEA TEST  S3  {args.symbol}  15m / 1h / 4h")
    print("=" * 64)

    try:
        connect()
    except RuntimeError as exc:
        print(f"ERROR: {exc}")
        sys.exit(1)

    try:
        print(account_line())
        m15 = fetch_rates(args.symbol, "15m", args.m15_bars)
        h1 = fetch_rates(args.symbol, "1h", max(400, args.m15_bars // 4 + 50))
        h4 = fetch_h4(args.symbol, max(200, args.m15_bars // 16 + 50))
        feat = build_s3(m15, h1, h4)
        labeled = label_forward(feat, hold=args.hold, stop_sigma=STOP_SIGMA)
        print(
            f"\nBars with labels: {len(labeled)}   "
            f"legal: {int(labeled['legal'].sum())}   "
            f"hold={args.hold} x 15m   stop={STOP_SIGMA} sigma"
        )
        summarize(labeled, "All bars (illegal grade=0, still labeled)")
        summarize(labeled[labeled["legal"]], "Legal only (align + both gates + CCI>=30)")
        summarize(labeled[~labeled["legal"]], "Illegal only")
        grade_buckets(labeled)
        nonoverlap_report(labeled)
        cost_haircut(labeled)

        cut = int(len(labeled) * TRAIN_FRAC)
        train, test = labeled.iloc[:cut], labeled.iloc[cut:]
        eval_policies(train, test)
        print("\nRead this as a signal check, not a trading system.")
        print("If Q5 <= Q1, stop. The grade is not predicting snap-back on this set.")
    finally:
        shutdown()


if __name__ == "__main__":
    main()
