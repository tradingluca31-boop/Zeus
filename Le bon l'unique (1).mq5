//+------------------------------------------------------------------+
//|                                   Poseidon_London_1H_fixedRisk   |
//|  H1 – Entrées 7:00-14:00 (serveur)                               |
//|  Signal: EMA21/55 OU MACD(SMA 20,45,15)                          |
//|  Max 2 trades/jour, SL 0.25%, TP +500$                           |
//|  BE (0$) dès profit >= 300$ OU move >= 3R                        |
//|  Risque FIXE = InpRiskPercent (pas de palier / pas de séries)    |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>

CTrade Trade;

//======================== Inputs utilisateur ========================
input long     InpMagic                = 20250811;
input bool     InpAllowBuys            = true;
input bool     InpAllowSells           = true;

// --- Choix des signaux ---
enum SignalMode { EMA_OR_MACD=0, EMA_ONLY=1, MACD_ONLY=2 };
input SignalMode InpSignalMode         = EMA_OR_MACD; // "OU" par défaut
input bool     InpUseEMA_Cross         = true;        // EMA21/55 croisement
input bool     InpUseMACD              = true;        // MACD SMA 20/45/15

// --- MACD SMA config ---
input int      InpMACD_Fast            = 20;          // SMA rapide
input int      InpMACD_Slow            = 45;          // SMA lente
input int      InpMACD_Signal          = 15;          // SMA du MACD

// --- Risque / gestion (en %) ---
input double InpRiskPercent        = 1.0;   // % de la BALANCE risqué par trade
// [ADDED] Poseidon 03/09/2025 Option A — réduction du risque après série de pertes
input bool   UseLossStreakReduction = true;   // ON/OFF
input int    LossStreakTrigger      = 7;      // Value=7 / Start=3 / Step=1 / Stop=15
input double LossStreakFactor       = 0.50;   // Value=0.50 / Start=0.20 / Step=0.10 / Stop=1.00

// [ADDED] Poseidon 03/09/2025 Option A — RISQUE EN MONTANT FIXE (devise du compte)
input bool   UseFixedRiskMoney = true;   // Utiliser un montant fixe (€) au lieu du %
input double FixedRiskMoney     = 100.0; // Montant risqué par trade (ex: 100€)
input double ReducedRiskMoney   = 50.0;  // Montant risqué sous série de pertes (ex: 50€)

input double InpSL_PercentOfPrice  = 0.25;  // SL = % du prix d'entrée (ex: 0.25 => 0.25%)
input double InpTP_PercentOfPrice  = 1.25;  // TP = % du prix d'entrée
input double InpBE_TriggerPercent  = 0.70;  // Passer BE quand le prix a évolué de +0.70% depuis l'entrée
input int    InpMaxTradesPerDay    = 2;


// --- Fenêtre d'ouverture ---
input ENUM_TIMEFRAMES InpSignalTF      = PERIOD_H1;   // TF signaux (H1)
input int      InpSessionStartHour     = 6;           // Ouverture 6h (heure serveur)
input int      InpSessionEndHour       = 15;          // Fermeture 15h (pas de nouvelles entrées après)
input int      InpSlippagePoints       = 20;
input bool     InpVerboseLogs          = false;
// [ADDED] === SMMA50 + Score conditions (optimisables) ===
input bool InpUseSMMA50Trend    = true;             // Filtre tendance SMMA50
input int  InpSMMA_Period       = 50;               // Période SMMA (Value=50 / Start=20 / Step=5 / Stop=200)
input ENUM_TIMEFRAMES InpSMMA_TF = PERIOD_H4;       // UT SMMA (H4)
input int  InpMinConditions     = 3;                // Conditions minimales requises (Value=3 / Start=2 / Step=1 / Stop=4)

