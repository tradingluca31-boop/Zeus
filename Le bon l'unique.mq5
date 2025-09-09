//+------------------------------------------------------------------+
//| POSEIDON EA - VERSION DEBUG CSV (Résolution problème export)    |
//| Diagnostic + Solution pour fichiers CSV non créés               |
//+------------------------------------------------------------------+
#property strict
#property copyright "Poseidon Trading System - CSV Debug"
#property version   "2.1"
#include <Trade/Trade.mqh>

CTrade Trade;

//======================== INPUTS PRINCIPAUX ========================
input long     InpMagic                = 20250811;
input bool     InpAllowBuys            = true;
input bool     InpAllowSells           = true;

// --- Export CSV (FORCÉ ON pour debug) ---
input bool     InpExportCSV            = true;        // Activer export CSV
input string   InpCSVPrefix            = "Poseidon";  // Préfixe fichiers CSV
input bool     InpForceCSVDebug        = true;        // NOUVEAU: Debug forcé

// --- Signaux ---
enum SignalMode { EMA_OR_MACD=0, EMA_ONLY=1, MACD_ONLY=2 };
input SignalMode InpSignalMode         = EMA_OR_MACD;
input bool     InpUseEMA_Cross         = true;
input bool     InpUseMACD              = true;

// --- MACD SMA config ---
input int      InpMACD_Fast            = 20;
input int      InpMACD_Slow            = 45;
input int      InpMACD_Signal          = 15;

// --- Risque ---
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

// --- Session Trading ---
input bool     InpUseSessionFilter     = true;
enum SessionMode { ASIA=0, LONDON=1, NY=2, CUSTOM=3 };
input SessionMode InpSessionMode       = LONDON;
input int      InpCustomStartHour      = 6;
input int      InpCustomEndHour        = 15;
input int      InpBrokerGMTOffset      = 2;
input bool     InpUseAutoDST          = true;
input bool     InpAllowOvernightPos    = false;
input bool     InpFlattenAtSessionEnd  = true;

// --- Jours autorisés ---
input bool     InpTrade_Monday         = true;
input bool     InpTrade_Tuesday        = true;
input bool     InpTrade_Wednesday      = true;
input bool     InpTrade_Thursday       = true;
input bool     InpTrade_Friday         = true;
input bool     InpTrade_Saturday       = false;
input bool     InpTrade_Sunday         = false;

// --- Indicateurs ---
input ENUM_TIMEFRAMES InpSignalTF      = PERIOD_H1;
input bool InpUseSMMA50Trend    = true;
input int  InpSMMA_Period       = 50;
input ENUM_TIMEFRAMES InpSMMA_TF = PERIOD_H4;
input int  InpMinConditions     = 3;

// --- RSI Filter ---
input bool InpUseRSI = true;
input ENUM_TIMEFRAMES InpRSITF = PERIOD_H4;
input int InpRSIPeriod = 14;
input int InpRSIOverbought = 70;
input int InpRSIOversold = 25;
input bool InpRSIBlockEqual = true;

// --- Mois autorisés ---
input bool InpTrade_Janvier   = false;
input bool InpTrade_Fevrier   = false;
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

input int      InpSlippagePoints       = 20;
input bool     InpVerboseLogs          = true;  // FORCÉ ON pour debug

//======================== VARIABLES GLOBALES ========================
datetime lastBarTime=0;
string   sym; int dig; double pt;
int tradedDay=-1, tradesCountToday=0;
int gLossStreak = 0;

// Handles indicateurs
int hEMA21=-1, hEMA55=-1;
int hSMAfast=-1, hSMAslow=-1;
int hSMMA50 = -1;
int rsi_handle = INVALID_HANDLE;
double rsi_val = EMPTY_VALUE;
datetime rsi_last_bar_time = 0;

