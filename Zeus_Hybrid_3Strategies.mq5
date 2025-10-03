//+------------------------------------------------------------------+
//|                                    Zeus_Hybrid_3Strategies.mq5    |
//|                                          Combination de 3 Logiques |
//|                                                                    |
//| Stratégie 1: Daily Range Breakout (DRB)                          |
//| Stratégie 2: Mean Reversion avec ATR                             |
//| Stratégie 3: Adaptive Risk + Trailing Stop                       |
//| Seuil: 70% des conditions doivent être remplies                  |
//+------------------------------------------------------------------+
#property copyright "Zeus Trading System"
#property version   "1.00"
#property strict

#include <Trade\Trade.mqh>

//--- Input Parameters UNIQUES
input group "=== FTMO RISK MANAGEMENT ==="
input double InpRiskPerTrade = 0.30;           // Risque par trade (%)
input double InpMaxSimultaneousRisk = 3.0;     // Risque simultané max (%)
input double InpMaxDailyLoss = 3.0;            // Perte quotidienne max (%)
input double InpMaxDrawdown = 8.0;             // Drawdown max (%)
input int    InpMaxPositions = 10;             // Positions simultanées max

input group "=== STRATEGY 1: DAILY RANGE BREAKOUT ==="
input int    InpDRB_StartHour = 0;             // Heure début calcul range
input int    InpDRB_EndHour = 6;               // Heure fin calcul range
input int    InpDRB_TradingStartHour = 6;      // Heure début trading
input int    InpDRB_TradingEndHour = 22;       // Heure fin trading
input double InpDRB_RiskReward = 5.0;          // Risk:Reward ratio (1:5)
input double InpDRB_BreakoutBuffer = 5.0;      // Buffer breakout (points)

input group "=== STRATEGY 2: MEAN REVERSION ATR ==="
input int    InpMR_EMAPeriod = 200;            // Période EMA
input int    InpMR_ATRPeriod = 14;             // Période ATR
input double InpMR_ATRMultiplier = 2.0;        // Multiplicateur ATR
input double InpMR_MinATR = 0.0001;            // ATR minimum

input group "=== STRATEGY 3: ADAPTIVE TRAILING STOP ==="
input double InpTS_Phase1_Profit = 0.5;        // Phase 1: % profit pour BE
input double InpTS_Phase2_Profit = 1.5;        // Phase 2: % profit pour trailing +0.5%
input double InpTS_Phase3_Profit = 3.0;        // Phase 3: % profit pour trailing +1.5%
input double InpTS_ATRMultiplier = 2.0;        // Multiplicateur ATR pour distance

input group "=== CORRELATION & EXPOSURE ==="
input double InpMaxCorrelation = 0.80;         // Corrélation max autorisée
input int    InpCorrelationPeriod = 100;       // Période calcul corrélation
input ENUM_TIMEFRAMES InpCorrelationTF = PERIOD_H1; // Timeframe corrélation

input group "=== GENERAL SETTINGS ==="
input int    InpMagicNumber = 789456;          // Magic Number
input string InpTradeComment = "Zeus_Hybrid";  // Commentaire trades
input bool   InpVerboseLogs = true;            // Logs détaillés

//--- Currency pairs
string g_Symbols[] = {"EURUSD", "GBPUSD", "USDJPY", "USDCHF", "AUDUSD", "NZDUSD", "USDCAD"};

//--- Global variables
CTrade g_Trade;
datetime g_LastBarTime = 0;
datetime g_DailyResetTime = 0;
double g_DailyPnL = 0.0;
double g_InitialBalance = 0.0;
double g_PeakBalance = 0.0;

//--- Indicator handles
int g_EMA_Handle[];
int g_ATR_Handle[];

//--- Structures
struct DailyRangeData {
    double highPrice;
    double lowPrice;
    double rangeSize;
    datetime calculatedDate;
    bool isValid;
};

struct PositionData {
    ulong ticket;
    string symbol;
    double entryPrice;
    double initialRisk;
    double currentProfit;
    double currentProfitPercent;
};

//--- Daily range cache
DailyRangeData g_DailyRange[];