// [ADDED] === RSI Filter ===
input bool InpUseRSI = true;                                // Utiliser filtre RSI
input ENUM_TIMEFRAMES InpRSITF = PERIOD_H4;                 // TimeFrame RSI
input int InpRSIPeriod = 14;                                // Période RSI (Value=14 / Start=7 / Step=1 / Stop=40)
input int InpRSIOverbought = 70;                            // Seuil surachat RSI (Value=70 / Start=60 / Step=1 / Stop=85)
input int InpRSIOversold = 25;                              // Seuil survente RSI (Value=25 / Start=10 / Step=1 / Stop=40)
input bool InpRSIBlockEqual = true;                         // Bloquer si == aux seuils (>=/<= vs >/<)


//=== Month Filter Inputs START ===========================================
input bool InpTrade_Janvier   = false;  // Trader en Janvier
input bool InpTrade_Fevrier   = false;  // Trader en Fevrier
input bool InpTrade_Mars      = false;  // Trader en Mars
input bool InpTrade_Avril     = true;   // Trader en Avril
input bool InpTrade_Mai       = true;   // Trader en Mai
input bool InpTrade_Juin      = true;   // Trader en Juin
input bool InpTrade_Juillet   = true;   // Trader en Juillet
input bool InpTrade_Aout      = true;   // Trader en Aout
input bool InpTrade_Septembre = true;   // Trader en Septembre
input bool InpTrade_Octobre   = true;   // Trader en Octobre
input bool InpTrade_Novembre  = true;   // Trader en Novembre
input bool InpTrade_Decembre  = true;   // Trader en Decembre
//=== Month Filter Inputs END =============================================


//======================== Variables ========================
datetime lastBarTime=0;
string   sym; int dig; double pt;
int tradedDay=-1, tradesCountToday=0;
int gLossStreak = 0;   // [ADDED] Compteur pertes consécutives — Poseidon 03/09/2025 Option A

// Handles EMA/MAs pour MACD SMA
int hEMA21=-1, hEMA55=-1;
int hSMAfast=-1, hSMAslow=-1;

int hSMMA50 = -1;   // [ADDED] Handle SMMA50

// [ADDED] RSI variables
int rsi_handle = INVALID_HANDLE;
double rsi_val = EMPTY_VALUE;
datetime rsi_last_bar_time = 0;
//======================== Utils Temps ======================
bool IsNewBar(){ datetime ct=iTime(sym, InpSignalTF, 0); if(ct!=lastBarTime){lastBarTime=ct; return true;} return false; }

void ResetDayIfNeeded(){ MqlDateTime t; TimeToStruct(TimeCurrent(), t); if(tradedDay!=t.day_of_year){ tradedDay=t.day_of_year; tradesCountToday=0; } }
bool CanOpenToday(){ ResetDayIfNeeded(); return tradesCountToday<InpMaxTradesPerDay; }
void MarkTradeOpened(){ ResetDayIfNeeded(); tradesCountToday++; }

bool InEntryWindow()
{
   MqlDateTime t; TimeToStruct(TimeCurrent(), t);
   if(InpSessionStartHour<=InpSessionEndHour)
      return (t.hour>=InpSessionStartHour && t.hour<InpSessionEndHour);
   return (t.hour>=InpSessionStartHour || t.hour<InpSessionEndHour);
}

//======================== Indicateurs ======================
bool GetEMAs(double &e21_1,double &e55_1,double &e21_2,double &e55_2)
{
   double b21[],b55[]; ArraySetAsSeries(b21,true); ArraySetAsSeries(b55,true);
   if(CopyBuffer(hEMA21,0,1,2,b21)<2) return false;
   if(CopyBuffer(hEMA55,0,1,2,b55)<2) return false;
   e21_1=b21[0]; e21_2=b21[1]; e55_1=b55[0]; e55_2=b55[1];
   return true;
}

