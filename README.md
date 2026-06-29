# xau5m

High-risk MetaTrader 5 Expert Advisor for XAUUSD M5 demo/stress testing.

## Expert Advisor

- Source: `MQL5/Experts/XAU5M_HighRisk_Timer.mq5`
- Platform: MetaTrader 5
- Symbol: XAUUSD only
- Timeframe logic: M5
- Default lot size: `0.10`
- Max simultaneous positions: `5`
- Schedule: attempts to open one position on each new M5 candle

## Logic

This EA is intentionally aggressive. It opens a new 0.10 lot position every 5 minutes while the EA has fewer than 5 open positions.

Direction is selected by a momentum/trend score using:

- EMA 20/50 trend and slope
- RSI 14 bias
- MACD 12/26/9 histogram direction
- previous M5 candle body and breakout behavior
- ATR 14 for SL/TP sizing

Positions are closed by:

- Stop Loss
- Take Profit
- break-even / ATR trailing stop
- `MaxHoldMinutes`, default 25 minutes

## Default Safety Guards

Even though the strategy is high risk, the EA keeps basic safety guards:

- `RequireDemoAccount = true`
- XAUUSD-only symbol check
- max 5 positions by EA magic number
- spread filter
- margin check before opening orders

This is not financial advice. Do not use on a live account without rewriting and backtesting the risk model.

## Suggested Demo Use

Attach to an XAUUSD M5 chart on a demo hedge account.

Key inputs:

```text
Lots = 0.10
OpenEveryMinutes = 5
MaxOpenPositions = 5
MaxHoldMinutes = 25
ATRStopMultiplier = 1.00
ATRTakeProfitMultiplier = 1.20
```

## Validation

Compiled locally with MetaEditor:

```text
Result: 0 errors, 0 warnings
```
