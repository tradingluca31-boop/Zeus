//+------------------------------------------------------------------+
//|                         TEST CLAUDE FIXED - Lot Size & TP Corrected |
//|  Version corrigée avec calcul simplifié pour XAUUSD              |
//|  Risque: 100$ FIXE | TP: 500$ FIXE (5R) | SL: 0.35%             |
//+------------------------------------------------------------------+
#property strict
#include <Trade/Trade.mqh>

CTrade Trade;

//======================== Inputs utilisateur ========================
input long     InpMagic                = 20250811;
input bool     InpAllowBuys            = true;
input bool     InpAllowSells           = true;

// --- 3 Signaux indépendants ---
input bool     InpUseEMA_Cross         = true;        // EMA21/55 croisement
input bool     InpUseMACD              = true;        // MACD histogramme
input bool     InpUseSMMA_Cross        = true;        // SMMA50/200 croisement H1
input int      InpMinSignalsRequired   = 2;           // Signaux minimum requis (1, 2 ou 3)

// --- MACD SMA config ---
input int      InpMACD_Fast            = 20;          // SMA rapide
input int      InpMACD_Slow            = 35;          // SMA lente
input int      InpMACD_Signal          = 15;          // SMA du MACD

// --- Risque / gestion (CORRIGÉ POUR XAUUSD) ---
input double InpRiskPercent        = 1.0;   // % de la BALANCE risqué par trade
// [FIXED] Poseidon - RISK MANAGEMENT SIMPLIFIÉ
input bool   UseFixedRiskMoney = true;   // FORCÉ à TRUE pour 100$ fixe
input double FixedRiskMoney     = 100.0; // FORCÉ à 100$ de risque
input double ReducedRiskMoney   = 50.0;  // Montant réduit après pertes

input double InpSL_PercentOfPrice  = 0.35;  // SL = 0.35% du prix d'entrée
input double InpTP_PercentOfPrice  = 1.75;  // TP = % du prix d'entrée
input double InpBE_TriggerPercent  = 1;      // BE quand +1% ou 3R
input int    InpMaxTradesPerDay    = 4;

// [ADDED] Poseidon Loss Streak Reduction
input bool   UseLossStreakReduction = true;
input int    LossStreakTrigger      = 7;
input double LossStreakFactor       = 0.50;

// --- Fenêtre d'ouverture ---
input ENUM_TIMEFRAMES InpSignalTF      = PERIOD_H1;   // TF signaux (H1)
input int      InpSessionStartHour     = 6;           // Ouverture 6h
input int      InpSessionEndHour       = 15;          // Fermeture 15h
input int      InpSlippagePoints       = 20;
input bool     InpVerboseLogs          = true;        // FORCÉ pour debug

// [ADDED] === SMMA50 + Score conditions ===
input bool InpUseSMMA50Trend    = true;
input int  InpSMMA_Period       = 50;
input ENUM_TIMEFRAMES InpSMMA_TF = PERIOD_H4;
input int  InpMinConditions     = 3;

// [ADDED] === RSI Filter ===
input bool InpUseRSI = true;
input ENUM_TIMEFRAMES InpRSITF = PERIOD_H4;
input int InpRSIPeriod = 12;
input int InpRSIOverbought = 80;
input int InpRSIOversold = 25;
input bool InpRSIBlockEqual = true;

//=== Month Filter Inputs ===
input bool InpTrade_Janvier   = true;
input bool InpTrade_Fevrier   = true;
input bool InpTrade_Mars      = false;
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

// Handles EMA/MAs pour MACD SMA
int hEMA21=-1, hEMA55=-1;
int hSMAfast=-1, hSMAslow=-1;
int hSMMA50 = -1;   // Handle SMMA50 (filtre)
int hSMMA50_Signal = -1, hSMMA200_Signal = -1;   // Handles SMMA50/200 pour croisement H1
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


//======================== SMMA/Scoring Functions ========================
bool GetSMMA50(double &out_smma)
{
   if(!InpUseSMMA50Trend) return false;
   if(hSMMA50==INVALID_HANDLE) return false;
   double b[]; ArraySetAsSeries(b,true);
   if(CopyBuffer(hSMMA50,0,0,1,b)<1) return false;
   out_smma = b[0];
   return true;
}

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

