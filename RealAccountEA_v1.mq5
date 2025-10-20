//+------------------------------------------------------------------+
//| RealAccountEA_v1.mq5                                             |
//| EA para conta real que usa DailyLog_v1, IndicatorSuite_refactored_complete_v9 e LiquidationManager_v1
//+------------------------------------------------------------------+
#property copyright ""
#property version   "1.00"
#property strict
#property description "EA simples para conta real: RSI baseado, usa DailyLog, IndicatorSuite e LiquidationManager"

#include "DailyLog_v1.mqh"
#include "IndicatorSuite_refactored_complete_v9.mqh"
#include "LiquidationManager_v1.mqh"
#include "StopManager_v1.mqh"

//--- input parameters
input ulong   InpMagic = 123456;            // magic number (unique id)
input string  InpSymbols = "WIN@,PETR4@";  // lista de símbolos CSV (use nomes base ou root; resolver será aplicado)
input double  InpRiskPercent = 1.0;         // risco por operação (% do capital líquido disponível)
input int     InpRSIPeriod = 14;            // RSI periodo
input double  InpLotStep = 0.01;            // passo mínimo de volume
input double  InpMinLot = 0.01;             // lote mínimo
//--- modo de leitura dos indicadores: 0=Value, 1=Signal, 2=Score, 3=IsQualified
enum EIndicatorMode { IND_MODE_VALUE=0, IND_MODE_SIGNAL=1, IND_MODE_SCORE=2, IND_MODE_QUALIFIED=3 };
input int     InpIndicatorMode = IND_MODE_SIGNAL; // default: Signal (comportamento atual)
input double  InpScoreThreshold = 5.0; // limiar para considerar Score como sinal positivo
//--- StopManager defaults (pontos)
input double InpDefaultSLPoints = 200.0;
input double InpDefaultTPPoints = 400.0;
input bool   InpBreakevenEnabled = true;
input double InpBreakevenStartPoints = 100.0;
input double InpBreakevenBufferPoints = 2.0;
input bool   InpTrailingEnabled = false;
input double InpTrailingStartPoints = 200.0;
input double InpTrailingStepPoints = 20.0;

//--- objetos principais
CDailyLog_v1      g_log;
CIndicatorManager g_im;
CLiquidationManager g_liq;
CStopManager      g_stops;

string g_symbols[];
int    g_symbols_count = 0;
// removed unused handle

