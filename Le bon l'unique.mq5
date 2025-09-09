//+------------------------------------------------------------------+
//|                        Poseidon_DIAGNOSTIC_VERSION              |
//|  VERSION SPÉCIALE POUR DIAGNOSTIQUER POURQUOI AUCUN TRADE       |
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
input SignalMode InpSignalMode         = EMA_OR_MACD;
input bool     InpUseEMA_Cross         = true;
input bool     InpUseMACD              = true;

// --- MACD SMA config ---
input int      InpMACD_Fast            = 20;
input int      InpMACD_Slow            = 45;
input int      InpMACD_Signal          = 15;

// --- Risque / gestion ---
input double InpRiskPercent        = 1.0;
input bool   UseLossStreakReduction = true;
input int    LossStreakTrigger      = 7;
input double LossStreakFactor       = 0.50;
input bool   UseFixedRiskMoney = true;
input double FixedRiskMoney     = 100.0;
input double ReducedRiskMoney   = 50.0;
input double InpSL_PercentOfPrice  = 0.25;
input double InpTP_PercentOfPrice  = 1.25;
input double InpBE_TriggerPercent  = 0.70;
input int    InpMaxTradesPerDay    = 2;

// --- Fenêtre d'ouverture ---
input ENUM_TIMEFRAMES InpSignalTF      = PERIOD_H1;
input int      InpSessionStartHour     = 6;
input int      InpSessionEndHour       = 15;
input int      InpSlippagePoints       = 20;
input bool     InpVerboseLogs          = true;  // 🔧 FORCÉ À TRUE

// === CONDITIONS DE SCORING ===
input bool InpUseSMMA50Trend    = true;
input int  InpSMMA_Period       = 50;
input ENUM_TIMEFRAMES InpSMMA_TF = PERIOD_H4;
input int  InpMinConditions     = 3;  // ⚠️ CRITQUE : 3 conditions minimum

// === RSI Filter ===
input bool InpUseRSI = true;  // ⚠️ CRITIQUE : Peut bloquer
input ENUM_TIMEFRAMES InpRSITF = PERIOD_H4;
input int InpRSIPeriod = 14;
input int InpRSIOverbought = 70;  // ⚠️ CRITIQUE : Seuils restrictifs
input int InpRSIOversold = 25;    // ⚠️ CRITIQUE : Seuils restrictifs
input bool InpRSIBlockEqual = true;

//=== Month Filter ===
input bool InpTrade_Janvier   = false;  // ⚠️ CRITIQUE : DÉSACTIVÉ
input bool InpTrade_Fevrier   = false;  // ⚠️ CRITIQUE : DÉSACTIVÉ
input bool InpTrade_Mars      = false;  // ⚠️ CRITIQUE : DÉSACTIVÉ
input bool InpTrade_Avril     = true;
input bool InpTrade_Mai       = true;
input bool InpTrade_Juin      = true;
input bool InpTrade_Juillet   = true;
input bool InpTrade_Aout      = true;
input bool InpTrade_Septembre = true;
input bool InpTrade_Octobre   = true;
input bool InpTrade_Novembre  = true;
input bool InpTrade_Decembre  = true;

//======================== Variables ========================
datetime lastBarTime=0;
string   sym; int dig; double pt;
int tradedDay=-1, tradesCountToday=0;
int gLossStreak = 0;

// Handles
int hEMA21=-1, hEMA55=-1;
int hSMAfast=-1, hSMAslow=-1;
int hSMMA50 = -1;
int rsi_handle = INVALID_HANDLE;
double rsi_val = EMPTY_VALUE;
datetime rsi_last_bar_time = 0;

// Variables de diagnostic
static int debug_tick_count = 0;
static bool debug_init_complete = false;

//======================== Utils Temps ======================
bool IsNewBar()
{ 
   datetime ct=iTime(sym, InpSignalTF, 0); 
   if(ct!=lastBarTime)
   {
      lastBarTime=ct; 
      PrintFormat("🔹 [DEBUG] NOUVELLE BARRE détectée à %s", TimeToString(ct));
      return true;
   } 
   return false; 
}