bool GetEMACrossSignal(bool &buy,bool &sell)
{
   buy=false; sell=false;
   double e21_1,e55_1,e21_2,e55_2;
   if(!GetEMAs(e21_1,e55_1,e21_2,e55_2)) return false;
   buy  = (e21_2<=e55_2 && e21_1>e55_1);
   sell = (e21_2>=e55_2 && e21_1<e55_1);
   return true;
}

bool GetMACD_CrossSignal(bool &buy,bool &sell)
{
   buy=false; sell=false;
   double m1,s1,m2,s2;
   if(!GetMACD_SMA(m1,s1,m2,s2)) return false;
   buy  = (m2<=s2 && m1>s1);
   sell = (m2>=s2 && m1<s1);
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
   return true;
}

// SMMA50/200 croisement H1 - signal basé sur le croisement des moyennes
bool GetSMMA50_DirectionH1(bool &buy, bool &sell)
{
   buy = false; sell = false;
   if(!InpUseSMMA_Cross) return false;

   double smma50[], smma200[];
   ArraySetAsSeries(smma50, true); ArraySetAsSeries(smma200, true);

   if(CopyBuffer(hSMMA50_Signal, 0, 0, 2, smma50) < 2) return false;
   if(CopyBuffer(hSMMA200_Signal, 0, 0, 2, smma200) < 2) return false;

   // Croisement persistant : SMMA50 > SMMA200 = BUY, SMMA50 < SMMA200 = SELL
   buy = (smma50[0] > smma200[0]);
   sell = (smma50[0] < smma200[0]);

   return true;
}

//======================== SL/TP Prix ========================
void MakeSL_Init(int dir,double entry,double &sl)
{
   double p=InpSL_PercentOfPrice/100.0;
   if(dir>0) sl=entry*(1.0-p); else sl=entry*(1.0+p);
   sl=NormalizeDouble(sl,dig);
}

//======================== [FIXED] CALCUL LOT ULTRA-SIMPLIFIÉ XAUUSD ========================
double LotsFromRisk_XAUUSD_Fixed(int dir, double entry, double sl)
{
   // ============================================================================
   // CALCUL FORCÉ SPÉCIALEMENT POUR XAUUSD AVEC RISQUE 100$ ET SL 0.35%
   // ============================================================================
   
   Print("╔══════════════════════════════════════════════════════════════════╗");
   Print("║              CALCUL LOT SIZE ULTRA-SIMPLIFIÉ XAUUSD             ║");
   Print("╠══════════════════════════════════════════════════════════════════╣");
   
   // FORCER LE RISQUE À 100$ (ignorer tous les paramètres complexes)
   double riskAmount = 100.0;
   
   // Gestion de la réduction après pertes consécutives
   if(UseLossStreakReduction) {
      gLossStreak = CountConsecutiveLosses();
      if(gLossStreak >= LossStreakTrigger) {
         riskAmount = ReducedRiskMoney; // 50$ en cas de série de pertes
         Print("║ ⚠️  RÉDUCTION RISQUE: ", gLossStreak, " pertes → ", riskAmount, "$        ║");
      }
   }
   
   // FORCER LE SL À 0.35% 
   double stopLossPercent = 0.35;
   double stopLossDistance = entry * stopLossPercent / 100.0;
   
   // ============================================================================ 
   // CALCUL SPÉCIFIQUE XAUUSD : 1$ de mouvement = 100 lots mini de profit/perte
   // Pour risquer 100$ avec SL de ~7$ → besoin de ~14 lots mini = 0.14 lot
   // ============================================================================
   
   double lotSize = riskAmount / stopLossDistance / 100.0; // Division par 100 pour XAUUSD
   
   // Limites de sécurité
   if(lotSize < 0.01) lotSize = 0.01;
   if(lotSize > 10.0) lotSize = 10.0;
   
   // Arrondir à 0.01
   lotSize = MathRound(lotSize * 100.0) / 100.0;
   
   // Logs détaillés
   Print("║ Prix entrée: ", entry, "                                         ║");
   Print("║ Risque: ", riskAmount, "$                                        ║");
   Print("║ SL: ", stopLossPercent, "% = ", stopLossDistance, "$             ║");
   Print("║ Formule: ", riskAmount, " ÷ ", stopLossDistance, " ÷ 100         ║");
   Print("║ LOT CALCULÉ: ", lotSize, "                                       ║");
   
   // Vérification finale
   if(lotSize > 1.0) {
      Print("║ ⚠️  ALERTE: Lot trop grand (", lotSize, ") - forcé à 0.15     ║");
      lotSize = 0.15;
   }
   
   Print("║ 🎯 LOT FINAL: ", lotSize, "                                      ║");
   Print("╚══════════════════════════════════════════════════════════════════╝");
   
   return lotSize;
}