// Calcule MACD SMA(20,45) et son Signal SMA(15) via SMA on-price + SMA sur MACD
bool GetMACD_SMA(double &macd_1,double &sig_1,double &macd_2,double &sig_2)
{
   int need = MathMax(MathMax(InpMACD_Fast, InpMACD_Slow), InpMACD_Signal) + 5;
   double fast[], slow[];
   ArraySetAsSeries(fast,true); ArraySetAsSeries(slow,true);
   if(CopyBuffer(hSMAfast,0,1,need,fast) < need) return false;
   if(CopyBuffer(hSMAslow,0,1,need,slow) < need) return false;

   double macdArr[]; ArrayResize(macdArr, need);
   for(int i=0;i<need;i++) macdArr[i] = fast[i] - slow[i];

   double sigArr[]; ArrayResize(sigArr, need);
   int p = InpMACD_Signal;
   double acc=0;
   for(int i=0;i<need;i++)
   {
      acc += macdArr[i];
      if(i>=p) acc -= macdArr[i-p];
      if(i>=p-1) sigArr[i] = acc / p; else sigArr[i] = macdArr[i];
   }

   macd_1 = macdArr[0];
   sig_1  = sigArr[0];
   macd_2 = macdArr[1];
   sig_2  = sigArr[1];
   return true;
}

//------------------------ Signaux ----------------------
void ComputeSignals(bool &buySig,bool &sellSig)
{
   buySig=false; sellSig=false;

   bool emaBuy=false, emaSell=false;
   if(InpUseEMA_Cross && (InpSignalMode==EMA_ONLY || InpSignalMode==EMA_OR_MACD))
   {
      double e21_1,e55_1,e21_2,e55_2;
      if(GetEMAs(e21_1,e55_1,e21_2,e55_2))
      {
         emaBuy  = (e21_2<=e55_2 && e21_1>e55_1);
         emaSell = (e21_2>=e55_2 && e21_1<e55_1);
      }
   }

   bool macdBuy=false, macdSell=false;
   if(InpUseMACD && (InpSignalMode==MACD_ONLY || InpSignalMode==EMA_OR_MACD))
   {
      double m1,s1,m2,s2;
      if(GetMACD_SMA(m1,s1,m2,s2))
      {
         macdBuy  = (m2<=s2 && m1>s1);   // croisement haussier
         macdSell = (m2>=s2 && m1<s1);   // croisement baissier
      }
   }

   if(InpSignalMode==EMA_ONLY)      { buySig=emaBuy;  sellSig=emaSell; }
   else if(InpSignalMode==MACD_ONLY){ buySig=macdBuy; sellSig=macdSell; }
   else /* EMA_OR_MACD */           {
      buySig  = (emaBuy  || macdBuy);
      sellSig = (emaSell || macdSell);
   }
}
// [ADDED] ---- Helpers SMMA/EMA/MACD pour scoring 4 conditions ----

bool GetSMMA50(double &out_smma)
{
   if(!InpUseSMMA50Trend) return false;
   if(hSMMA50==INVALID_HANDLE) return false;
   double b[]; ArraySetAsSeries(b,true);
   if(CopyBuffer(hSMMA50,0,0,1,b)<1) return false;
   out_smma = b[0];
   return true;
}

// +1 (buy) / -1 (sell) / 0 neutre
int TrendDir_SMMA50()
{
   if(!InpUseSMMA50Trend) return 0;
   double smma=0.0; if(!GetSMMA50(smma)) return 0;
   double bid=SymbolInfoDouble(sym,SYMBOL_BID), ask=SymbolInfoDouble(sym,SYMBOL_ASK);
   double px=(bid+ask)*0.5;
   if(px>smma) return +1;
   if(px<smma) return -1;
   return 0;
}

// EMA21/55 (croisement)
bool GetEMACrossSignal(bool &buy,bool &sell)
{
   buy=false; sell=false;
   double e21_1,e55_1,e21_2,e55_2;
   if(!GetEMAs(e21_1,e55_1,e21_2,e55_2)) return false;
   buy  = (e21_2<=e55_2 && e21_1>e55_1);
   sell = (e21_2>=e55_2 && e21_1<e55_1);
   return true;
}

// MACD (SMA-based existant) — croisement des lignes
bool GetMACD_CrossSignal(bool &buy,bool &sell)
{
   buy=false; sell=false;
   double m1,s1,m2,s2;
   if(!GetMACD_SMA(m1,s1,m2,s2)) return false;
   buy  = (m2<=s2 && m1>s1);
   sell = (m2>=s2 && m1<s1);
   return true;
}