void ResetDayIfNeeded()
{ 
   MqlDateTime t; 
   TimeToStruct(TimeCurrent(), t); 
   if(tradedDay!=t.day_of_year)
   { 
      tradedDay=t.day_of_year; 
      tradesCountToday=0; 
      PrintFormat("🔹 [DEBUG] NOUVEAU JOUR détecté: %d, trades remis à 0", t.day_of_year);
   } 
}

bool CanOpenToday()
{ 
   ResetDayIfNeeded(); 
   bool can = tradesCountToday<InpMaxTradesPerDay;
   if(!can) PrintFormat("❌ [DEBUG] MAX TRADES atteint: %d/%d", tradesCountToday, InpMaxTradesPerDay);
   return can;
}

void MarkTradeOpened(){ ResetDayIfNeeded(); tradesCountToday++; }

bool InEntryWindow()
{
   MqlDateTime t; 
   TimeToStruct(TimeCurrent(), t);
   bool inWindow;
   
   if(InpSessionStartHour<=InpSessionEndHour)
      inWindow = (t.hour>=InpSessionStartHour && t.hour<InpSessionEndHour);
   else
      inWindow = (t.hour>=InpSessionStartHour || t.hour<InpSessionEndHour);
   
   if(!inWindow) 
      PrintFormat("❌ [DEBUG] HORS FENÊTRE TRADING: %02d:%02d (session %d-%d)", t.hour, t.min, InpSessionStartHour, InpSessionEndHour);
   
   return inWindow;
}

//======================== Indicateurs ======================
bool GetEMAs(double &e21_1,double &e55_1,double &e21_2,double &e55_2)
{
   double b21[],b55[]; 
   ArraySetAsSeries(b21,true); 
   ArraySetAsSeries(b55,true);
   
   if(CopyBuffer(hEMA21,0,1,2,b21)<2) 
   {
      Print("❌ [DEBUG] Erreur CopyBuffer EMA21");
      return false;
   }
   if(CopyBuffer(hEMA55,0,1,2,b55)<2) 
   {
      Print("❌ [DEBUG] Erreur CopyBuffer EMA55");
      return false;
   }
   
   e21_1=b21[0]; e21_2=b21[1]; e55_1=b55[0]; e55_2=b55[1];
   return true;
}

bool GetMACD_SMA(double &macd_1,double &sig_1,double &macd_2,double &sig_2)
{
   int need = MathMax(MathMax(InpMACD_Fast, InpMACD_Slow), InpMACD_Signal) + 5;
   double fast[], slow[];
   ArraySetAsSeries(fast,true); ArraySetAsSeries(slow,true);
   
   if(CopyBuffer(hSMAfast,0,1,need,fast) < need) 
   {
      Print("❌ [DEBUG] Erreur CopyBuffer SMA Fast");
      return false;
   }
   if(CopyBuffer(hSMAslow,0,1,need,slow) < need) 
   {
      Print("❌ [DEBUG] Erreur CopyBuffer SMA Slow");
      return false;
   }

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

   macd_1 = macdArr[0]; sig_1  = sigArr[0];
   macd_2 = macdArr[1]; sig_2  = sigArr[1];
   return true;
}

//======================== Helpers SMMA/EMA/MACD ========================
bool GetSMMA50(double &out_smma)
{
   if(!InpUseSMMA50Trend) return false;
   if(hSMMA50==INVALID_HANDLE) return false;
   double b[]; ArraySetAsSeries(b,true);
   if(CopyBuffer(hSMMA50,0,0,1,b)<1) 
   {
      Print("❌ [DEBUG] Erreur CopyBuffer SMMA50");
      return false;
   }
   out_smma = b[0];
   return true;
}

int TrendDir_SMMA50()
{
   if(!InpUseSMMA50Trend) return 0;
   double smma=0.0; 
   if(!GetSMMA50(smma)) return 0;
   double bid=SymbolInfoDouble(sym,SYMBOL_BID), ask=SymbolInfoDouble(sym,SYMBOL_ASK);
   double px=(bid+ask)*0.5;
   
   int dir = 0;
   if(px>smma) dir = +1;
   else if(px<smma) dir = -1;
   
   PrintFormat("🔹 [DEBUG] SMMA50: %.5f, Prix: %.5f, Direction: %s", 
               smma, px, (dir>0?"HAUSSIER":(dir<0?"BAISSIER":"NEUTRE")));
   return dir;
}