//--- helper: calcula volume baseado em risco
// agora aceita o símbolo como parâmetro (multi-symbol)
// CalcVolumeByRisk: calcula volume (lots) baseado em risco monetário e distância do SL.
// Usa informações do símbolo (tick value/tick size ou contract size) e faz fallback
// para métodos aproximados quando necessário.
double CalcVolumeByRisk(double riskPercent, const string symbol, double stopPoints = -1.0)
{
   double available = g_liq.GetAvailableForTrading();
   if(!MathIsValidNumber(available) || available <= 0.0)
   {
      return 0.0;
   }

   double risk_value = available * (riskPercent / 100.0);
   if(risk_value <= 0.0)
   {
      return 0.0;
   }

   // determina SL em pontos (usar parâmetro ou fallback do input)
   double sl_points = stopPoints;
   if(sl_points <= 0.0)
   {
      sl_points = InpDefaultSLPoints;
   }

   if(sl_points <= 0.0)
   {
      return 0.0;
   }

   double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   double tick_size = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   double tick_value = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   double contract_size = SymbolInfoDouble(symbol, SYMBOL_TRADE_CONTRACT_SIZE);

   if(point <= 0.0)
   {
      return 0.0;
   }

   // fallbacks razoáveis
   if(tick_size <= 0.0)
   {
      tick_size = point;
   }

   // Se não houver tick_value, tentar aproximar com contract_size
   if(tick_value <= 0.0 && contract_size > 0.0)
   {
      // aproximação: valor de 1 point por contrato
      tick_value = point * contract_size;
   }

   double price_move = sl_points * point;
   double ticks = (tick_size > 0.0) ? (price_move / tick_size) : 0.0;
   double loss_per_lot = (ticks > 0.0 && tick_value > 0.0) ? (ticks * tick_value) : 0.0;

   // Se não conseguimos calcular loss_per_lot de forma confiável, tentamos usar OrderCalcMargin
   if(loss_per_lot <= 0.0)
   {
      // tentamos calcular a margem para 1 lote usando OrderCalcMargin
      double test_volume = 1.0;
      // ajustar test_volume para o passo do símbolo
      double vol_step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
      if(vol_step <= 0.0)
      {
         vol_step = InpLotStep;
      }

      // normalizar test_volume para o passo
      test_volume = vol_step;

      double margin = 0.0;
      // Sem OrderCalcMargin disponível nessa build/ambiente, usar estimativa conservadora
      {
         double priceAskTmp = SymbolInfoDouble(symbol, SYMBOL_ASK);
         if(!(MathIsValidNumber(priceAskTmp) && priceAskTmp > 0.0))
         {
            priceAskTmp = SymbolInfoDouble(symbol, SYMBOL_BID);
         }

         if(MathIsValidNumber(priceAskTmp) && priceAskTmp > 0.0)
         {
            margin = test_volume * priceAskTmp;
            loss_per_lot = margin * MathMax(0.001, sl_points/1000.0);
         }
      }
   }

   // Se ainda não conseguimos estimar loss_per_lot, então fazemos fallback para método simples (divisão por preço)
   if(loss_per_lot <= 0.0)
   {
      double price = SymbolInfoDouble(symbol, SYMBOL_ASK);
      if(!MathIsValidNumber(price) || price <= 0.0)
      {
         return 0.0;
      }

      double vol_step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
      double vol_min = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
      if(vol_step <= 0.0)
      {
         vol_step = InpLotStep;
      }

      if(vol_min <= 0.0)
      {
         vol_min = InpMinLot;
      }

      double raw = risk_value / price;
      double steps = MathFloor(raw / vol_step);
      double v = steps * vol_step;
      if(v < vol_min)
      {
         v = vol_min;
      }

      int digits = 0;
      double tmp = vol_step;
      while(MathAbs(tmp - MathRound(tmp)) > 1e-9 && digits < 8)
      {
         tmp *= 10.0;
         digits++;
      }

      return NormalizeDouble(v, digits);
   }

   // cálculo principal: raw_lots = risk / loss_per_lot
   double raw_lots = risk_value / loss_per_lot;

   double vol_step2 = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   double vol_min2 = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   if(vol_step2 <= 0.0)
   {
      vol_step2 = InpLotStep;
   }

   if(vol_min2 <= 0.0)
   {
      vol_min2 = InpMinLot;
   }

   double steps2 = MathFloor(raw_lots / vol_step2);
   double v2 = steps2 * vol_step2;
   if(v2 < vol_min2)
   {
      v2 = vol_min2;
   }

   // Garantir que o volume cabe na margem disponível (usa OrderCalcMargin)
   double price_for_margin = SymbolInfoDouble(symbol, SYMBOL_ASK);
   if(!(MathIsValidNumber(price_for_margin) && price_for_margin > 0.0))
   {
      price_for_margin = SymbolInfoDouble(symbol, SYMBOL_BID);
   }

   double available_margin = g_liq.GetRealTimeAvailableMargin();

   int safety = 0;
   while(v2 >= vol_min2 && safety < 200)
   {
      double margin_required = 0.0;
      // tenta calcular margem para tipo BUY (a margem é similar por direção para muitos símbolos)
      {
         // Estimativa conservadora de margem: volume * price
         double tmpMarginReq = v2 * price_for_margin;
         if(!(MathIsValidNumber(tmpMarginReq) && tmpMarginReq > 0.0))
         {
            break;
         }

         margin_required = tmpMarginReq;
      }

      if(margin_required <= available_margin)
      {
         // OK: cabe na margem
         break;
      }

      // reduz um passo e re-testa
      v2 -= vol_step2;
      if(v2 < vol_min2)
      {
         v2 = 0.0;
         break;
      }

      safety++;
   }

   if(v2 <= 0.0)
   {
      return 0.0;
   }

   int digits2 = 0;
   double tmp2 = vol_step2;
   while(MathAbs(tmp2 - MathRound(tmp2)) > 1e-9 && digits2 < 8)
   {
      tmp2 *= 10.0;
      digits2++;
   }

   return NormalizeDouble(v2, digits2);
}