// MACD — histogramme (MAIN - SIGNAL)
bool GetMACD_HistSignal(bool &buy,bool &sell)
{
   buy=false; sell=false;
   double m1,s1,m2,s2;
   if(!GetMACD_SMA(m1,s1,m2,s2)) return false;
   double hist = (m1 - s1);
   buy  = (hist > 0.0);
   sell = (hist < 0.0);
   return true;
}


//======================== Prix/SL/TP ========================
void MakeSL_Init(int dir,double entry,double &sl)
{
   double p=InpSL_PercentOfPrice/100.0;
   if(dir>0) sl=entry*(1.0-p); else sl=entry*(1.0+p);
   sl=NormalizeDouble(sl,dig);
}

bool PriceForTargetProfit(int dir,double lots,double entry,double targetUSD,double &priceOut)
{
   // Recherche binaire +/- 3% autour de l'entrée
   double range = entry*0.03;
   double lo = (dir>0? entry : entry-range), hi=(dir>0? entry+range : entry);
   for(int i=0;i<50;i++){
      double mid=(lo+hi)*0.5;
      double pf=0.0; bool ok = (dir>0)? OrderCalcProfit(ORDER_TYPE_BUY,sym,lots,entry,mid,pf)
                                      : OrderCalcProfit(ORDER_TYPE_SELL,sym,lots,entry,mid,pf);
      if(!ok) return false;
      if(pf<targetUSD){ if(dir>0) lo=mid; else hi=mid; }
      else             { if(dir>0) hi=mid; else lo=mid; }
   }
   priceOut=NormalizeDouble((lo+hi)*0.5,dig);
   return true;
}

//======================== Sizing 1% FIXE ===================
double LossPerLotAtSL(int dir,double entry,double sl)
{
   double p=0.0; bool ok = (dir>0)? OrderCalcProfit(ORDER_TYPE_BUY,sym,1.0,entry,sl,p)
                                  : OrderCalcProfit(ORDER_TYPE_SELL,sym,1.0,entry,sl,p);
   if(ok) return MathAbs(p);
   double tv=SymbolInfoDouble(sym,SYMBOL_TRADE_TICK_VALUE);
   double ts=SymbolInfoDouble(sym,SYMBOL_TRADE_TICK_SIZE);
   double dist=MathAbs(entry-sl);
   if(tv>0 && ts>0) return (dist/ts)*tv;
   return 0.0;
}

double LotsFromRisk(int dir,double entry,double sl)
{
   double equity=AccountInfoDouble(ACCOUNT_EQUITY);
// [CHANGED] Poseidon 03/09/2025 Option A — risque en € fixe + réduction série
double riskMoney = equity*(InpRiskPercent/100.0); // fallback %
if(UseFixedRiskMoney)
   riskMoney = FixedRiskMoney;

if(UseLossStreakReduction)
{
   gLossStreak = CountConsecutiveLosses();
   if(gLossStreak >= LossStreakTrigger)
   {
      if(UseFixedRiskMoney) riskMoney = ReducedRiskMoney;
      else                  riskMoney *= LossStreakFactor;
   }
   if(InpVerboseLogs) PrintFormat("[LossStreak] count=%d, riskMoney=%.2f", gLossStreak, riskMoney);
}

double risk=riskMoney;
   double lossPerLot=LossPerLotAtSL(dir,entry,sl);
   if(lossPerLot<=0) return 0.0;
   double lots=risk/lossPerLot;
   double step=SymbolInfoDouble(sym,SYMBOL_VOLUME_STEP);
   double minL=SymbolInfoDouble(sym,SYMBOL_VOLUME_MIN);
   double maxL=SymbolInfoDouble(sym,SYMBOL_VOLUME_MAX);
   if(step<=0) step=0.01;
   lots=MathFloor(lots/step)*step;
   lots=MathMax(minL,MathMin(lots,maxL));
   if(InpVerboseLogs) PrintFormat("[Sizing FIX] equity=%.2f risk$=%.2f entry=%.2f sl=%.2f lossPerLot=%.2f lots=%.2f",
                                  equity, risk, entry, sl, lossPerLot, lots);
   return lots;
}