bool GetEMACrossSignal(bool &buy,bool &sell)
{
   buy=false; sell=false;
   double e21_1,e55_1,e21_2,e55_2;
   if(!GetEMAs(e21_1,e55_1,e21_2,e55_2)) return false;
   
   buy  = (e21_2<=e55_2 && e21_1>e55_1);
   sell = (e21_2>=e55_2 && e21_1<e55_1);
   
   if(buy || sell)
      PrintFormat("🔹 [DEBUG] EMA Cross: %s (EMA21: %.5f->%.5f, EMA55: %.5f->%.5f)", 
                  (buy?"BUY":(sell?"SELL":"NONE")), e21_2, e21_1, e55_2, e55_1);
   
   return true;
}

bool GetMACD_CrossSignal(bool &buy,bool &sell)
{
   buy=false; sell=false;
   double m1,s1,m2,s2;
   if(!GetMACD_SMA(m1,s1,m2,s2)) return false;
   
   buy  = (m2<=s2 && m1>s1);
   sell = (m2>=s2 && m1<s1);
   
   if(buy || sell)
      PrintFormat("🔹 [DEBUG] MACD Cross: %s (MACD: %.6f->%.6f, Signal: %.6f->%.6f)", 
                  (buy?"BUY":(sell?"SELL":"NONE")), m2, m1, s2, s1);
   
   return true;
}

bool GetMACD_HistSignal(bool &buy,bool &sell)
{
   buy=false; sell=false;
   double m1,s1,m2,s2;
   if(!GetMACD_SMA(m1,s1,m2,s2)) return false;
   
   double hist = (m1 - s1);
   buy  = (hist > 0.0);
   sell = (hist < 0.0);
   
   PrintFormat("🔹 [DEBUG] MACD Hist: %.6f (%s)", hist, (buy?"BUY":(sell?"SELL":"NEUTRE")));
   return true;
}

//======================== Month Filter ========================
bool IsTradingMonth(datetime currentTime)
{
   MqlDateTime dt;
   TimeToStruct(currentTime, dt);
   
   bool allowed = false;
   switch(dt.mon)
   {
      case  1: allowed = InpTrade_Janvier; break;
      case  2: allowed = InpTrade_Fevrier; break;
      case  3: allowed = InpTrade_Mars; break;
      case  4: allowed = InpTrade_Avril; break;
      case  5: allowed = InpTrade_Mai; break;
      case  6: allowed = InpTrade_Juin; break;
      case  7: allowed = InpTrade_Juillet; break;
      case  8: allowed = InpTrade_Aout; break;
      case  9: allowed = InpTrade_Septembre; break;
      case 10: allowed = InpTrade_Octobre; break;
      case 11: allowed = InpTrade_Novembre; break;
      case 12: allowed = InpTrade_Decembre; break;
   }
   
   if(!allowed)
      PrintFormat("❌ [DEBUG] MOIS BLOQUÉ: %s (%d) - Trading désactivé", MonthToString(dt.mon), dt.mon);
   
   return allowed;
}

//======================== RSI Filter ========================
bool IsRSIFilterOK()
{
   if(!InpUseRSI) 
   {
      PrintFormat("🔹 [DEBUG] RSI Filter DÉSACTIVÉ");
      return true;
   }
   
   datetime current_bar = iTime(sym, InpRSITF, 0);
   if(rsi_last_bar_time == current_bar && rsi_val != EMPTY_VALUE)
      return CheckRSILevel(rsi_val);
   
   double rsi_buffer[];
   ArraySetAsSeries(rsi_buffer, true);
   
   if(CopyBuffer(rsi_handle, 0, 1, 1, rsi_buffer) < 1) {
      Print("❌ [DEBUG] Erreur lecture buffer RSI");
      return false;
   }
   
   rsi_val = rsi_buffer[0];
   rsi_last_bar_time = current_bar;
   
   return CheckRSILevel(rsi_val);
}

bool CheckRSILevel(double rsi)
{
   bool ok = true;
   
   if(InpRSIBlockEqual) {
      if(rsi >= InpRSIOverbought || rsi <= InpRSIOversold) {
         PrintFormat("❌ [DEBUG] RSI BLOQUE: %.2f (seuils: %d/%d, mode >=/<= )", 
                     rsi, InpRSIOversold, InpRSIOverbought);
         ok = false;
      }
   } else {
      if(rsi > InpRSIOverbought || rsi < InpRSIOversold) {
         PrintFormat("❌ [DEBUG] RSI BLOQUE: %.2f (seuils: %d/%d, mode >/<)", 
                     rsi, InpRSIOversold, InpRSIOverbought);
         ok = false;
      }
   }
   
   if(ok)
      PrintFormat("✅ [DEBUG] RSI OK: %.2f", rsi);
   
   return ok;
}