//--- inicializa indicadores e managers
int OnInit()
{
   // Init log com magic number
   g_log.InitLog((long)InpMagic, true, 8, 30, true);
   g_log.Logs(true, true, "EA inicializando: ", MQLInfoString(MQL_PROGRAM_NAME));

   // Inspecionar inputs e dumpar
   CInputInspector inspector;
   inspector.SetLog(g_log);
   // adicionar inputs (tipo, nome, valor)
   inspector.Add("ulong", "InpMagic", (string)InpMagic);
   inspector.Add("string", "InpSymbols", InpSymbols);
   inspector.Add("double", "InpRiskPercent", DoubleToString(InpRiskPercent, 6));
   inspector.Add("int", "InpRSIPeriod", IntegerToString(InpRSIPeriod));
   inspector.Add("double", "InpLotStep", DoubleToString(InpLotStep, 6));
   inspector.Add("double", "InpMinLot", DoubleToString(InpMinLot, 6));
   inspector.Add("int", "InpIndicatorMode", IntegerToString(InpIndicatorMode));
   inspector.Add("double", "InpScoreThreshold", DoubleToString(InpScoreThreshold, 6));
   inspector.Add("double", "InpDefaultSLPoints", DoubleToString(InpDefaultSLPoints, 6));
   inspector.Add("double", "InpDefaultTPPoints", DoubleToString(InpDefaultTPPoints, 6));
   inspector.Add("bool", "InpBreakevenEnabled", (InpBreakevenEnabled?"true":"false"));
   inspector.Add("double","InpBreakevenStartPoints", DoubleToString(InpBreakevenStartPoints,6));
   inspector.Add("double","InpBreakevenBufferPoints", DoubleToString(InpBreakevenBufferPoints,6));
   inspector.Add("bool","InpTrailingEnabled", (InpTrailingEnabled?"true":"false"));
   inspector.Add("double","InpTrailingStartPoints", DoubleToString(InpTrailingStartPoints,6));
   inspector.Add("double","InpTrailingStepPoints", DoubleToString(InpTrailingStepPoints,6));

   inspector.Dump();

   // set log para outros módulos
   g_im.SetLog(g_log);
   g_liq.SetLog(g_log);
   g_stops.SetLog(g_log);
   g_stops.SetDefault(InpDefaultSLPoints, InpDefaultTPPoints, InpBreakevenEnabled, InpBreakevenStartPoints, InpBreakevenBufferPoints, InpTrailingEnabled, InpTrailingStartPoints, InpTrailingStepPoints);
   g_stops.Init();

   // --- processar lista de símbolos informada por input
   string tmp[];
   _SplitCSV(InpSymbols, tmp);
   ArrayResize(g_symbols, 0);
   for(int i=0;i<ArraySize(tmp);i++){
      int n=ArraySize(g_symbols); ArrayResize(g_symbols,n+1); g_symbols[n]=tmp[i];
   }
   g_symbols_count = ArraySize(g_symbols);
   if(g_symbols_count==0) { g_log.Logs(true,true,"Nenhum símbolo especificado em InpSymbols. Uso: CSV de símbolos."); }

   // Configura symbols no indicator manager (ele resolve futuros internamente)
   string allcsv = InpSymbols; // CIndicatorManager espera SetSymbols(csv)
   g_im.SetSymbols(allcsv);

   // criar 3 instâncias para cada indicador por símbolo: 30min, 1h, 1d
   ENUM_TIMEFRAMES tfs[3]; tfs[0]=PERIOD_M30; tfs[1]=PERIOD_H1; tfs[2]=PERIOD_D1;

   // 1) RSI instâncias
   for(int s=0;s<g_symbols_count;s++){
      string sym = g_symbols[s];
      for(int i=0;i<3;i++){
         string name = MakeIndicatorName("RSI_", (int)tfs[i], sym);
         bool ok = g_im.AddRSI(sym, name, tfs[i], InpRSIPeriod, PRICE_CLOSE);
         if(!ok) { g_log.Logs(true,true,"Falha ao criar RSI: ", name); }
         g_im.SetRule(name, 30.0, 70.0);
      }
   }

   // 2) MACD instâncias (fast=12, slow=26, signal=9)
   for(int s=0;s<g_symbols_count;s++){
      string sym = g_symbols[s];
      for(int i=0;i<3;i++){
         string name = MakeIndicatorName("MACD_", (int)tfs[i], sym);
         bool ok = g_im.AddMACD(sym, name, tfs[i], 12, 26, 9, PRICE_CLOSE);
         if(!ok) { g_log.Logs(true,true,"Falha ao criar MACD: ", name); }
         g_im.SetRule(name, 0.0, 0.0);
      }
   }

   // 3) CCI instâncias (period=20)
   for(int s=0;s<g_symbols_count;s++){
      string sym = g_symbols[s];
      for(int i=0;i<3;i++){
         string name = MakeIndicatorName("CCI_", (int)tfs[i], sym);
         bool ok = g_im.AddCCI(sym, name, tfs[i], 20, PRICE_TYPICAL);
         if(!ok) { g_log.Logs(true,true,"Falha ao criar CCI: ", name); }
         g_im.SetRule(name, 100.0, -100.0);
      }
   }

   // iniciar treinadores e store (cria CSignalTrainer por indicador)
   g_im.Init();

   g_log.Logs(true, true, "OnInit concluido.");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   g_log.Logs(true, true, "OnDeinit: reason=", IntegerToString(reason));
   g_stops.Deinit();
   g_log.CloseLog();
}