//======================== Ouverture ========================
void TryOpenTrade()
{
   if(!InEntryWindow()) return;
   if(!CanOpenToday()) return;
   
   // [ADDED] RSI Filter - bloque si conditions non respectées
   if(!IsRSIFilterOK()) return;

   // [CHANGED] Scoring 4 conditions (SMMA + EMA + MACD_hist + MACD_cross) + filtre SMMA directionnel
int scoreBuy=0, scoreSell=0;

// 1) SMMA50 H4 tendance
int tdir = TrendDir_SMMA50(); // +1/-1/0
if(InpUseSMMA50Trend){
   if(tdir>0) scoreBuy++;
   else if(tdir<0) scoreSell++;
   else return; // neutre -> pas d'entrée
}

// 2) EMA21/55 cross
bool emaB=false, emaS=false; GetEMACrossSignal(emaB, emaS);
if(emaB) scoreBuy++; if(emaS) scoreSell++;

// 3) MACD histogramme
bool mhB=false, mhS=false; GetMACD_HistSignal(mhB, mhS);
if(mhB) scoreBuy++; if(mhS) scoreSell++;

// 4) MACD croisement lignes
bool mcB=false, mcS=false; GetMACD_CrossSignal(mcB, mcS);
if(mcB) scoreBuy++; if(mcS) scoreSell++;

bool allowBuy  = (!InpUseSMMA50Trend || tdir>0);
bool allowSell = (!InpUseSMMA50Trend || tdir<0);

int dir=0;
if(scoreBuy  >= InpMinConditions && allowBuy  && InpAllowBuys)  dir=+1;
if(scoreSell >= InpMinConditions && allowSell && InpAllowSells && dir==0) dir=-1;
if(dir==0) return;

   double entry=(dir>0)? SymbolInfoDouble(sym,SYMBOL_ASK):SymbolInfoDouble(sym,SYMBOL_BID);
   double sl; MakeSL_Init(dir,entry,sl);
   double lots=LotsFromRisk(dir,entry,sl);
   if(lots<=0) return;

   // TP en % du prix d'entrée
double tpPrice = (dir>0 ? entry*(1.0 + InpTP_PercentOfPrice/100.0)
                        : entry*(1.0 - InpTP_PercentOfPrice/100.0));



   Trade.SetExpertMagicNumber(InpMagic);
   Trade.SetDeviationInPoints(InpSlippagePoints);
   string cmt="BASE";
   if(UseLossStreakReduction && gLossStreak >= LossStreakTrigger) cmt="RISK-REDUCED";   // [ADDED]
   bool ok=(dir>0)? Trade.Buy(lots,sym,entry,sl,tpPrice,cmt)
                  : Trade.Sell(lots,sym,entry,sl,tpPrice,cmt);
   if(ok) MarkTradeOpened();
}

//======================== Gestion BE =======================
double RPrice(const double entry){ return entry*(InpSL_PercentOfPrice/100.0); } // 1R = SL% d'entrée