//+------------------------------------------------------------------+
//| Expert initialization function                                     |
//+------------------------------------------------------------------+
int OnInit()
{
    Print("===== ZEUS HYBRID 3 STRATEGIES - INITIALISATION =====");

    g_Trade.SetExpertMagicNumber(InpMagicNumber);
    g_Trade.SetDeviationInPoints(20);
    g_Trade.SetTypeFilling(ORDER_FILLING_FOK);
    g_Trade.SetAsyncMode(false);

    //--- Initialize arrays
    ArrayResize(g_EMA_Handle, ArraySize(g_Symbols));
    ArrayResize(g_ATR_Handle, ArraySize(g_Symbols));
    ArrayResize(g_DailyRange, ArraySize(g_Symbols));

    //--- Create indicator handles for all symbols
    for(int i = 0; i < ArraySize(g_Symbols); i++)
    {
        g_EMA_Handle[i] = iMA(g_Symbols[i], PERIOD_CURRENT, InpMR_EMAPeriod, 0, MODE_EMA, PRICE_CLOSE);
        g_ATR_Handle[i] = iATR(g_Symbols[i], PERIOD_CURRENT, InpMR_ATRPeriod);

        if(g_EMA_Handle[i] == INVALID_HANDLE || g_ATR_Handle[i] == INVALID_HANDLE)
        {
            Print("ERREUR: Impossible de créer les indicateurs pour ", g_Symbols[i]);
            return INIT_FAILED;
        }

        //--- Initialize daily range
        g_DailyRange[i].isValid = false;
        g_DailyRange[i].calculatedDate = 0;
    }

    //--- Initialize balance tracking
    g_InitialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    g_PeakBalance = g_InitialBalance;
    g_DailyResetTime = TimeCurrent();

    Print("Initialisation réussie - Balance: ", g_InitialBalance);
    Print("Paires surveillées: ", ArraySize(g_Symbols));
    Print("Seuil conditions: 70% (7/10 minimum)");

    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    //--- Release indicator handles
    for(int i = 0; i < ArraySize(g_Symbols); i++)
    {
        if(g_EMA_Handle[i] != INVALID_HANDLE) IndicatorRelease(g_EMA_Handle[i]);
        if(g_ATR_Handle[i] != INVALID_HANDLE) IndicatorRelease(g_ATR_Handle[i]);
    }

    Print("Zeus Hybrid déchargé - Raison: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
    //--- Check new bar
    datetime currentBarTime = iTime(_Symbol, PERIOD_CURRENT, 0);
    if(currentBarTime == g_LastBarTime) return;
    g_LastBarTime = currentBarTime;

    //--- Daily reset
    CheckDailyReset();

    //--- FTMO checks
    if(!CheckFTMOLimits()) return;

    //--- Update trailing stops for all positions
    UpdateAllTrailingStops();

    //--- Scan all symbols for trading opportunities
    for(int i = 0; i < ArraySize(g_Symbols); i++)
    {
        AnalyzeSymbol(g_Symbols[i], i);
    }
}

//+------------------------------------------------------------------+
//| Analyze symbol for trading opportunity                           |
//+------------------------------------------------------------------+
void AnalyzeSymbol(string symbol, int symbolIndex)
{
    //--- Check if symbol already has a position
    if(HasOpenPosition(symbol)) return;

    //--- Check correlation exposure
    if(!CheckCorrelationExposure(symbol)) return;

    //--- Update daily range
    UpdateDailyRange(symbol, symbolIndex);

    //--- Get market data
    double close = iClose(symbol, PERIOD_CURRENT, 1);
    double open = iOpen(symbol, PERIOD_CURRENT, 1);

    //--- Get indicator values
    double ema[], atr[];
    ArraySetAsSeries(ema, true);
    ArraySetAsSeries(atr, true);

    if(CopyBuffer(g_EMA_Handle[symbolIndex], 0, 0, 3, ema) < 3) return;
    if(CopyBuffer(g_ATR_Handle[symbolIndex], 0, 0, 3, atr) < 3) return;

    double currentATR = atr[1];
    double currentEMA = ema[1];

    //--- SCORE CONDITIONS (10 conditions totales)
    int conditionsTotal = 10;
    int conditionsPassed = 0;

    //--- Condition 1: Daily Range Breakout (Stratégie 1)
    bool drbBuySignal = false, drbSellSignal = false;
    if(g_DailyRange[symbolIndex].isValid)
    {
        double highBreakout = g_DailyRange[symbolIndex].highPrice + InpDRB_BreakoutBuffer * _Point;
        double lowBreakout = g_DailyRange[symbolIndex].lowPrice - InpDRB_BreakoutBuffer * _Point;

        drbBuySignal = (close > highBreakout);
        drbSellSignal = (close < lowBreakout);

        if(drbBuySignal || drbSellSignal) conditionsPassed++;
    }

    //--- Condition 2: Trading hours (Stratégie 1)
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    bool validTradingHours = (dt.hour >= InpDRB_TradingStartHour && dt.hour < InpDRB_TradingEndHour);
    if(validTradingHours) conditionsPassed++;

    //--- Condition 3: Mean Reversion - Price extension (Stratégie 2)
    double upperBand = currentEMA + (currentATR * InpMR_ATRMultiplier);
    double lowerBand = currentEMA - (currentATR * InpMR_ATRMultiplier);

    bool mrBuySignal = (close < lowerBand);  // Prix en dessous = buy mean reversion
    bool mrSellSignal = (close > upperBand); // Prix au dessus = sell mean reversion
    if(mrBuySignal || mrSellSignal) conditionsPassed++;

    //--- Condition 4: ATR minimum (Stratégie 2)
    bool atrValid = (currentATR > InpMinATR);
    if(atrValid) conditionsPassed++;

    //--- Condition 5: EMA trend
    bool emaTrendUp = (ema[1] > ema[2]);
    bool emaTrendDown = (ema[1] < ema[2]);
    if(emaTrendUp || emaTrendDown) conditionsPassed++;

    //--- Condition 6: Price vs EMA position
    bool priceAboveEMA = (close > currentEMA);
    bool priceBelowEMA = (close < currentEMA);
    if(priceAboveEMA || priceBelowEMA) conditionsPassed++;

    //--- Condition 7: Candle direction
    bool bullishCandle = (close > open);
    bool bearishCandle = (close < open);
    if(bullishCandle || bearishCandle) conditionsPassed++;

    //--- Condition 8: ATR increasing (volatility)
    bool atrIncreasing = (atr[1] > atr[2]);
    if(atrIncreasing) conditionsPassed++;

    //--- Condition 9: Range size valid
    bool rangeValid = (g_DailyRange[symbolIndex].isValid && g_DailyRange[symbolIndex].rangeSize > currentATR);
    if(rangeValid) conditionsPassed++;

    //--- Condition 10: Drawdown under control
    bool ddUnderControl = (CalculateCurrentDrawdown() < InpMaxDrawdown * 0.8); // 80% of max DD
    if(ddUnderControl) conditionsPassed++;

    //--- EVALUATE 70% THRESHOLD
    double successRate = (double)conditionsPassed / (double)conditionsTotal;

    if(InpVerboseLogs)
    {
        Print("=== ", symbol, " === Conditions: ", conditionsPassed, "/", conditionsTotal,
              " (", DoubleToString(successRate * 100, 1), "%)");
    }

    //--- Need at least 70% (7/10)
    if(successRate < 0.70) return;

    //--- Determine signal direction
    int buyScore = 0, sellScore = 0;

    if(drbBuySignal) buyScore++;
    if(drbSellSignal) sellScore++;
    if(mrBuySignal) buyScore++;
    if(mrSellSignal) sellScore++;
    if(emaTrendUp) buyScore++;
    if(emaTrendDown) sellScore++;
    if(priceAboveEMA) buyScore++;
    if(priceBelowEMA) sellScore++;
    if(bullishCandle) buyScore++;
    if(bearishCandle) sellScore++;

    //--- Execute trade
    if(buyScore > sellScore && buyScore >= 4)
    {
        OpenPosition(symbol, ORDER_TYPE_BUY, currentATR, close);
    }
    else if(sellScore > buyScore && sellScore >= 4)
    {
        OpenPosition(symbol, ORDER_TYPE_SELL, currentATR, close);
    }
}

//+------------------------------------------------------------------+
//| Open position with risk management                               |
//+------------------------------------------------------------------+
void OpenPosition(string symbol, ENUM_ORDER_TYPE orderType, double atr, double price)
{
    //--- Calculate position size
    double riskAmount = AccountInfoDouble(ACCOUNT_BALANCE) * (InpRiskPerTrade / 100.0);

    //--- Calculate SL/TP based on ATR and RR ratio
    double slDistance = atr * InpMR_ATRMultiplier;
    double tpDistance = slDistance * InpDRB_RiskReward;

    double sl = 0, tp = 0;

    if(orderType == ORDER_TYPE_BUY)
    {
        sl = price - slDistance;
        tp = price + tpDistance;
    }
    else if(orderType == ORDER_TYPE_SELL)
    {
        sl = price + slDistance;
        tp = price - tpDistance;
    }

    //--- Calculate lot size
    double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
    double slPoints = MathAbs(price - sl);

    double lotSize = (riskAmount / (slPoints / tickSize * tickValue));

    //--- Normalize lot size
    double minLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
    double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

    lotSize = MathFloor(lotSize / lotStep) * lotStep;
    lotSize = MathMax(minLot, MathMin(maxLot, lotSize));

    //--- Execute order
    bool result = false;

    if(orderType == ORDER_TYPE_BUY)
    {
        result = g_Trade.Buy(lotSize, symbol, 0, sl, tp, InpTradeComment);
    }
    else if(orderType == ORDER_TYPE_SELL)
    {
        result = g_Trade.Sell(lotSize, symbol, 0, sl, tp, InpTradeComment);
    }

    if(result)
    {
        Print(">>> ORDRE OUVERT: ", symbol, " | Type: ", EnumToString(orderType),
              " | Lot: ", lotSize, " | SL: ", sl, " | TP: ", tp);
    }
    else
    {
        Print("ERREUR ouverture ordre: ", symbol, " - ", g_Trade.ResultRetcodeDescription());
    }
}

//+------------------------------------------------------------------+
//| Update daily range for symbol                                    |
//+------------------------------------------------------------------+
void UpdateDailyRange(string symbol, int symbolIndex)
{
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);

    datetime today = StringToTime(IntegerToString(dt.year) + "." +
                                   IntegerToString(dt.mon) + "." +
                                   IntegerToString(dt.day) + " 00:00");

    //--- Check if already calculated for today
    if(g_DailyRange[symbolIndex].calculatedDate == today && g_DailyRange[symbolIndex].isValid)
        return;

    //--- Calculate range only after end hour
    if(dt.hour < InpDRB_EndHour)
    {
        g_DailyRange[symbolIndex].isValid = false;
        return;
    }

    //--- Find high and low between start and end hours
    datetime startTime = StringToTime(IntegerToString(dt.year) + "." +
                                       IntegerToString(dt.mon) + "." +
                                       IntegerToString(dt.day) + " " +
                                       IntegerToString(InpDRB_StartHour) + ":00");

    datetime endTime = StringToTime(IntegerToString(dt.year) + "." +
                                     IntegerToString(dt.mon) + "." +
                                     IntegerToString(dt.day) + " " +
                                     IntegerToString(InpDRB_EndHour) + ":00");

    int startBar = iBarShift(symbol, PERIOD_H1, startTime);
    int endBar = iBarShift(symbol, PERIOD_H1, endTime);

    if(startBar < 0 || endBar < 0) return;

    double rangeHigh = iHigh(symbol, PERIOD_H1, iHighest(symbol, PERIOD_H1, MODE_HIGH, startBar - endBar, endBar));
    double rangeLow = iLow(symbol, PERIOD_H1, iLowest(symbol, PERIOD_H1, MODE_LOW, startBar - endBar, endBar));

    g_DailyRange[symbolIndex].highPrice = rangeHigh;
    g_DailyRange[symbolIndex].lowPrice = rangeLow;
    g_DailyRange[symbolIndex].rangeSize = rangeHigh - rangeLow;
    g_DailyRange[symbolIndex].calculatedDate = today;
    g_DailyRange[symbolIndex].isValid = true;

    if(InpVerboseLogs)
    {
        Print("Daily Range calculé pour ", symbol, ": High=", rangeHigh, " Low=", rangeLow,
              " Size=", g_DailyRange[symbolIndex].rangeSize);
    }
}