//--- OnTradeTransaction para capturar execuções e alimentar LiquidationManager
void OnTradeTransaction(const MqlTradeTransaction &trans, const MqlTradeRequest &request, const MqlTradeResult &result)
{
   // encaminha para o gestor de liquidação
   g_liq.OnTradeTransaction(trans, request, result);
}

//--- Verifica se trades são permitidos (conta real segura)
bool CanTrade()
{
   if(MQLInfoInteger(MQL_TESTER) || MQLInfoInteger(MQL_OPTIMIZATION)) { return false; }
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED)) { return false; }
   return true;
}

//--- Tenta abrir ordem de mercado (market)
// agora recebe símbolo alvo
bool OpenMarketOrder(int type, double volume, const string symbol)
{
   if(!CanTrade()) { g_log.Logs(true, true, "OpenMarketOrder: trade não permitido"); return false; }
   
   double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   if(!MathIsValidNumber(bid) || bid<=0) { g_log.Logs(true,true,"OpenMarketOrder: preço inválido para ", symbol); return false; }
   // calcular margem requerida para este volume
   double price_for_margin = (type==0) ? SymbolInfoDouble(symbol, SYMBOL_ASK) : SymbolInfoDouble(symbol, SYMBOL_BID);
   if(!(MathIsValidNumber(price_for_margin) && price_for_margin > 0.0)) price_for_margin = SymbolInfoDouble(symbol, SYMBOL_ASK);
   double required_margin = 0.0;
   {
      // Estimativa conservadora de margem: usar volume * price
      double tmpReq = volume * price_for_margin;
      if(MathIsValidNumber(tmpReq) && tmpReq > 0.0) required_margin = tmpReq;
      else required_margin = volume * bid;
   }

   if(!g_liq.CanOpenPosition(required_margin)) {
      g_log.Logs(true, true, "OpenMarketOrder: margem insuficiente para ", symbol, " vol=", DoubleToString(volume,2), " required_margin=", DoubleToString(required_margin,2));
      return false;
   }

   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);
   req.action = TRADE_ACTION_DEAL;
   req.symbol = symbol;
   req.volume = volume;
   req.deviation = 10;
   req.magic = InpMagic;
   req.type = (ENUM_ORDER_TYPE) (type==0? ORDER_TYPE_BUY : ORDER_TYPE_SELL);

   if(type==0) { req.price = SymbolInfoDouble(symbol, SYMBOL_ASK); }
   else { req.price = SymbolInfoDouble(symbol, SYMBOL_BID); }

   if(!OrderSend(req, res)) {
      g_log.Logs(true, true, "OrderSend falhou: retcode=", IntegerToString(res.retcode), " symbol=", symbol);
      return false;
   }

   // Se OrderSend retornou com sucesso, registrar operação imediatamente no LiquidationManager
   // res.retcode pode indicar execução dependendo do broker; registramos para minimizar janela sem registro.
   // Registrar operação quando o resultado indica ordem executada/aceita
   if(res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_PLACED)
   {
      int opType = (type == 0) ? 0 : 1;
      g_liq.RegisterOperation(symbol, volume, req.price, opType);
   }

   g_log.Logs(true, true, "Ordem enviada: ", (type==0?"BUY":"SELL"), " ", symbol, " vol=", DoubleToString(volume,2), " price=", DoubleToString(req.price,_Digits));
   return true;
}

