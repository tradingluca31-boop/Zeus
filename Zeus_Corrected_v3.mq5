//+------------------------------------------------------------------+
//|                                           Zeus_Corrected_v3.mq5  |
//|                             FILTRES vs SIGNAUX - Version Finale  |
//|                                                                    |
//| FILTRES ÉLIMINATOIRES (H4):                                       |
//|   1. RSI H4 > 80 (surachat) ou < 25 (survente)                   |
//|   2. SMMA 200 H4 (prix au-dessus = BUY, en-dessous = SELL)       |
//|                                                                    |
//| SIGNAUX TECHNIQUES (H1) - 6 signaux:                              |
//|   1. Cross EMA 21/55 H1                                           |
//|   2. MACD Histogram H1 (position > 0 ou < 0)                      |
//|   3. ADX Trending (> 25)                                          |
//|   4. Higher Highs / Lower Lows                                    |
//|   5. RSI H1 Momentum (> 50 ou < 50)                               |
//|   6. RSI H1 Bounce (oversold/overbought)                          |
//|                                                                    |
//| RISK MANAGEMENT:                                                   |
//|   - Risque: 0.50% du capital                                      |
//|   - RR: 1:3 (SL 0.70% / TP 2.10%)                                |
//|   - Perte max journalière: 1.5% (STOP NOUVEAUX TRADES)           |
//|   - Max 3 trades/jour                                             |
//|   - Durée max trade: 72H                                          |
//|   - Break Even à 1R                                               |
//+------------------------------------------------------------------+
#property copyright "Zeus Trading System - Corrected v3"
#property version   "3.00"
#property strict

#include <Trade\Trade.mqh>

//--- Input Parameters
input group "=== RISK MANAGEMENT ==="
input double InpRiskPerTrade = 0.50;           // Risque par trade (%)
input double InpMaxDailyLoss = 1.50;           // Perte journalière max (%) - STOP NOUVEAUX TRADES
input int    InpMaxTradesPerDay = 3;           // Max trades par jour
input int    InpMaxPositions = 10;             // Positions simultanées max

input group "=== SL/TP FIXE - RR 1:3 ==="
input double InpSL_Percent = 0.70;             // Stop Loss (% du prix) - 1R
input double InpTP_Percent = 2.10;             // Take Profit (% du prix) - 3R (1:3 RR)
input double InpBE_TriggerR = 1.0;             // Break Even à XR (1.0 = 1R)

input group "=== DURÉE MAXIMUM TRADE ==="
input int    InpMaxTradeHours = 72;            // Durée max trade (heures)

input group "=== TRADING HOURS ==="
input int    InpTradingStartHour = 6;          // Heure début trading
input int    InpTradingEndHour = 22;           // Heure fin trading

input group "=== FILTRES H4 ==="
input int    InpRSI_H4_Period = 14;            // Période RSI H4
input int    InpRSI_H4_Overbought = 80;        // RSI H4 surachat (FILTRE)
input int    InpRSI_H4_Oversold = 25;          // RSI H4 survente (FILTRE)
input int    InpSMMA_H4_Period = 200;          // Période SMMA H4

input group "=== SIGNAUX H1 ==="
input int    InpEMA_Fast = 21;                 // EMA rapide H1
input int    InpEMA_Slow = 55;                 // EMA lente H1
input int    InpMACD_Fast = 12;                // MACD Fast EMA
input int    InpMACD_Slow = 26;                // MACD Slow EMA
input int    InpMACD_Signal = 9;               // MACD Signal
input int    InpRSI_H1_Period = 14;            // Période RSI H1
input int    InpRSI_H1_Overbought = 70;        // RSI H1 surachat
input int    InpRSI_H1_Oversold = 30;          // RSI H1 survente
input int    InpADX_Period = 14;               // Période ADX
input double InpADX_TrendingThreshold = 25.0;  // ADX > 25 = Trending