//======================== Prix/SL/TP ========================
void MakeSL_Init(int dir,double entry,double &sl)
{
   double p=InpSL_PercentOfPrice/100.0;
   if(dir>0) sl=entry*(1.0-p); else sl=entry*(1.0+p);
   sl=NormalizeDouble(sl,dig);
}

double LossPerLotAtSL(int dir,double entry,double sl)
{
   double p=0.0; 
   bool ok = (dir>0)? OrderCalcProfit(ORDER_TYPE_BUY,sym,1.0,entry,sl,p)
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
   double riskMoney = equity*(InpRiskPercent/100.0);
   
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
   }

   double lossPerLot=LossPerLotAtSL(dir,entry,sl);
   if(lossPerLot<=0) 
   {
      Print("❌ [DEBUG] LossPerLot = 0, impossible de calculer la taille");
      return 0.0;
   }
   
   double lots=riskMoney/lossPerLot;
   double step=SymbolInfoDouble(sym,SYMBOL_VOLUME_STEP);
   double minL=SymbolInfoDouble(sym,SYMBOL_VOLUME_MIN);
   double maxL=SymbolInfoDouble(sym,SYMBOL_VOLUME_MAX);
   
   if(step<=0) step=0.01;
   lots=MathFloor(lots/step)*step;
   lots=MathMax(minL,MathMin(lots,maxL));
   
   PrintFormat("🔹 [DEBUG] SIZING: equity=%.2f risk$=%.2f lossPerLot=%.2f lots=%.2f",
               equity, riskMoney, lossPerLot, lots);
   
   return lots;
}