// === VARIABLES CSV EXPORT (SIMPLIFIÉES) ===
string csvTradesFile = "";
string csvSignalsFile = "";
string csvStatsFile = "";
int signalCounter = 0;
int tradesCounter = 0;
bool csvInitialized = false;

//======================== STRUCTURES POUR LOGGING ========================
struct TradeRecord
{
   datetime openTime;
   string   symbol;
   int      type;
   double   volume;
   double   openPrice;
   double   sl;
   double   tp;
   double   profit;
   string   comment;
};

struct SignalRecord
{
   datetime time;
   string   symbol;
   int      signal;
   double   price;
   string   reason;
};

//======================== FONCTIONS CSV SIMPLIFIÉES (DEBUG) ========================

bool TestFileWritePermissions()
{
   string testFile = "TEST_PERMISSIONS.txt";
   int handle = FileOpen(testFile, FILE_WRITE|FILE_TXT);
   
   if(handle == INVALID_HANDLE)
   {
      Print("[CSV ERROR] Impossible d'écrire fichier test. Error: ", GetLastError());
      return false;
   }
   
   FileWrite(handle, "Test permissions OK");
   FileClose(handle);
   
   Print("[CSV OK] Permissions d'écriture vérifiées");
   FileDelete(testFile); // Nettoyer
   return true;
}

void InitializeCSVFiles_Debug()
{
   Print("[CSV DEBUG] === DÉBUT INITIALISATION CSV ===");
   
   if(!InpExportCSV && !InpForceCSVDebug)
   {
      Print("[CSV DEBUG] Export CSV désactivé");
      return;
   }
   
   // Test permissions d'abord
   if(!TestFileWritePermissions())
   {
      Print("[CSV ERROR] Permissions fichiers échouées - ARRÊT");
      return;
   }
   
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   
   // Noms de fichiers SIMPLIFIÉS
   csvTradesFile = StringFormat("%s_Trades.csv", InpCSVPrefix);
   csvSignalsFile = StringFormat("%s_Signals.csv", InpCSVPrefix);
   csvStatsFile = StringFormat("%s_Stats.csv", InpCSVPrefix);
   
   Print("[CSV DEBUG] Noms fichiers:");
   Print("- Trades: ", csvTradesFile);
   Print("- Signals: ", csvSignalsFile);
   Print("- Stats: ", csvStatsFile);
   
   // === CRÉATION FICHIER TRADES ===
   int handle = FileOpen(csvTradesFile, FILE_WRITE|FILE_CSV);
   if(handle == INVALID_HANDLE)
   {
      Print("[CSV ERROR] Impossible créer ", csvTradesFile, " Error: ", GetLastError());
      return;
   }
   
   FileWrite(handle, "TradeID", "Time", "Symbol", "Type", "Volume", "Price", "SL", "TP", "Profit", "Comment");
   FileClose(handle);
   Print("[CSV OK] Fichier trades créé: ", csvTradesFile);
   
   // === CRÉATION FICHIER SIGNALS ===
   handle = FileOpen(csvSignalsFile, FILE_WRITE|FILE_CSV);
   if(handle == INVALID_HANDLE)
   {
      Print("[CSV ERROR] Impossible créer ", csvSignalsFile, " Error: ", GetLastError());
      return;
   }
   
   FileWrite(handle, "SignalID", "Time", "Symbol", "Signal", "Price", "Reason");
   FileClose(handle);
   Print("[CSV OK] Fichier signals créé: ", csvSignalsFile);
   
   // Test écriture immédiate
   WriteTestSignal();
   
   csvInitialized = true;
   Print("[CSV DEBUG] === INITIALISATION CSV TERMINÉE ===");
}