//+------------------------------------------------------------------+
//| Update trailing stops for all positions (Stratégie 3)           |
//+------------------------------------------------------------------+
void UpdateAllTrailingStops()
{
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(ticket <= 0) continue;

        if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

        string symbol = PositionGetString(POSITION_SYMBOL);
        double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
        double currentPrice = PositionGetDouble(POSITION_PRICE_CURRENT);
        double currentSL = PositionGetDouble(POSITION_SL);
        ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

        //--- Calculate profit percentage
        double profitPercent = 0;
        if(posType == POSITION_TYPE_BUY)
        {
            profitPercent = ((currentPrice - entryPrice) / entryPrice) * 100.0;
        }
        else if(posType == POSITION_TYPE_SELL)
        {
            profitPercent = ((entryPrice - currentPrice) / entryPrice) * 100.0;
        }

        //--- Get ATR for this symbol
        int symbolIndex = GetSymbolIndex(symbol);
        if(symbolIndex < 0) continue;

        double atr[];
        ArraySetAsSeries(atr, true);
        if(CopyBuffer(g_ATR_Handle[symbolIndex], 0, 0, 2, atr) < 2) continue;

        double atrDistance = atr[1] * InpTS_ATRMultiplier;
        double newSL = currentSL;

        //--- Phase 1: +0.5% profit → SL to Breakeven
        if(profitPercent >= InpTS_Phase1_Profit && currentSL != entryPrice)
        {
            newSL = entryPrice;
            if(InpVerboseLogs) Print("Phase 1 - SL à Breakeven: ", symbol);
        }

        //--- Phase 2: +1.5% profit → Trailing to +0.5%
        else if(profitPercent >= InpTS_Phase2_Profit)
        {
            double targetProfit = entryPrice * (InpTS_Phase1_Profit / 100.0);

            if(posType == POSITION_TYPE_BUY)
            {
                newSL = entryPrice + targetProfit;
                if(newSL < currentSL) newSL = currentSL; // Never move SL backwards
            }
            else if(posType == POSITION_TYPE_SELL)
            {
                newSL = entryPrice - targetProfit;
                if(newSL > currentSL) newSL = currentSL;
            }

            if(InpVerboseLogs) Print("Phase 2 - Trailing +0.5%: ", symbol);
        }

        //--- Phase 3: +3% profit → Trailing to +1.5%
        else if(profitPercent >= InpTS_Phase3_Profit)
        {
            double targetProfit = entryPrice * (InpTS_Phase2_Profit / 100.0);

            if(posType == POSITION_TYPE_BUY)
            {
                newSL = entryPrice + targetProfit;
                if(newSL < currentSL) newSL = currentSL;
            }
            else if(posType == POSITION_TYPE_SELL)
            {
                newSL = entryPrice - targetProfit;
                if(newSL > currentSL) newSL = currentSL;
            }

            if(InpVerboseLogs) Print("Phase 3 - Trailing +1.5%: ", symbol);
        }

        //--- Modify SL if changed
        if(newSL != currentSL && newSL > 0)
        {
            double currentTP = PositionGetDouble(POSITION_TP);
            if(g_Trade.PositionModify(ticket, newSL, currentTP))
            {
                Print("Trailing Stop modifié: ", symbol, " | Nouveau SL: ", newSL,
                      " | Profit: ", DoubleToString(profitPercent, 2), "%");
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Check FTMO limits                                                |
//+------------------------------------------------------------------+
bool CheckFTMOLimits()
{
    double balance = AccountInfoDouble(ACCOUNT_BALANCE);

    //--- Daily loss check
    double dailyLossPercent = (g_DailyPnL / balance) * 100.0;
    if(dailyLossPercent <= -InpMaxDailyLoss)
    {
        Print("FTMO STOP: DAILY LOSS LIMIT ATTEINT (", DoubleToString(dailyLossPercent, 2), "%)");
        return false;
    }

    //--- Drawdown check
    double currentDD = CalculateCurrentDrawdown();
    if(currentDD >= InpMaxDrawdown)
    {
        Print("FTMO STOP: DRAWDOWN MAX ATTEINT (", DoubleToString(currentDD, 2), "%)");
        return false;
    }

    //--- Max positions check
    int openPositions = 0;
    for(int i = 0; i < PositionsTotal(); i++)
    {
        if(PositionGetTicket(i) > 0 && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
            openPositions++;
    }

    if(openPositions >= InpMaxPositions)
    {
        if(InpVerboseLogs) Print("Max positions atteint: ", openPositions);
        return false;
    }

    //--- Simultaneous risk check
    double totalRisk = CalculateTotalRisk();
    if(totalRisk >= InpMaxSimultaneousRisk)
    {
        if(InpVerboseLogs) Print("Risque simultané max atteint: ", DoubleToString(totalRisk, 2), "%");
        return false;
    }

    return true;
}

//+------------------------------------------------------------------+
//| Calculate current drawdown                                       |
//+------------------------------------------------------------------+
double CalculateCurrentDrawdown()
{
    double balance = AccountInfoDouble(ACCOUNT_BALANCE);

    if(balance > g_PeakBalance)
        g_PeakBalance = balance;

    double drawdown = ((g_PeakBalance - balance) / g_PeakBalance) * 100.0;

    return MathMax(0, drawdown);
}

//+------------------------------------------------------------------+
//| Calculate total risk from open positions                         |
//+------------------------------------------------------------------+
double CalculateTotalRisk()
{
    double totalRisk = 0.0;
    double balance = AccountInfoDouble(ACCOUNT_BALANCE);

    for(int i = 0; i < PositionsTotal(); i++)
    {
        if(PositionGetTicket(i) > 0 && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
        {
            double positionRisk = MathAbs(PositionGetDouble(POSITION_PROFIT));
            totalRisk += (positionRisk / balance) * 100.0;
        }
    }

    return totalRisk;
}

//+------------------------------------------------------------------+
//| Check correlation exposure                                        |
//+------------------------------------------------------------------+
bool CheckCorrelationExposure(string symbol)
{
    //--- Get all open positions
    for(int i = 0; i < PositionsTotal(); i++)
    {
        if(PositionGetTicket(i) <= 0) continue;
        if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

        string posSymbol = PositionGetString(POSITION_SYMBOL);
        if(posSymbol == symbol) continue;

        //--- Calculate correlation
        double correlation = CalculateCorrelation(symbol, posSymbol, InpCorrelationPeriod, InpCorrelationTF);

        if(MathAbs(correlation) > InpMaxCorrelation)
        {
            if(InpVerboseLogs)
            {
                Print("Corrélation trop élevée entre ", symbol, " et ", posSymbol, ": ",
                      DoubleToString(correlation, 3));
            }
            return false;
        }
    }

    return true;
}

//+------------------------------------------------------------------+
//| Calculate Pearson correlation between two symbols                |
//+------------------------------------------------------------------+
double CalculateCorrelation(string symbol1, string symbol2, int period, ENUM_TIMEFRAMES tf)
{
    double closes1[], closes2[];
    ArraySetAsSeries(closes1, true);
    ArraySetAsSeries(closes2, true);

    if(CopyClose(symbol1, tf, 0, period, closes1) < period) return 0;
    if(CopyClose(symbol2, tf, 0, period, closes2) < period) return 0;

    //--- Calculate means
    double mean1 = 0, mean2 = 0;
    for(int i = 0; i < period; i++)
    {
        mean1 += closes1[i];
        mean2 += closes2[i];
    }
    mean1 /= period;
    mean2 /= period;

    //--- Calculate correlation
    double numerator = 0, denom1 = 0, denom2 = 0;
    for(int i = 0; i < period; i++)
    {
        double diff1 = closes1[i] - mean1;
        double diff2 = closes2[i] - mean2;

        numerator += diff1 * diff2;
        denom1 += diff1 * diff1;
        denom2 += diff2 * diff2;
    }

    if(denom1 == 0 || denom2 == 0) return 0;

    return numerator / (MathSqrt(denom1) * MathSqrt(denom2));
}

//+------------------------------------------------------------------+
//| Check if symbol has open position                                |
//+------------------------------------------------------------------+
bool HasOpenPosition(string symbol)
{
    for(int i = 0; i < PositionsTotal(); i++)
    {
        if(PositionGetTicket(i) > 0 &&
           PositionGetInteger(POSITION_MAGIC) == InpMagicNumber &&
           PositionGetString(POSITION_SYMBOL) == symbol)
        {
            return true;
        }
    }
    return false;
}

//+------------------------------------------------------------------+
//| Get symbol index from array                                      |
//+------------------------------------------------------------------+
int GetSymbolIndex(string symbol)
{
    for(int i = 0; i < ArraySize(g_Symbols); i++)
    {
        if(g_Symbols[i] == symbol) return i;
    }
    return -1;
}

//+------------------------------------------------------------------+
//| Check and reset daily counters                                   |
//+------------------------------------------------------------------+
void CheckDailyReset()
{
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);

    datetime today = StringToTime(IntegerToString(dt.year) + "." +
                                   IntegerToString(dt.mon) + "." +
                                   IntegerToString(dt.day) + " 00:00");

    if(today > g_DailyResetTime)
    {
        g_DailyPnL = 0.0;
        g_DailyResetTime = today;

        Print("===== RESET QUOTIDIEN - Nouvelle journée de trading =====");
    }

    //--- Update daily P&L
    double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    g_DailyPnL = currentBalance - g_InitialBalance;
}
//+------------------------------------------------------------------+