//======================== Ouverture ========================
void TryOpenTrade()
{
   Print("🔄 [DEBUG] === TryOpenTrade() DÉMARRAGE ===");
   
   // 1. Vérification fenêtre de trading
   if(!InEntryWindow()) {
      Print("❌ [DEBUG] SORTIE: Hors fenêtre de trading");
      return;
   }
   Print("✅ [DEBUG] Fenêtre de trading OK");
   
   // 2. Vérification max trades/jour
   if(!CanOpenToday()) {
      Print("❌ [DEBUG] SORTIE: Max trades atteint");
      return;
   }
   Print("✅ [DEBUG] Max trades OK");
   
   // 3. Vérification RSI
   if(!IsRSIFilterOK()) {
      Print("❌ [DEBUG] SORTIE: RSI bloque");
      return;
   }
   Print("✅ [DEBUG] RSI Filter OK");

   // 4. Scoring des 4 conditions
   Print("🔄 [DEBUG] === CALCUL DES SIGNAUX ===");
   
   int scoreBuy=0, scoreSell=0;

   // SMMA50 Trend
   int tdir = TrendDir_SMMA50();
   if(InpUseSMMA50Trend) {
      if(tdir>0) {
         scoreBuy++;
         Print("✅ [DEBUG] SMMA50 → BUY (+1)");
      }
      else if(tdir<0) {
         scoreSell++;
         Print("✅ [DEBUG] SMMA50 → SELL (+1)");
      }
      else {
         Print("❌ [DEBUG] SORTIE: SMMA50 neutre");
         return;
      }
   }

   // EMA21/55 Cross
   bool emaB=false, emaS=false; 
   if(GetEMACrossSignal(emaB, emaS)) {
      if(emaB) {
         scoreBuy++;
         Print("✅ [DEBUG] EMA Cross → BUY (+1)");
      }
      if(emaS) {
         scoreSell++;
         Print("✅ [DEBUG] EMA Cross → SELL (+1)");
      }
   }

   // MACD Histogramme
   bool mhB=false, mhS=false; 
   if(GetMACD_HistSignal(mhB, mhS)) {
      if(mhB) {
         scoreBuy++;
         Print("✅ [DEBUG] MACD Hist → BUY (+1)");
      }
      if(mhS) {
         scoreSell++;
         Print("✅ [DEBUG] MACD Hist → SELL (+1)");
      }
   }

   // MACD Cross
   bool mcB=false, mcS=false; 
   if(GetMACD_CrossSignal(mcB, mcS)) {
      if(mcB) {
         scoreBuy++;
         Print("✅ [DEBUG] MACD Cross → BUY (+1)");
      }
      if(mcS) {
         scoreSell++;
         Print("✅ [DEBUG] MACD Cross → SELL (+1)");
      }
   }

   PrintFormat("🔹 [DEBUG] SCORES FINAUX: BUY=%d, SELL=%d (min requis=%d)", scoreBuy, scoreSell, InpMinConditions);

   // 5. Vérification conditions finales
   bool allowBuy  = (!InpUseSMMA50Trend || tdir>0);
   bool allowSell = (!InpUseSMMA50Trend || tdir<0);

   int dir=0;
   if(scoreBuy >= InpMinConditions && allowBuy && InpAllowBuys) {
      dir=+1;
      Print("🟢 [DEBUG] SIGNAL BUY VALIDÉ!");
   }
   else if(scoreSell >= InpMinConditions && allowSell && InpAllowSells && dir==0) {
      dir=-1;
      Print("🔴 [DEBUG] SIGNAL SELL VALIDÉ!");
   }
   
   if(dir==0) {
      PrintFormat("❌ [DEBUG] SORTIE: Aucun signal valide (BUY: %d/%d, SELL: %d/%d)", 
                  scoreBuy, InpMinConditions, scoreSell, InpMinConditions);
      return;
   }

   // 6. Calcul et exécution trade
   Print("🔄 [DEBUG] === PRÉPARATION TRADE ===");
   
   double entry=(dir>0)? SymbolInfoDouble(sym,SYMBOL_ASK):SymbolInfoDouble(sym,SYMBOL_BID);
   double sl; MakeSL_Init(dir,entry,sl);
   double lots=LotsFromRisk(dir,entry,sl);
   
   if(lots<=0) {
      Print("❌ [DEBUG] SORTIE: Lots calculé = 0");
      return;
   }

   double tpPrice = (dir>0 ? entry*(1.0 + InpTP_PercentOfPrice/100.0)
                           : entry*(1.0 - InpTP_PercentOfPrice/100.0));

   PrintFormat("🔹 [DEBUG] TRADE PARAMS: %s %.2f lots @ %.5f, SL=%.5f, TP=%.5f", 
               (dir>0?"BUY":"SELL"), lots, entry, sl, tpPrice);

   Trade.SetExpertMagicNumber(InpMagic);
   Trade.SetDeviationInPoints(InpSlippagePoints);
   
   string cmt="DIAGNOSTIC";
   bool ok=(dir>0)? Trade.Buy(lots,sym,entry,sl,tpPrice,cmt)
                  : Trade.Sell(lots,sym,entry,sl,tpPrice,cmt);
                  
   if(ok) {
      MarkTradeOpened();
      PrintFormat("🎉 [DEBUG] TRADE OUVERT AVEC SUCCÈS! %s %.2f lots", (dir>0?"BUY":"SELL"), lots);
   } else {
      PrintFormat("❌ [DEBUG] ERREUR OUVERTURE TRADE: %d - %s", GetLastError(), Trade.ResultComment());
   }
   
   Print("🔄 [DEBUG] === TryOpenTrade() FIN ===");
}