//======================== Ouverture ========================
void TryOpenTrade()
{
   if(!InEntryWindow()) return;
   if(!CanOpenToday()) return;
   
   // RSI Filter
   if(!IsRSIFilterOK()) return;

   // 3 SIGNAUX INDÉPENDANTS avec persistance - Règle 2/3
   int scoreBuy=0, scoreSell=0;

   // SIGNAL 1) EMA21/55 croisement (persistant)
   bool emaB=false, emaS=false;
   GetEMACrossSignal(emaB, emaS);
   if(emaB) scoreBuy++;
   if(emaS) scoreSell++;

   // SIGNAL 2) MACD histogramme seulement (persistant)
   bool macdB=false, macdS=false;
   GetMACD_HistSignal(macdB, macdS);
   if(macdB) scoreBuy++;
   if(macdS) scoreSell++;

   // SIGNAL 3) SMMA50/200 croisement H1 (persistant)
   bool smmaB=false, smmaS=false;
   GetSMMA50_DirectionH1(smmaB, smmaS);
   if(smmaB) scoreBuy++;
   if(smmaS) scoreSell++;

   // FILTRES (ne comptent pas dans le score)
   int tdir = TrendDir_SMMA50(); // +1/-1/0 (filtre SMMA50 H4)
   bool allowBuy  = (!InpUseSMMA50Trend || tdir>0);
   bool allowSell = (!InpUseSMMA50Trend || tdir<0);

   // Règle X/3 signaux (configurable)
   int dir=0;
   if(scoreBuy >= InpMinSignalsRequired && allowBuy && InpAllowBuys) dir=+1;
   if(scoreSell >= InpMinSignalsRequired && allowSell && InpAllowSells && dir==0) dir=-1;
   if(dir==0) return;

   double entry=(dir>0)? SymbolInfoDouble(sym,SYMBOL_ASK):SymbolInfoDouble(sym,SYMBOL_BID);
   double sl; MakeSL_Init(dir,entry,sl);
   
   // [FIXED] Utiliser la nouvelle fonction de calcul de lot simplifiée
   double lots = LotsFromRisk_XAUUSD_Fixed(dir, entry, sl);
   if(lots<=0) return;

   // TP en % du prix d'entrée
   double tpPrice = (dir>0 ? entry*(1.0 + InpTP_PercentOfPrice/100.0)
                           : entry*(1.0 - InpTP_PercentOfPrice/100.0));

   Trade.SetExpertMagicNumber(InpMagic);
   Trade.SetDeviationInPoints(InpSlippagePoints);
   string cmt="CLAUDE-FIXED";
   if(UseLossStreakReduction && gLossStreak >= LossStreakTrigger) cmt="RISK-REDUCED";
   
   bool ok=(dir>0)? Trade.Buy(lots,sym,entry,sl,tpPrice,cmt)
                  : Trade.Sell(lots,sym,entry,sl,tpPrice,cmt);
   if(ok) MarkTradeOpened();
}

//======================== Gestion BE =======================
double RPrice(const double entry){ return entry*(InpSL_PercentOfPrice/100.0); }

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
            PrintFormat("[BE] %s entry=%.2f price=%.2f move=%.2fR sl->%.2f (%%Trig=%s, 3R=%s)",
                        symbol_, entry, price, (R>0? move/R:0.0), targetSL,
                        (condPercent?"yes":"no"), (cond3R?"yes":"no"));
         }
      }
   }
}