//--- OnTick: lógica principal (leitura RSI, decisão, gestão de posições)
void OnTick()
{
   // indicadores são atualizados por símbolo no loop abaixo

   // Para cada símbolo configurado: agrega sinais dos 9 indicadores e toma ação
   ENUM_TIMEFRAMES tfs[3]; tfs[0]=PERIOD_M30; tfs[1]=PERIOD_H1; tfs[2]=PERIOD_D1;
   for(int sidx=0; sidx<g_symbols_count; sidx++){
      string sym = g_symbols[sidx];
      // atualiza indicadores para este símbolo
      g_im.TickSymbol(sym);

      string names[9]; int idx=0;
      for(int r=0;r<3;r++){
         for(int j=0;j<3;j++){
            if(r==0) { names[idx] = "RSI_" + IntegerToString((int)tfs[j]) + "@" + sym; }
            else if(r==1) { names[idx] = "MACD_" + IntegerToString((int)tfs[j]) + "@" + sym; }
            else { names[idx] = "CCI_" + IntegerToString((int)tfs[j]) + "@" + sym; }
            idx++;
         }
      }

      int total_positive = 0; int total_negative = 0; int total_valid = 0;
      for(int i=0;i<9;i++){
         double val = g_im.Value(names[i]);
         if(!MathIsValidNumber(val)) { continue; }
         int contrib = 0;
         // selecionar modo de indicador
         if(InpIndicatorMode == IND_MODE_SIGNAL) {
            int s = g_im.Signal(names[i]);
            if(s>0) { contrib = +1; }
            else if(s<0) { contrib = -1; }
         }
         else if(InpIndicatorMode == IND_MODE_VALUE) {
            // usar regras já definidas (CRuleBook) aplicando ao valor bruto
            int s = g_im.Signal(names[i]);
            if(s>0) { contrib = +1; }
            else if(s<0) { contrib = -1; }
         }
         else if(InpIndicatorMode == IND_MODE_SCORE) {
            double sc = g_im.Score(names[i]);
            if(!MathIsValidNumber(sc)) { contrib = 0; }
            else {
               if(sc >= InpScoreThreshold) { contrib = +1; }
               else { contrib = 0; }
            }
         }
         else if(InpIndicatorMode == IND_MODE_QUALIFIED) {
            bool q = g_im.IsQualified(names[i]);
            if(q) { contrib = +1; }
            else { contrib = 0; }
         }

         if(contrib > 0) { total_positive++; }
         else if(contrib < 0) { total_negative++; }
         total_valid++;
      }

   if(total_valid==0) { continue; }

      int sig = 0;
   if(total_positive > total_negative) { sig = +1; }
   else if(total_negative > total_positive) { sig = -1; }

      // checa posições existentes para o símbolo
      int total_pos = PositionsTotal();
      int pos_dir = 0; // 0 nenhum, +1 buy, -1 sell
      double pos_volume = 0.0;
      for(int i=0;i<total_pos;i++){
         ulong pticket = PositionGetTicket(i);
         if(pticket == 0) { continue; }
         if(!PositionSelectByTicket(pticket)) { continue; }
         string psym = PositionGetString(POSITION_SYMBOL);
         if(psym != sym) { continue; }
         long ptype = PositionGetInteger(POSITION_TYPE);
         double pvol = PositionGetDouble(POSITION_VOLUME);
         pos_volume += pvol;
         if(ptype == POSITION_TYPE_BUY) { pos_dir = +1; }
         else if(ptype == POSITION_TYPE_SELL) { pos_dir = -1; }
      }


      // decisões básicas por maioria para este símbolo:
         if(sig > 0 && pos_dir <= 0) {
            double vol = CalcVolumeByRisk(InpRiskPercent, sym);
            if(vol > 0) {
               OpenMarketOrder(0, vol, sym);
            }
         }
         else if(sig < 0 && pos_dir >= 0) {
            double vol = CalcVolumeByRisk(InpRiskPercent, sym);
            if(vol > 0) {
               OpenMarketOrder(1, vol, sym);
            }
         }
      // log por símbolo
      g_log.ChartLogAdd(sym + " p+=" + IntegerToString(total_positive) + " p-=" + IntegerToString(total_negative));
   } // fim loop symbols

   // ajustar stops/trailing/breakeven nas posições existentes
   g_stops.OnTick();
}

//+------------------------------------------------------------------+