void ManageBreakEvenPercent(const string symbol_)   // nom changé pour ne pas masquer une globale
{
   for(int i=PositionsTotal()-1; i>=0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket)) continue;         // sélection
      if(PositionGetString(POSITION_SYMBOL)!=symbol_) continue;          // filtre symbole

      long   type  = (long)PositionGetInteger(POSITION_TYPE);            // BUY/SELL
      double entry = PositionGetDouble (POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble (POSITION_SL);
      double tp    = PositionGetDouble (POSITION_TP);
      double price = (type==POSITION_TYPE_BUY)
                     ? SymbolInfoDouble(symbol_, SYMBOL_BID)
                     : SymbolInfoDouble(symbol_, SYMBOL_ASK);

      // Seuil BE : +0.70% depuis l'entrée OU 3R
      const double beTrigger = (type==POSITION_TYPE_BUY)
                               ? entry*(1.0 + InpBE_TriggerPercent/100.0)
                               : entry*(1.0 - InpBE_TriggerPercent/100.0);
      const bool condPercent = (type==POSITION_TYPE_BUY) ? (price>=beTrigger) : (price<=beTrigger);

      const double R    = MathAbs(entry - sl);              // 1R en prix
      const double move = MathAbs(price - entry);
      const bool   cond3R = (R>0.0 && move >= 3.0*R);

      if(condPercent || cond3R)
      {
         const int    d       = (int)SymbolInfoInteger(symbol_, SYMBOL_DIGITS);
         const double ptLocal = SymbolInfoDouble(symbol_, SYMBOL_POINT);  // <— nom différent

         double targetSL = NormalizeDouble(entry, d);       // BE = SL à l'entrée
         bool need = (type==POSITION_TYPE_BUY)  ? (sl < targetSL - 10*ptLocal)
                                                : (sl > targetSL + 10*ptLocal);

         if(need){
            Trade.PositionModify(symbol_, targetSL, tp);
            // log utile
            PrintFormat("[BE] %s entry=%.2f price=%.2f move=%.2fR sl->%.2f (%%Trig=%s, 3R=%s)",
                        symbol_, entry, price, (R>0? move/R:0.0), targetSL,
                        (condPercent?"yes":"no"), (cond3R?"yes":"no"));
         }
      }
   }
}

// ancien : ManageOpenTrades();
void OnTick()
{
   //=== Month Filter Guard ===============================================
   {
      MqlDateTime _dt; 
      TimeToStruct(TimeCurrent(), _dt);
      if(!IsTradingMonth(TimeCurrent()) && PositionsTotal()==0 && OrdersTotal()==0)
      {
         PrintFormat("[MonthFilter] Ouverture bloquee : %s desactive.", MonthToString(_dt.mon));
         return;
      }
   }
   //=====================================================================

    ManageBreakEvenPercent(_Symbol);   // ou ManageBreakEvenPercent(sym);
   // BE en continu (seuil %)
    if(!IsNewBar()) return;
    TryOpenTrade();
}




//======================== Events ==========================
int OnInit()
{
   sym=_Symbol; dig=(int)SymbolInfoInteger(sym,SYMBOL_DIGITS); pt=SymbolInfoDouble(sym,SYMBOL_POINT);

   hEMA21=iMA(sym,InpSignalTF,21,0,MODE_EMA,PRICE_CLOSE);
   hEMA55=iMA(sym,InpSignalTF,55,0,MODE_EMA,PRICE_CLOSE);
   hSMAfast=iMA(sym,InpSignalTF,InpMACD_Fast,0,MODE_SMA,PRICE_CLOSE);
   hSMAslow=iMA(sym,InpSignalTF,InpMACD_Slow,0,MODE_SMA,PRICE_CLOSE);
   if(InpUseSMMA50Trend) hSMMA50 = iMA(sym, InpSMMA_TF, InpSMMA_Period, 0, MODE_SMMA, PRICE_CLOSE);
   
   // [ADDED] Initialize RSI handle
   if(InpUseRSI) {
      rsi_handle = iRSI(sym, InpRSITF, InpRSIPeriod, PRICE_CLOSE);
      if(rsi_handle == INVALID_HANDLE) {
         Print(__FUNCTION__, ": RSI init failed, error=", GetLastError());
         return INIT_FAILED;
      }
   }
   
   if(hEMA21==INVALID_HANDLE || hEMA55==INVALID_HANDLE || hSMAfast==INVALID_HANDLE || hSMAslow==INVALID_HANDLE || (InpUseSMMA50Trend && hSMMA50==INVALID_HANDLE)){
      Print("Erreur: handle indicateur invalide"); return INIT_FAILED;
   }
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(hEMA21  !=INVALID_HANDLE) IndicatorRelease(hEMA21);
   if(hEMA55  !=INVALID_HANDLE) IndicatorRelease(hEMA55);
   if(hSMAfast!=INVALID_HANDLE) IndicatorRelease(hSMAfast);
   if(hSMAslow!=INVALID_HANDLE) IndicatorRelease(hSMAslow);
   if(hSMMA50 !=INVALID_HANDLE) IndicatorRelease(hSMMA50);   // [ADDED]
   if(rsi_handle!=INVALID_HANDLE) IndicatorRelease(rsi_handle);   // [ADDED] RSI
}