//======================== Break Even ========================
void ManageBreakEvenPercent(const string symbol_)
{
   for(int i=PositionsTotal()-1; i>=0; --i)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket==0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=symbol_) continue;

      long   type  = (long)PositionGetInteger(POSITION_TYPE);
      double entry = PositionGetDouble (POSITION_PRICE_OPEN);
      double sl    = PositionGetDouble (POSITION_SL);
      double tp    = PositionGetDouble (POSITION_TP);
      double price = (type==POSITION_TYPE_BUY)
                     ? SymbolInfoDouble(symbol_, SYMBOL_BID)
                     : SymbolInfoDouble(symbol_, SYMBOL_ASK);

      const double beTrigger = (type==POSITION_TYPE_BUY)
                               ? entry*(1.0 + InpBE_TriggerPercent/100.0)
                               : entry*(1.0 - InpBE_TriggerPercent/100.0);
      const bool condPercent = (type==POSITION_TYPE_BUY) ? (price>=beTrigger) : (price<=beTrigger);

      const double R    = MathAbs(entry - sl);
      const double move = MathAbs(price - entry);
      const bool   cond3R = (R>0.0 && move >= 3.0*R);

      if(condPercent || cond3R)
      {
         const int    d       = (int)SymbolInfoInteger(symbol_, SYMBOL_DIGITS);
         const double ptLocal = SymbolInfoDouble(symbol_, SYMBOL_POINT);

         double targetSL = NormalizeDouble(entry, d);
         bool need = (type==POSITION_TYPE_BUY)  ? (sl < targetSL - 10*ptLocal)
                                                : (sl > targetSL + 10*ptLocal);

         if(need){
            Trade.PositionModify(symbol_, targetSL, tp);
            PrintFormat("[BE] %s entry=%.2f price=%.2f move=%.2fR sl->%.2f", 
                        symbol_, entry, price, (R>0? move/R:0.0), targetSL);
         }
      }
   }
}

//======================== OnTick - VERSION DIAGNOSTIC ========================
void OnTick()
{
   debug_tick_count++;
   
   // Debug périodique (chaque 100 ticks)
   if(debug_tick_count % 100 == 1) {
      MqlDateTime dt; 
      TimeToStruct(TimeCurrent(), dt);
      
      PrintFormat("📊 [DEBUG PÉRIODIQUE] Tick #%d - %s %02d:%02d:%02d", 
                  debug_tick_count, 
                  TimeToString(TimeCurrent(), TIME_DATE),
                  dt.hour, dt.min, dt.sec);
                  
      PrintFormat("📊 [DEBUG] Mois actuel: %s - Trading autorisé: %s", 
                  MonthToString(dt.mon), 
                  IsTradingMonth(TimeCurrent()) ? "OUI" : "NON");
                  
      PrintFormat("📊 [DEBUG] Positions ouvertes: %d, Orders: %d", 
                  PositionsTotal(), OrdersTotal());
                  
      PrintFormat("📊 [DEBUG] Params critiques - MinConditions:%d, UseRSI:%s, UseSMMA50:%s", 
                  InpMinConditions, 
                  InpUseRSI ? "true" : "false",
                  InpUseSMMA50Trend ? "true" : "false");
   }

   //=== Month Filter Guard ===============================================
   {
      MqlDateTime _dt; 
      TimeToStruct(TimeCurrent(), _dt);
      if(!IsTradingMonth(TimeCurrent()) && PositionsTotal()==0 && OrdersTotal()==0)
      {
         if(debug_tick_count % 500 == 1) // Log toutes les 500 ticks pour éviter spam
            PrintFormat("⚠️ [MonthFilter] Ouverture bloquée : %s désactivé.", MonthToString(_dt.mon));
         return;
      }
   }
   //=====================================================================

   ManageBreakEvenPercent(_Symbol);
   
   // Vérification nouvelle barre
   if(!IsNewBar()) return;
   
   Print("🆕 [DEBUG] NOUVELLE BARRE → Appel TryOpenTrade()");
   TryOpenTrade();
}