void WriteTestSignal()
{
   Print("[CSV DEBUG] Écriture signal de test...");
   
   int handle = FileOpen(csvSignalsFile, FILE_WRITE|FILE_CSV);
   if(handle == INVALID_HANDLE)
   {
      Print("[CSV ERROR] Impossible ouvrir ", csvSignalsFile, " pour test. Error: ", GetLastError());
      return;
   }
   
   FileSeek(handle, 0, SEEK_END);
   FileWrite(handle, 0, TimeToString(TimeCurrent()), sym, "TEST", SymbolInfoDouble(sym, SYMBOL_BID), "Test initialization");
   FileClose(handle);
   
   Print("[CSV OK] Signal de test écrit");
}

void LogSignalToCSV_Simple(const SignalRecord &signal)
{
   if(!csvInitialized || csvSignalsFile == "")
   {
      Print("[CSV WARNING] CSV non initialisé pour signal");
      return;
   }
   
   int handle = FileOpen(csvSignalsFile, FILE_WRITE|FILE_CSV);
   if(handle == INVALID_HANDLE)
   {
      Print("[CSV ERROR] Impossible ouvrir ", csvSignalsFile, " Error: ", GetLastError());
      return;
   }
   
   FileSeek(handle, 0, SEEK_END);
   
   string signalStr = "NONE";
   if(signal.signal == 1) signalStr = "BUY";
   else if(signal.signal == -1) signalStr = "SELL";
   
   FileWrite(handle,
      signalCounter++,
      TimeToString(signal.time, TIME_DATE|TIME_MINUTES),
      signal.symbol,
      signalStr,
      DoubleToString(signal.price, dig),
      signal.reason
   );
   FileClose(handle);
   
   Print("[CSV OK] Signal logué: ", signalStr, " à ", signal.price);
}

void LogTradeToCSV_Simple(const TradeRecord &trade)
{
   if(!csvInitialized || csvTradesFile == "")
   {
      Print("[CSV WARNING] CSV non initialisé pour trade");
      return;
   }
   
   int handle = FileOpen(csvTradesFile, FILE_WRITE|FILE_CSV);
   if(handle == INVALID_HANDLE)
   {
      Print("[CSV ERROR] Impossible ouvrir ", csvTradesFile, " Error: ", GetLastError());
      return;
   }
   
   FileSeek(handle, 0, SEEK_END);
   
   string typeStr = (trade.type == 0) ? "BUY" : "SELL";
   
   FileWrite(handle,
      tradesCounter++,
      TimeToString(trade.openTime, TIME_DATE|TIME_MINUTES),
      trade.symbol,
      typeStr,
      DoubleToString(trade.volume, 2),
      DoubleToString(trade.openPrice, dig),
      DoubleToString(trade.sl, dig),
      DoubleToString(trade.tp, dig),
      DoubleToString(trade.profit, 2),
      trade.comment
   );
   FileClose(handle);
   
   Print("[CSV OK] Trade logué: ", typeStr, " ", trade.volume, " lots à ", trade.openPrice);
}

void ExportFinalStats()
{
   if(!csvInitialized) return;
   
   Print("[CSV DEBUG] Export stats finales...");
   
   int handle = FileOpen(csvStatsFile, FILE_WRITE|FILE_CSV);
   if(handle != INVALID_HANDLE)
   {
      FileWrite(handle, "Metric", "Value");
      FileWrite(handle, "Symbol", sym);
      FileWrite(handle, "Magic", InpMagic);
      FileWrite(handle, "Signals Generated", signalCounter);
      FileWrite(handle, "Trades Logged", tradesCounter);
      FileWrite(handle, "Export Time", TimeToString(TimeCurrent()));
      FileClose(handle);
      
      Print("[CSV OK] Stats exportées: ", csvStatsFile);
   }
   else
   {
      Print("[CSV ERROR] Impossible créer stats file");
   }
}

//======================== FONCTIONS TEMPS & INDICATEURS (SIMPLIFIÉES) ========================
bool IsNewBar()
{
   datetime ct=iTime(sym, InpSignalTF, 0);
   if(ct!=lastBarTime){lastBarTime=ct; return true;}
   return false;
}