//======================== [ADDED] Functions for LossStreak ========================
int CountConsecutiveLosses()
{
   int count = 0;
   datetime endTime = TimeCurrent();
   datetime startTime = endTime - 86400*30; // 30 derniers jours

   HistorySelect(startTime, endTime);
   int totalDeals = HistoryDealsTotal();

   // Parcourir les deals du plus récent au plus ancien
   for(int i = totalDeals-1; i >= 0; i--)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) == sym &&
         HistoryDealGetInteger(ticket, DEAL_MAGIC) == InpMagic)
      {
         double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
         if(profit < 0) count++;
         else break; // Arrêter au premier trade gagnant
      }
   }
   
   return count;
}

//======================== [ADDED] Month Filter Functions ========================
bool IsTradingMonth(datetime currentTime)
{
   MqlDateTime dt;
   TimeToStruct(currentTime, dt);
   
   switch(dt.mon)
   {
      case  1: return InpTrade_Janvier;
      case  2: return InpTrade_Fevrier;
      case  3: return InpTrade_Mars;
      case  4: return InpTrade_Avril;
      case  5: return InpTrade_Mai;
      case  6: return InpTrade_Juin;
      case  7: return InpTrade_Juillet;
      case  8: return InpTrade_Aout;
      case  9: return InpTrade_Septembre;
      case 10: return InpTrade_Octobre;
      case 11: return InpTrade_Novembre;
      case 12: return InpTrade_Decembre;
      default: return false;
   }
}

//======================== [ADDED] RSI Filter Function ========================
bool IsRSIFilterOK()
{
   if(!InpUseRSI) return true; // Filtre désactivé
   
   // Éviter recalc intra-bar
   datetime current_bar = iTime(sym, InpRSITF, 0);
   if(rsi_last_bar_time == current_bar && rsi_val != EMPTY_VALUE)
      return CheckRSILevel(rsi_val);
   
   // Mise à jour RSI
   double rsi_buffer[];
   ArraySetAsSeries(rsi_buffer, true);
   
   if(CopyBuffer(rsi_handle, 0, 1, 1, rsi_buffer) < 1) {
      if(InpVerboseLogs) Print("[RSI] Erreur lecture buffer RSI");
      return false; // Bloque si erreur lecture
   }
   
   rsi_val = rsi_buffer[0];
   rsi_last_bar_time = current_bar;
   
   return CheckRSILevel(rsi_val);
}

bool CheckRSILevel(double rsi)
{
   if(InpRSIBlockEqual) {
      // Mode >= / <=
      if(rsi >= InpRSIOverbought || rsi <= InpRSIOversold) {
         if(InpVerboseLogs) PrintFormat("[RSI] Bloqué: RSI=%.2f (seuils: %d/%d)", 
                                       rsi, InpRSIOversold, InpRSIOverbought);
         return false;
      }
   } else {
      // Mode strict > / <
      if(rsi > InpRSIOverbought || rsi < InpRSIOversold) {
         if(InpVerboseLogs) PrintFormat("[RSI] Bloqué: RSI=%.2f (seuils: %d/%d)", 
                                       rsi, InpRSIOversold, InpRSIOverbought);
         return false;
      }
   }
   
   return true; // RSI OK
}

string MonthToString(int month)
{
   switch(month)
   {
      case  1: return "Janvier";
      case  2: return "Fevrier";
      case  3: return "Mars";
      case  4: return "Avril";
      case  5: return "Mai";
      case  6: return "Juin";
      case  7: return "Juillet";
      case  8: return "Aout";
      case  9: return "Septembre";
      case 10: return "Octobre";
      case 11: return "Novembre";
      case 12: return "Decembre";
      default: return "Inconnu";
   }
}