input group "=== CORRELATION ==="
input double InpMaxCorrelation = 0.85;         // Corrélation max autorisée
input int    InpCorrelationPeriod = 100;       // Période calcul corrélation

input group "=== SCORING ==="
input int    InpMinSignalsRequired = 4;        // Signaux minimum requis (sur 6)

input group "=== GENERAL SETTINGS ==="
input int    InpMagicNumber = 789456;          // Magic Number
input string InpTradeComment = "Zeus_v3";      // Commentaire trades
input bool   InpVerboseLogs = true;            // Logs détaillés

//--- Currency pairs
string g_Symbols[] = {"EURUSD", "GBPUSD", "USDJPY", "USDCHF", "AUDUSD", "NZDUSD", "USDCAD"};

//--- Global variables
CTrade g_Trade;
datetime g_LastBarTime = 0;
datetime g_DailyResetTime = 0;
int g_DailyTradesCount = 0;
double g_DailyPnL = 0.0;
double g_DailyStartBalance = 0.0;

//--- Indicator handles H4 (FILTRES)
int g_RSI_H4_Handle[];
int g_SMMA_H4_Handle[];

//--- Indicator handles H1 (SIGNAUX)
int g_EMA_Fast_Handle[];
int g_EMA_Slow_Handle[];
int g_MACD_Handle[];
int g_RSI_H1_Handle[];
int g_ADX_Handle[];

//--- Position tracking
enum ENUM_MARKET_BIAS {
    BIAS_NONE,
    BIAS_BULLISH,
    BIAS_BEARISH
};

ENUM_MARKET_BIAS g_CurrentBias = BIAS_NONE;