bool IsSessionActive()
{
   if(!InpUseSessionFilter) return true;
   
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   
   // Logique session simplifiée
   int hour = dt.hour;
   return (hour >= 6 && hour <= 18); // 6h-18h simple
}

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

//======================== TRADING LOGIC SIMPLIFIÉE ========================
void TryOpenTrade_Debug()
{
   if(!IsSessionActive())
   {
      Print("[DEBUG] Hors session de trading");
      
      // Log signal refusé
      SignalRecord sig;
      sig.time = TimeCurrent();
      sig.symbol = sym;
      sig.signal = 0;
      sig.price = SymbolInfoDouble(sym, SYMBOL_BID);
      sig.reason = "Hors session";
      LogSignalToCSV_Simple(sig);
      return;
   }
   
   // Signal BUY forcé pour test
   double entry = SymbolInfoDouble(sym, SYMBOL_ASK);
   double sl = entry * (1.0 - InpSL_PercentOfPrice/100.0);
   double tp = entry * (1.0 + InpTP_PercentOfPrice/100.0);
   
   // Log signal généré
   SignalRecord sig;
   sig.time = TimeCurrent();
   sig.symbol = sym;
   sig.signal = 1;
   sig.price = entry;
   sig.reason = "Signal test debug";
   LogSignalToCSV_Simple(sig);
   
   // Pas d'ouverture réelle en mode debug, juste logging
   if(InpForceCSVDebug)
   {
      Print("[DEBUG] Mode test - pas d'ouverture réelle");
      
      // Simuler un trade pour CSV
      TradeRecord tr;
      tr.openTime = TimeCurrent();
      tr.symbol = sym;
      tr.type = 0; // BUY
      tr.volume = 0.01;
      tr.openPrice = entry;
      tr.sl = sl;
      tr.tp = tp;
      tr.profit = 0;
      tr.comment = "DEBUG_TEST";
      LogTradeToCSV_Simple(tr);
   }
}

//======================== MAIN FUNCTIONS ========================
void OnTick()
{
   // Vérification mois
   if(!IsTradingMonth(TimeCurrent())) return;
   
   if(!IsNewBar()) return;
   
   // Test CSV à chaque nouvelle barre
   TryOpenTrade_Debug();
}

int OnInit()
{
   Print("[DEBUG] === DÉMARRAGE POSEIDON DEBUG CSV ===");
   
   sym = _Symbol; 
   dig = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS); 
   pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   
   Print("[DEBUG] Symbole: ", sym, " Digits: ", dig);
   
   // Initialisation IMMÉDIATE des CSV
   InitializeCSVFiles_Debug();
   
   // Indicateurs basiques
   hEMA21 = iMA(sym, InpSignalTF, 21, 0, MODE_EMA, PRICE_CLOSE);
   hEMA55 = iMA(sym, InpSignalTF, 55, 0, MODE_EMA, PRICE_CLOSE);
   
   if(hEMA21 == INVALID_HANDLE || hEMA55 == INVALID_HANDLE)
   {
      Print("[ERROR] Indicateurs invalides");
      return INIT_FAILED;
   }
   
   Print("[DEBUG] EA initialisé avec CSV debug activé");
   Print("[DEBUG] Répertoire fichiers: MQL5/Files/");
   Print("[DEBUG] === INITIALISATION TERMINÉE ===");
   
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   Print("[DEBUG] === ARRÊT EA - EXPORT FINAL ===");
   
   ExportFinalStats();
   
   if(hEMA21 != INVALID_HANDLE) IndicatorRelease(hEMA21);
   if(hEMA55 != INVALID_HANDLE) IndicatorRelease(hEMA55);
   
   Print("[DEBUG] Fichiers CSV sauvegardés:");
   Print("- ", csvTradesFile);
   Print("- ", csvSignalsFile);
   Print("- ", csvStatsFile);
   Print("[DEBUG] === ARRÊT TERMINÉ ===");
}