//======================== Events ==========================
int OnInit()
{
   Print("🚀 [DEBUG] === INITIALISATION EA DIAGNOSTIC ===");
   
   sym=_Symbol; 
   dig=(int)SymbolInfoInteger(sym,SYMBOL_DIGITS); 
   pt=SymbolInfoDouble(sym,SYMBOL_POINT);
   
   PrintFormat("🔹 [DEBUG] Symbole: %s, Digits: %d, Point: %.6f", sym, dig, pt);

   // Initialisation des handles
   hEMA21=iMA(sym,InpSignalTF,21,0,MODE_EMA,PRICE_CLOSE);
   hEMA55=iMA(sym,InpSignalTF,55,0,MODE_EMA,PRICE_CLOSE);
   hSMAfast=iMA(sym,InpSignalTF,InpMACD_Fast,0,MODE_SMA,PRICE_CLOSE);
   hSMAslow=iMA(sym,InpSignalTF,InpMACD_Slow,0,MODE_SMA,PRICE_CLOSE);
   
   if(InpUseSMMA50Trend) {
      hSMMA50 = iMA(sym, InpSMMA_TF, InpSMMA_Period, 0, MODE_SMMA, PRICE_CLOSE);
      PrintFormat("🔹 [DEBUG] SMMA50 Handle: %d", hSMMA50);
   }
   
   if(InpUseRSI) {
      rsi_handle = iRSI(sym, InpRSITF, InpRSIPeriod, PRICE_CLOSE);
      if(rsi_handle == INVALID_HANDLE) {
         Print("❌ [DEBUG] RSI init ÉCHEC, erreur=", GetLastError());
         return INIT_FAILED;
      }
      PrintFormat("🔹 [DEBUG] RSI Handle: %d", rsi_handle);
   }
   
   // Vérification des handles
   if(hEMA21==INVALID_HANDLE || hEMA55==INVALID_HANDLE || 
      hSMAfast==INVALID_HANDLE || hSMAslow==INVALID_HANDLE || 
      (InpUseSMMA50Trend && hSMMA50==INVALID_HANDLE)) {
      Print("❌ [DEBUG] Erreur: handle indicateur invalide");
      return INIT_FAILED;
   }
   
   PrintFormat("✅ [DEBUG] Tous les handles créés: EMA21=%d, EMA55=%d, SMAfast=%d, SMAslow=%d", 
               hEMA21, hEMA55, hSMAfast, hSMAslow);
   
   // Affichage des paramètres critiques
   Print("🔹 [DEBUG] === PARAMÈTRES CRITIQUES ===");
   PrintFormat("🔹 [DEBUG] InpMinConditions: %d", InpMinConditions);
   PrintFormat("🔹 [DEBUG] InpUseRSI: %s (seuils: %d/%d)", 
               InpUseRSI ? "ACTIVÉ" : "DÉSACTIVÉ", InpRSIOversold, InpRSIOverbought);
   PrintFormat("🔹 [DEBUG] InpUseSMMA50Trend: %s", InpUseSMMA50Trend ? "ACTIVÉ" : "DÉSACTIVÉ");
   PrintFormat("🔹 [DEBUG] Session trading: %02d:00-%02d:00", InpSessionStartHour, InpSessionEndHour);
   
   // Affichage filtres mois
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   PrintFormat("🔹 [DEBUG] Mois actuel: %s (%d) - Autorisé: %s", 
               MonthToString(dt.mon), dt.mon, IsTradingMonth(TimeCurrent()) ? "OUI" : "NON");
   
   if(!IsTradingMonth(TimeCurrent())) {
      Print("⚠️ [DEBUG] ATTENTION: Le mois actuel est DÉSACTIVÉ dans les paramètres!");
   }
   
   debug_init_complete = true;
   Print("✅ [DEBUG] === INITIALISATION TERMINÉE AVEC SUCCÈS ===");
   
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   Print("🛑 [DEBUG] === DÉINITIALISATION EA ===");
   PrintFormat("🔹 [DEBUG] Raison: %d, Total ticks traités: %d", reason, debug_tick_count);
   
   if(hEMA21  !=INVALID_HANDLE) IndicatorRelease(hEMA21);
   if(hEMA55  !=INVALID_HANDLE) IndicatorRelease(hEMA55);
   if(hSMAfast!=INVALID_HANDLE) IndicatorRelease(hSMAfast);
   if(hSMAslow!=INVALID_HANDLE) IndicatorRelease(hSMAslow);
   if(hSMMA50 !=INVALID_HANDLE) IndicatorRelease(hSMMA50);
   if(rsi_handle!=INVALID_HANDLE) IndicatorRelease(rsi_handle);
   
   Print("✅ [DEBUG] Tous les handles libérés");
}

//======================== Fonctions auxiliaires ========================
int CountConsecutiveLosses()
{
   int count = 0;
   datetime endTime = TimeCurrent();
   datetime startTime = endTime - 86400*30; // 30 derniers jours

   HistorySelect(startTime, endTime);
   int totalDeals = HistoryDealsTotal();

   for(int i = totalDeals-1; i >= 0; i--)
   {
      ulong ticket = HistoryDealGetTicket(i);
      if(HistoryDealGetString(ticket, DEAL_SYMBOL) == sym &&
         HistoryDealGetInteger(ticket, DEAL_MAGIC) == InpMagic)
      {
         double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
         if(profit < 0) count++;
         else break;
      }
   }
   
   return count;
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