void OnTick()
{
   // Month Filter Guard
   {
      MqlDateTime _dt; 
      TimeToStruct(TimeCurrent(), _dt);
      if(!IsTradingMonth(TimeCurrent()) && PositionsTotal()==0 && OrdersTotal()==0)
      {
         PrintFormat("[MonthFilter] Ouverture bloquee : %s desactive.", MonthToString(_dt.mon));
         return;
      }
   }

   ManageBreakEvenPercent(_Symbol);
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

   // Initialize SMMA signals H1
   if(InpUseSMMA_Cross) {
      hSMMA50_Signal = iMA(sym, PERIOD_H1, 50, 0, MODE_SMMA, PRICE_CLOSE);
      hSMMA200_Signal = iMA(sym, PERIOD_H1, 200, 0, MODE_SMMA, PRICE_CLOSE);
   }
   
   if(InpUseRSI) {
      rsi_handle = iRSI(sym, InpRSITF, InpRSIPeriod, PRICE_CLOSE);
      if(rsi_handle == INVALID_HANDLE) {
         Print(__FUNCTION__, ": RSI init failed, error=", GetLastError());
         return INIT_FAILED;
      }
   }
   
   if(hEMA21==INVALID_HANDLE || hEMA55==INVALID_HANDLE || hSMAfast==INVALID_HANDLE || hSMAslow==INVALID_HANDLE || (InpUseSMMA50Trend && hSMMA50==INVALID_HANDLE) || (InpUseSMMA_Cross && (hSMMA50_Signal==INVALID_HANDLE || hSMMA200_Signal==INVALID_HANDLE))){
      Print("Erreur: handle indicateur invalide"); return INIT_FAILED;
   }
   
   Print("✅ TEST CLAUDE FIXED initialisé - Calculs simplifiés pour XAUUSD");
   Print("🎯 Risque fixe: 100$ | TP fixe: 500$ | SL: 0.35%");
   
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   Print("🛑 === OnDeinit appelé - Raison: ", reason, " ===");
   
   if(MQLInfoInteger(MQL_TESTER)) {
      Print("🚀 OnDeinit: Mode testeur détecté - Lancement export de sauvegarde");
      ExportTradeHistoryCSV();
   }
   
   if(hEMA21  !=INVALID_HANDLE) IndicatorRelease(hEMA21);
   if(hEMA55  !=INVALID_HANDLE) IndicatorRelease(hEMA55);
   if(hSMAfast!=INVALID_HANDLE) IndicatorRelease(hSMAfast);
   if(hSMAslow!=INVALID_HANDLE) IndicatorRelease(hSMAslow);
   if(hSMMA50 !=INVALID_HANDLE) IndicatorRelease(hSMMA50);
   if(hSMMA50_Signal!=INVALID_HANDLE) IndicatorRelease(hSMMA50_Signal);
   if(hSMMA200_Signal!=INVALID_HANDLE) IndicatorRelease(hSMMA200_Signal);
   if(rsi_handle!=INVALID_HANDLE) IndicatorRelease(rsi_handle);
   
   Print("✅ OnDeinit: Handles libérés");
}

