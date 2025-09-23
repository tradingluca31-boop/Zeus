//+------------------------------------------------------------------+
//| Claude V2 - FIXED CSV EXPORT                                    |
//| Version corrigée avec export CSV forcé                          |
//+------------------------------------------------------------------+

#property copyright "tradingluca31-boop"
#property link      "https://github.com/tradingluca31-boop"
#property version   "2.1"

// Import des fonctions pour forcer l'export
#include <Trade\Trade.mqh>

// Parameters
input int InpMagic = 31031995;
input bool InpForceCSVExport = true;  // Force CSV export

// Variables globales pour tracking
datetime last_export_time = 0;
bool csv_exported = false;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    Print("Claude V2 Fixed - Initialisation avec export CSV forcé");
    csv_exported = false;
    last_export_time = 0;
    return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    Print("OnDeinit appelé, raison: ", reason);

    // FORCER l'export CSV à chaque deinit
    if(InpForceCSVExport)
    {
        Print("Force export CSV...");
        ExportTradeHistoryCSVForced();
    }
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    // Votre logique de trading ici

    // Vérifier périodiquement si on doit exporter
    if(InpForceCSVExport && TimeCurrent() - last_export_time > 3600) // Chaque heure
    {
        CheckAndExportCSV();
        last_export_time = TimeCurrent();
    }
}

//+------------------------------------------------------------------+
//| Tester function - CRITIQUE pour backtests                       |
//+------------------------------------------------------------------+
double OnTester()
{
    Print("OnTester() - Fin de backtest détectée");

    // FORCER l'export CSV
    ExportTradeHistoryCSVForced();

    // Retourner une métrique (par exemple profit factor)
    return TesterStatistics(STAT_PROFIT_FACTOR);
}

//+------------------------------------------------------------------+
//| Tester Deinit - CRITIQUE pour optimisations                     |
//+------------------------------------------------------------------+
void OnTesterDeinit()
{
    Print("OnTesterDeinit() - Fin d'optimisation détectée");

    // FORCER l'export CSV
    ExportTradeHistoryCSVForced();
}