//+------------------------------------------------------------------+
//| Expert initialization function                                     |
//+------------------------------------------------------------------+
int OnInit()
{
    Print("===== ZEUS CORRECTED V3 - INITIALISATION =====");

    g_Trade.SetExpertMagicNumber(InpMagicNumber);
    g_Trade.SetDeviationInPoints(20);
    g_Trade.SetTypeFilling(ORDER_FILLING_FOK);
    g_Trade.SetAsyncMode(false);

    int symbolCount = ArraySize(g_Symbols);

    //--- Initialize arrays
    ArrayResize(g_RSI_H4_Handle, symbolCount);
    ArrayResize(g_SMMA_H4_Handle, symbolCount);
    ArrayResize(g_EMA_Fast_Handle, symbolCount);
    ArrayResize(g_EMA_Slow_Handle, symbolCount);
    ArrayResize(g_MACD_Handle, symbolCount);
    ArrayResize(g_RSI_H1_Handle, symbolCount);
    ArrayResize(g_ADX_Handle, symbolCount);

    //--- Create indicator handles for all symbols
    for(int i = 0; i < symbolCount; i++)
    {
        // FILTRES H4
        g_RSI_H4_Handle[i] = iRSI(g_Symbols[i], PERIOD_H4, InpRSI_H4_Period, PRICE_CLOSE);
        g_SMMA_H4_Handle[i] = iMA(g_Symbols[i], PERIOD_H4, InpSMMA_H4_Period, 0, MODE_SMMA, PRICE_CLOSE);

        // SIGNAUX H1
        g_EMA_Fast_Handle[i] = iMA(g_Symbols[i], PERIOD_H1, InpEMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
        g_EMA_Slow_Handle[i] = iMA(g_Symbols[i], PERIOD_H1, InpEMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
        g_MACD_Handle[i] = iMACD(g_Symbols[i], PERIOD_H1, InpMACD_Fast, InpMACD_Slow, InpMACD_Signal, PRICE_CLOSE);
        g_RSI_H1_Handle[i] = iRSI(g_Symbols[i], PERIOD_H1, InpRSI_H1_Period, PRICE_CLOSE);
        g_ADX_Handle[i] = iADX(g_Symbols[i], PERIOD_H1, InpADX_Period);

        bool handlesOK = (g_RSI_H4_Handle[i] != INVALID_HANDLE && g_SMMA_H4_Handle[i] != INVALID_HANDLE &&
                          g_EMA_Fast_Handle[i] != INVALID_HANDLE && g_EMA_Slow_Handle[i] != INVALID_HANDLE &&
                          g_MACD_Handle[i] != INVALID_HANDLE && g_RSI_H1_Handle[i] != INVALID_HANDLE &&
                          g_ADX_Handle[i] != INVALID_HANDLE);

        if(!handlesOK)
        {
            Print("ERREUR: Impossible de créer les indicateurs pour ", g_Symbols[i]);
            return INIT_FAILED;
        }
    }

    //--- Initialize balance tracking
    g_DailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    g_DailyResetTime = TimeCurrent();
    g_DailyTradesCount = 0;

    Print("Initialisation réussie - Balance: ", g_DailyStartBalance);
    Print("Paires surveillées: ", symbolCount);
    Print("SL: ", InpSL_Percent, "% | TP: ", InpTP_Percent, "% (RR 1:3) | BE: ", InpBE_TriggerR, "R");
    Print("Max trades/jour: ", InpMaxTradesPerDay, " | Durée max: ", InpMaxTradeHours, "H");
    Print("Signaux requis: ", InpMinSignalsRequired, "/6");

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
        if(g_RSI_H4_Handle[i] != INVALID_HANDLE) IndicatorRelease(g_RSI_H4_Handle[i]);
        if(g_SMMA_H4_Handle[i] != INVALID_HANDLE) IndicatorRelease(g_SMMA_H4_Handle[i]);
        if(g_EMA_Fast_Handle[i] != INVALID_HANDLE) IndicatorRelease(g_EMA_Fast_Handle[i]);
        if(g_EMA_Slow_Handle[i] != INVALID_HANDLE) IndicatorRelease(g_EMA_Slow_Handle[i]);
        if(g_MACD_Handle[i] != INVALID_HANDLE) IndicatorRelease(g_MACD_Handle[i]);
        if(g_RSI_H1_Handle[i] != INVALID_HANDLE) IndicatorRelease(g_RSI_H1_Handle[i]);
        if(g_ADX_Handle[i] != INVALID_HANDLE) IndicatorRelease(g_ADX_Handle[i]);
    }

    Print("Zeus Corrected v3 déchargé - Raison: ", reason);
}

//+------------------------------------------------------------------+
//| Expert tick function                                              |
//+------------------------------------------------------------------+
void OnTick()
{
    //--- Check new bar (H1)
    datetime currentBarTime = iTime(_Symbol, PERIOD_H1, 0);
    if(currentBarTime == g_LastBarTime) return;
    g_LastBarTime = currentBarTime;

    //--- Daily reset
    CheckDailyReset();

    //--- Update Break Even for all positions
    UpdateAllBreakEven();

    //--- Close positions older than 72H
    CloseOldPositions();

    //--- Check daily loss limit (STOP NOUVEAUX TRADES)
    if(!CheckDailyLossLimit())
    {
        if(InpVerboseLogs) Print("DAILY LOSS LIMIT ATTEINT - Pas de nouveaux trades aujourd'hui");
        return;
    }

    //--- Check max trades per day
    if(g_DailyTradesCount >= InpMaxTradesPerDay)
    {
        if(InpVerboseLogs) Print("MAX TRADES/JOUR ATTEINT (", InpMaxTradesPerDay, ") - Pas de nouveaux trades");
        return;
    }

    //--- Check max positions
    if(!CheckMaxPositions())
    {
        if(InpVerboseLogs) Print("MAX POSITIONS ATTEINT - Pas de nouveaux trades");
        return;
    }

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
    //--- FILTRES ÉLIMINATOIRES

    //--- Filtre 1: Pas de position déjà ouverte
    if(HasOpenPosition(symbol)) return;

    //--- Filtre 2: Vérifier heures de trading
    MqlDateTime dt;
    TimeToStruct(TimeCurrent(), dt);
    if(dt.hour < InpTradingStartHour || dt.hour >= InpTradingEndHour)
        return;

    //--- Filtre 3: Corrélation
    if(!CheckCorrelationExposure(symbol))
        return;

    //--- FILTRE 4: RSI H4 (80 surachat / 25 survente)
    double rsi_h4[];
    ArraySetAsSeries(rsi_h4, true);
    if(CopyBuffer(g_RSI_H4_Handle[symbolIndex], 0, 0, 2, rsi_h4) < 2) return;

    double currentRSI_H4 = rsi_h4[1];

    // Si RSI H4 en zone extrême, on SKIP (filtre éliminatoire)
    if(currentRSI_H4 > InpRSI_H4_Overbought || currentRSI_H4 < InpRSI_H4_Oversold)
    {
        if(InpVerboseLogs)
            Print("FILTRE RSI H4: ", symbol, " - RSI H4 = ", currentRSI_H4, " (Zone extrême) - SKIP");
        return;
    }

    //--- FILTRE 5: SMMA 200 H4 (direction trend)
    double smma_h4[];
    ArraySetAsSeries(smma_h4, true);
    if(CopyBuffer(g_SMMA_H4_Handle[symbolIndex], 0, 0, 2, smma_h4) < 2) return;

    double currentSMMA_H4 = smma_h4[1];
    double close_h4 = iClose(symbol, PERIOD_H4, 1);

    bool smma_bullish = (close_h4 > currentSMMA_H4);
    bool smma_bearish = (close_h4 < currentSMMA_H4);

    //--- Get H1 market data
    double close = iClose(symbol, PERIOD_H1, 1);
    double high = iHigh(symbol, PERIOD_H1, 1);
    double low = iLow(symbol, PERIOD_H1, 1);

    //--- Get H1 indicator values
    double ema_fast[], ema_slow[], macd_main[], rsi_h1[], adx[];
    ArraySetAsSeries(ema_fast, true);
    ArraySetAsSeries(ema_slow, true);
    ArraySetAsSeries(macd_main, true);
    ArraySetAsSeries(rsi_h1, true);
    ArraySetAsSeries(adx, true);

    if(CopyBuffer(g_EMA_Fast_Handle[symbolIndex], 0, 0, 3, ema_fast) < 3) return;
    if(CopyBuffer(g_EMA_Slow_Handle[symbolIndex], 0, 0, 3, ema_slow) < 3) return;
    if(CopyBuffer(g_MACD_Handle[symbolIndex], 0, 0, 3, macd_main) < 3) return;
    if(CopyBuffer(g_RSI_H1_Handle[symbolIndex], 0, 0, 3, rsi_h1) < 3) return;
    if(CopyBuffer(g_ADX_Handle[symbolIndex], 0, 0, 2, adx) < 2) return;

    double currentEMA_Fast = ema_fast[1];
    double prevEMA_Fast = ema_fast[2];
    double currentEMA_Slow = ema_slow[1];
    double prevEMA_Slow = ema_slow[2];
    double currentMACD = macd_main[1];
    double currentRSI_H1 = rsi_h1[1];
    double prevRSI_H1 = rsi_h1[2];
    double currentADX = adx[1];

    //--- SCORING 6 SIGNAUX TECHNIQUES (H1)
    int signalsTotal = 6;
    int signalsBuy = 0, signalsSell = 0;

    //--- Signal 1: Cross EMA 21/55 H1
    bool ema_bullish_cross = (prevEMA_Fast < prevEMA_Slow && currentEMA_Fast > currentEMA_Slow);
    bool ema_bearish_cross = (prevEMA_Fast > prevEMA_Slow && currentEMA_Fast < currentEMA_Slow);

    if(ema_bullish_cross) signalsBuy++;
    else if(ema_bearish_cross) signalsSell++;

    //--- Signal 2: MACD Histogram H1 (position > 0 ou < 0)
    if(currentMACD > 0) signalsBuy++;
    else if(currentMACD < 0) signalsSell++;

    //--- Signal 3: ADX Trending (> 25)
    if(currentADX > InpADX_TrendingThreshold)
    {
        if(close > currentEMA_Slow) signalsBuy++;
        else if(close < currentEMA_Slow) signalsSell++;
    }

    //--- Signal 4: Higher Highs / Lower Lows
    double prevHigh = iHigh(symbol, PERIOD_H1, 2);
    double prevLow = iLow(symbol, PERIOD_H1, 2);

    if(high > prevHigh && low > prevLow) signalsBuy++;
    else if(high < prevHigh && low < prevLow) signalsSell++;

    //--- Signal 5: RSI H1 Momentum (> 50 ou < 50)
    if(currentRSI_H1 > 50 && currentRSI_H1 < InpRSI_H1_Overbought) signalsBuy++;
    else if(currentRSI_H1 < 50 && currentRSI_H1 > InpRSI_H1_Oversold) signalsSell++;

    //--- Signal 6: RSI H1 Bounce (oversold/overbought)
    if(prevRSI_H1 < InpRSI_H1_Oversold && currentRSI_H1 > InpRSI_H1_Oversold) signalsBuy++;
    else if(prevRSI_H1 > InpRSI_H1_Overbought && currentRSI_H1 < InpRSI_H1_Overbought) signalsSell++;

    //--- DÉCISION: Buy ou Sell selon scoring + FILTRE SMMA H4
    bool takeBuy = (signalsBuy >= InpMinSignalsRequired && smma_bullish);
    bool takeSell = (signalsSell >= InpMinSignalsRequired && smma_bearish);

    //--- LOGIQUE ANTI-TRADES OPPOSÉS
    if(g_CurrentBias == BIAS_BULLISH && takeSell)
    {
        if(InpVerboseLogs) Print("BIAS BULLISH actif - Trade SELL refusé pour ", symbol);
        return;
    }
    if(g_CurrentBias == BIAS_BEARISH && takeBuy)
    {
        if(InpVerboseLogs) Print("BIAS BEARISH actif - Trade BUY refusé pour ", symbol);
        return;
    }

    //--- EXÉCUTION
    if(takeBuy)
    {
        if(InpVerboseLogs)
        {
            Print(">>> SIGNAL BUY: ", symbol, " | Signaux: ", signalsBuy, "/", signalsTotal,
                  " | RSI H4: ", currentRSI_H4, " | SMMA H4: BULLISH");
        }
        ExecuteTrade(symbol, ORDER_TYPE_BUY, close);
        g_CurrentBias = BIAS_BULLISH;
        g_DailyTradesCount++;
    }
    else if(takeSell)
    {
        if(InpVerboseLogs)
        {
            Print(">>> SIGNAL SELL: ", symbol, " | Signaux: ", signalsSell, "/", signalsTotal,
                  " | RSI H4: ", currentRSI_H4, " | SMMA H4: BEARISH");
        }
        ExecuteTrade(symbol, ORDER_TYPE_SELL, close);
        g_CurrentBias = BIAS_BEARISH;
        g_DailyTradesCount++;
    }
}

//+------------------------------------------------------------------+
//| Execute Trade with Fixed SL/TP                                   |
//+------------------------------------------------------------------+
void ExecuteTrade(string symbol, ENUM_ORDER_TYPE orderType, double price)
{
    //--- Calculate lot size based on risk
    double slDistance = price * (InpSL_Percent / 100.0);
    double lotSize = CalculateLotSize(symbol, slDistance);

    if(lotSize <= 0)
    {
        if(InpVerboseLogs) Print("Lot size invalide pour ", symbol);
        return;
    }

    //--- Calculate SL and TP (FIXED %)
    double sl, tp;

    if(orderType == ORDER_TYPE_BUY)
    {
        sl = price - (price * InpSL_Percent / 100.0);  // -0.70%
        tp = price + (price * InpTP_Percent / 100.0);  // +2.10% (RR 1:3)
    }
    else // SELL
    {
        sl = price + (price * InpSL_Percent / 100.0);  // +0.70%
        tp = price - (price * InpTP_Percent / 100.0);  // -2.10% (RR 1:3)
    }

    //--- Normalize prices
    int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
    sl = NormalizeDouble(sl, digits);
    tp = NormalizeDouble(tp, digits);

    //--- Execute order
    bool result = false;
    if(orderType == ORDER_TYPE_BUY)
        result = g_Trade.Buy(lotSize, symbol, 0, sl, tp, InpTradeComment);
    else
        result = g_Trade.Sell(lotSize, symbol, 0, sl, tp, InpTradeComment);

    if(result)
    {
        Print(">>> ORDRE OUVERT: ", symbol, " | Type: ", EnumToString(orderType),
              " | Lot: ", lotSize, " | SL: ", sl, " | TP: ", tp, " (RR 1:3)");
    }
    else
    {
        Print("ERREUR: Impossible d'ouvrir ordre pour ", symbol, " - Code: ", GetLastError());
        g_DailyTradesCount--; // Revert counter if failed
    }
}

//+------------------------------------------------------------------+
//| Calculate lot size based on risk                                 |
//+------------------------------------------------------------------+
double CalculateLotSize(string symbol, double slDistance)
{
    double balance = AccountInfoDouble(ACCOUNT_BALANCE);
    double riskAmount = balance * (InpRiskPerTrade / 100.0);

    double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
    double minLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
    double maxLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
    double lotStep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

    if(tickValue == 0 || tickSize == 0 || slDistance == 0) return 0;

    double lotSize = (riskAmount * tickSize) / (slDistance * tickValue);
    lotSize = MathFloor(lotSize / lotStep) * lotStep;
    lotSize = MathMax(minLot, MathMin(maxLot, lotSize));

    return lotSize;
}

//+------------------------------------------------------------------+
//| Update Break Even for all positions                              |
//+------------------------------------------------------------------+
void UpdateAllBreakEven()
{
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(ticket <= 0) continue;
        if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

        string symbol = PositionGetString(POSITION_SYMBOL);
        double entryPrice = PositionGetDouble(POSITION_PRICE_OPEN);
        double currentSL = PositionGetDouble(POSITION_SL);
        ENUM_POSITION_TYPE posType = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

        //--- Calculate 1R profit (BE trigger)
        double rDistance = entryPrice * (InpSL_Percent / 100.0);
        double beProfit = rDistance * InpBE_TriggerR;

        double currentPrice = (posType == POSITION_TYPE_BUY) ?
                              SymbolInfoDouble(symbol, SYMBOL_BID) :
                              SymbolInfoDouble(symbol, SYMBOL_ASK);

        int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
        bool shouldMoveToBE = false;
        double newSL = 0;

        if(posType == POSITION_TYPE_BUY)
        {
            if(currentPrice >= entryPrice + beProfit && currentSL < entryPrice)
            {
                shouldMoveToBE = true;
                newSL = NormalizeDouble(entryPrice, digits);
            }
        }
        else // SELL
        {
            if(currentPrice <= entryPrice - beProfit && (currentSL > entryPrice || currentSL == 0))
            {
                shouldMoveToBE = true;
                newSL = NormalizeDouble(entryPrice, digits);
            }
        }

        if(shouldMoveToBE)
        {
            if(g_Trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP)))
            {
                Print(">>> BREAK EVEN activé: ", symbol, " | Ticket: ", ticket, " | SL: ", newSL);
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Close positions older than 72H                                   |
//+------------------------------------------------------------------+
void CloseOldPositions()
{
    datetime currentTime = TimeCurrent();

    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(ticket <= 0) continue;
        if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

        datetime openTime = (datetime)PositionGetInteger(POSITION_TIME);
        int hoursOpen = (int)((currentTime - openTime) / 3600);

        if(hoursOpen >= InpMaxTradeHours)
        {
            string symbol = PositionGetString(POSITION_SYMBOL);

            if(g_Trade.PositionClose(ticket))
            {
                Print(">>> POSITION FERMÉE (72H MAX): ", symbol, " | Ticket: ", ticket,
                      " | Durée: ", hoursOpen, "H");
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Check correlation exposure                                       |
//+------------------------------------------------------------------+
bool CheckCorrelationExposure(string symbol)
{
    for(int i = 0; i < PositionsTotal(); i++)
    {
        if(PositionGetTicket(i) <= 0) continue;
        if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;

        string posSymbol = PositionGetString(POSITION_SYMBOL);
        if(posSymbol == symbol) continue;

        double correlation = CalculateCorrelation(symbol, posSymbol, InpCorrelationPeriod, PERIOD_H1);

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
//| Calculate correlation between two symbols                        |
//+------------------------------------------------------------------+
double CalculateCorrelation(string symbol1, string symbol2, int period, ENUM_TIMEFRAMES tf)
{
    double close1[], close2[];
    ArraySetAsSeries(close1, true);
    ArraySetAsSeries(close2, true);

    if(CopyClose(symbol1, tf, 0, period, close1) < period) return 0.0;
    if(CopyClose(symbol2, tf, 0, period, close2) < period) return 0.0;

    double mean1 = 0, mean2 = 0;
    for(int i = 0; i < period; i++)
    {
        mean1 += close1[i];
        mean2 += close2[i];
    }
    mean1 /= period;
    mean2 /= period;

    double sum_xy = 0, sum_x2 = 0, sum_y2 = 0;
    for(int i = 0; i < period; i++)
    {
        double dx = close1[i] - mean1;
        double dy = close2[i] - mean2;
        sum_xy += dx * dy;
        sum_x2 += dx * dx;
        sum_y2 += dy * dy;
    }

    double denominator = MathSqrt(sum_x2 * sum_y2);
    if(denominator == 0) return 0.0;

    return sum_xy / denominator;
}

//+------------------------------------------------------------------+
//| Check if position exists for symbol                              |
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
//| Check max positions                                              |
//+------------------------------------------------------------------+
bool CheckMaxPositions()
{
    int openPositions = 0;
    for(int i = 0; i < PositionsTotal(); i++)
    {
        if(PositionGetTicket(i) > 0 && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
            openPositions++;
    }

    return (openPositions < InpMaxPositions);
}

//+------------------------------------------------------------------+
//| Check daily loss limit                                           |
//+------------------------------------------------------------------+
bool CheckDailyLossLimit()
{
    double dailyLossPercent = (g_DailyPnL / g_DailyStartBalance) * 100.0;

    if(dailyLossPercent <= -InpMaxDailyLoss) // -1.5%
    {
        return false; // STOP NOUVEAUX TRADES
    }

    return true;
}

//+------------------------------------------------------------------+
//| Check daily reset                                                |
//+------------------------------------------------------------------+
void CheckDailyReset()
{
    MqlDateTime dtCurrent, dtLastReset;
    TimeToStruct(TimeCurrent(), dtCurrent);
    TimeToStruct(g_DailyResetTime, dtLastReset);

    if(dtCurrent.day != dtLastReset.day)
    {
        //--- New day: reset counters
        g_DailyStartBalance = AccountInfoDouble(ACCOUNT_BALANCE);
        g_DailyPnL = 0.0;
        g_DailyResetTime = TimeCurrent();
        g_DailyTradesCount = 0;
        g_CurrentBias = BIAS_NONE;

        if(InpVerboseLogs)
        {
            Print("===== NOUVEAU JOUR - Reset =====");
            Print("Balance de départ: ", g_DailyStartBalance);
        }
    }

    //--- Update daily P&L
    double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
    g_DailyPnL = currentBalance - g_DailyStartBalance;
}