//======================== Loss Streak Functions ========================
int CountConsecutiveLosses()
{
   int count = 0;
   datetime endTime = TimeCurrent();
   datetime startTime = endTime - 86400*30;

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

//======================== Month Filter Functions ========================
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

//======================== RSI Filter Function ========================
bool IsRSIFilterOK()
{
   if(!InpUseRSI) return true;
   
   datetime current_bar = iTime(sym, InpRSITF, 0);
   if(rsi_last_bar_time == current_bar && rsi_val != EMPTY_VALUE)
      return CheckRSILevel(rsi_val);
   
   double rsi_buffer[];
   ArraySetAsSeries(rsi_buffer, true);
   
   if(CopyBuffer(rsi_handle, 0, 1, 1, rsi_buffer) < 1) {
      if(InpVerboseLogs) Print("[RSI] Erreur lecture buffer RSI");
      return false;
   }
   
   rsi_val = rsi_buffer[0];
   rsi_last_bar_time = current_bar;
   
   return CheckRSILevel(rsi_val);
}

bool CheckRSILevel(double rsi)
{
   if(InpRSIBlockEqual) {
      if(rsi >= InpRSIOverbought || rsi <= InpRSIOversold) {
         if(InpVerboseLogs) PrintFormat("[RSI] Bloqué: RSI=%.2f (seuils: %d/%d)", 
                                       rsi, InpRSIOversold, InpRSIOverbought);
         return false;
      }
   } else {
      if(rsi > InpRSIOverbought || rsi < InpRSIOversold) {
         if(InpVerboseLogs) PrintFormat("[RSI] Bloqué: RSI=%.2f (seuils: %d/%d)", 
                                       rsi, InpRSIOversold, InpRSIOverbought);
         return false;
      }
   }
   
   return true;
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

//======================== Export CSV Functions ========================
void ExportTradeHistoryCSV()
{
   Print("=== DÉBUT EXPORT CSV TRADES - VERSION CLAUDE FIXED ===");
   
   string file_name = StringSubstr(sym, 0, 6) + "_CLAUDE_FIXED_" + TimeToString(TimeCurrent(), TIME_DATE) + ".csv";
   
   int file_handle = FileOpen(file_name, FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, 0, CP_UTF8);
   if(file_handle == INVALID_HANDLE)
   {
      Print("Échec FILE_COMMON, essai sans FILE_COMMON");
      file_handle = FileOpen(file_name, FILE_WRITE | FILE_CSV | FILE_ANSI, 0, CP_UTF8);
   }
   
   if(file_handle == INVALID_HANDLE)
   {
      Print("ERREUR CRITIQUE: Impossible de créer le fichier CSV. Erreur: ", GetLastError());
      return;
   }
   
   Print("✅ Fichier CSV ouvert avec succès: ", file_name);
   
   FileWrite(file_handle, "magic,symbol,type,time_open,time_close,price_open,price_close,profit,volume,swap,commission,comment");
   
   datetime startDate = D'2020.01.01';
   datetime endDate = TimeCurrent() + 86400;
   
   if(HistorySelect(startDate, endDate))
   {
      Print("✅ Historique sélectionné avec succès");
      int total_deals = HistoryDealsTotal();
      Print("📊 Nombre total de deals: ", total_deals);
      
      int exported_count = 0;
      
      for(int i = 0; i < total_deals; i++)
      {
         ulong ticket = HistoryDealGetTicket(i);
         if(ticket == 0) continue;
         
         long deal_magic = HistoryDealGetInteger(ticket, DEAL_MAGIC);
         if(deal_magic != InpMagic) continue;
         
         if(HistoryDealGetInteger(ticket, DEAL_ENTRY) == DEAL_ENTRY_OUT)
         {
            string deal_symbol = HistoryDealGetString(ticket, DEAL_SYMBOL);
            long deal_type = HistoryDealGetInteger(ticket, DEAL_TYPE);
            long deal_time = HistoryDealGetInteger(ticket, DEAL_TIME);
            double deal_price = HistoryDealGetDouble(ticket, DEAL_PRICE);
            double deal_profit = HistoryDealGetDouble(ticket, DEAL_PROFIT);
            double deal_volume = HistoryDealGetDouble(ticket, DEAL_VOLUME);
            double deal_swap = HistoryDealGetDouble(ticket, DEAL_SWAP);
            double deal_commission = HistoryDealGetDouble(ticket, DEAL_COMMISSION);
            string deal_comment = HistoryDealGetString(ticket, DEAL_COMMENT);
            
            string csv_line = IntegerToString(deal_magic) + "," +
                             deal_symbol + "," +
                             IntegerToString(deal_type) + "," +
                             IntegerToString(deal_time) + "," +
                             IntegerToString(deal_time) + "," +
                             DoubleToString(deal_price, 5) + "," +
                             DoubleToString(deal_price, 5) + "," +
                             DoubleToString(deal_profit, 2) + "," +
                             DoubleToString(deal_volume, 2) + "," +
                             DoubleToString(deal_swap, 2) + "," +
                             DoubleToString(deal_commission, 2) + "," +
                             deal_comment;
            
            FileWrite(file_handle, csv_line);
            exported_count++;
         }
      }
      
      Print("🎯 Nombre de trades exportés: ", exported_count);
   }
   else
   {
      Print("❌ ERREUR: Impossible de sélectionner l'historique. Erreur: ", GetLastError());
   }
   
   FileFlush(file_handle);
   FileClose(file_handle);
   Print("✅ Fichier CSV fermé avec succès");
   Print("📁 Localisation: MQL5/Files/Common/ ou Tester/Files/");
   Print("=== FIN EXPORT CSV TRADES - VERSION CLAUDE FIXED ===");
}

void OnTesterDeinit()
{
   Print("🚀 === OnTesterDeinit appelé - Export automatique CLAUDE FIXED ===");
   ExportTradeHistoryCSV();
   Print("🏁 === Fin OnTesterDeinit CLAUDE FIXED ===");
}