//+------------------------------------------------------------------+
//| Fonction d'export CSV améliorée et forcée                       |
//+------------------------------------------------------------------+
void ExportTradeHistoryCSVForced()
{
    Print("=== DÉBUT EXPORT CSV FORCÉ ===");

    // Sélectionner TOUT l'historique
    datetime from = StringToTime("2020.01.01");
    datetime to = TimeCurrent() + 86400; // +1 jour

    if(!HistorySelect(from, to))
    {
        Print("ERREUR: HistorySelect a échoué");
        return;
    }

    int total_deals = HistoryDealsTotal();
    Print("Nombre total de deals trouvés: ", total_deals);

    if(total_deals == 0)
    {
        Print("ATTENTION: Aucun deal trouvé dans l'historique");
        return;
    }

    // Créer nom de fichier unique avec timestamp
    string timestamp = TimeToString(TimeCurrent(), TIME_DATE | TIME_SECONDS);
    StringReplace(timestamp, ":", "");
    StringReplace(timestamp, " ", "_");
    StringReplace(timestamp, ".", "");

    string symbol_clean = Symbol();
    StringReplace(symbol_clean, ".", "");

    string file_name = StringFormat("CLAUDE_V2_%s_%s_M%d.csv",
                                   symbol_clean, timestamp, InpMagic);

    Print("Tentative création fichier: ", file_name);

    // STRATÉGIE 1: FILE_COMMON (dossier partagé)
    int file_handle = FileOpen(file_name, FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_COMMON, 0, CP_UTF8);
    string export_path = "FILE_COMMON";

    if(file_handle == INVALID_HANDLE)
    {
        Print("Échec FILE_COMMON, essai FILE_LOCAL...");

        // STRATÉGIE 2: Sans FILE_COMMON
        file_handle = FileOpen(file_name, FILE_WRITE | FILE_CSV | FILE_ANSI, 0, CP_UTF8);
        export_path = "FILE_LOCAL";
    }

    if(file_handle == INVALID_HANDLE)
    {
        Print("ERREUR CRITIQUE: Impossible de créer le fichier CSV");
        Print("Erreur: ", GetLastError());
        return;
    }

    Print("SUCCESS: Fichier ouvert avec ", export_path);

    // En-têtes CSV
    string header = "Ticket,Symbol,Type,Volume,OpenTime,OpenPrice,CloseTime,ClosePrice,Profit,Commission,Swap,Comment";
    FileWrite(file_handle, header);

    int exported_count = 0;

    // Exporter TOUS les deals
    for(int i = 0; i < total_deals; i++)
    {
        ulong deal_ticket = HistoryDealGetTicket(i);

        if(deal_ticket > 0)
        {
            // Filtrer par Magic Number si spécifié
            if(InpMagic > 0)
            {
                long deal_magic = HistoryDealGetInteger(deal_ticket, DEAL_MAGIC);
                if(deal_magic != InpMagic)
                    continue;
            }

            // Récupérer les données du deal
            string deal_symbol = HistoryDealGetString(deal_ticket, DEAL_SYMBOL);
            long deal_type = HistoryDealGetInteger(deal_ticket, DEAL_TYPE);
            double deal_volume = HistoryDealGetDouble(deal_ticket, DEAL_VOLUME);
            datetime deal_time = (datetime)HistoryDealGetInteger(deal_ticket, DEAL_TIME);
            double deal_price = HistoryDealGetDouble(deal_ticket, DEAL_PRICE);
            double deal_profit = HistoryDealGetDouble(deal_ticket, DEAL_PROFIT);
            double deal_commission = HistoryDealGetDouble(deal_ticket, DEAL_COMMISSION);
            double deal_swap = HistoryDealGetDouble(deal_ticket, DEAL_SWAP);
            string deal_comment = HistoryDealGetString(deal_ticket, DEAL_COMMENT);

            // Formatage de la ligne CSV
            string csv_line = StringFormat("%d,%s,%d,%.2f,%s,%.5f,%s,%.5f,%.2f,%.2f,%.2f,%s",
                                         deal_ticket,
                                         deal_symbol,
                                         deal_type,
                                         deal_volume,
                                         TimeToString(deal_time, TIME_DATE | TIME_SECONDS),
                                         deal_price,
                                         TimeToString(deal_time, TIME_DATE | TIME_SECONDS), // Close = Open pour deals
                                         deal_price,
                                         deal_profit,
                                         deal_commission,
                                         deal_swap,
                                         deal_comment);

            FileWrite(file_handle, csv_line);
            exported_count++;
        }
    }

    FileClose(file_handle);

    Print("=== EXPORT CSV TERMINÉ ===");
    Print("Fichier créé: ", file_name);
    Print("Localisation: ", export_path);
    Print("Deals exportés: ", exported_count, "/", total_deals);
    Print("Magic Number: ", InpMagic);

    // Marquer comme exporté
    csv_exported = true;

    // NOTIFICATION CRITIQUE
    Alert("CSV EXPORTÉ: ", file_name, " (", exported_count, " deals)");
}

//+------------------------------------------------------------------+
//| Vérification périodique et export                               |
//+------------------------------------------------------------------+
void CheckAndExportCSV()
{
    static datetime last_check = 0;

    if(TimeCurrent() - last_check < 300) // Éviter les exports trop fréquents
        return;

    last_check = TimeCurrent();

    // Vérifier s'il y a de nouveaux trades
    int current_deals = HistoryDealsTotal();
    static int last_deals_count = 0;

    if(current_deals > last_deals_count)
    {
        Print("Nouveaux deals détectés: ", current_deals - last_deals_count);
        ExportTradeHistoryCSVForced();
        last_deals_count = current_deals;
    }
}

//+------------------------------------------------------------------+
//| FONCTIONS DE DEBUG                                              |
//+------------------------------------------------------------------+
void DebugFileSystem()
{
    Print("=== DEBUG FILESYSTEM ===");
    Print("TerminalInfoString(TERMINAL_DATA_PATH): ", TerminalInfoString(TERMINAL_DATA_PATH));
    Print("TerminalInfoString(TERMINAL_COMMON_DATA_PATH): ", TerminalInfoString(TERMINAL_COMMON_DATA_PATH));

    // Test création fichier simple
    string test_file = "test_" + IntegerToString(GetTickCount()) + ".txt";
    int test_handle = FileOpen(test_file, FILE_WRITE | FILE_TXT | FILE_COMMON);

    if(test_handle != INVALID_HANDLE)
    {
        FileWrite(test_handle, "Test réussi");
        FileClose(test_handle);
        Print("Test FILE_COMMON: SUCCESS");
    }
    else
    {
        Print("Test FILE_COMMON: FAILED, erreur: ", GetLastError());
    }
}