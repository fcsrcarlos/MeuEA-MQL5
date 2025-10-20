//=====================================================================
// StopManager_v1.mqh
// Nota de teste: comentário adicionado automaticamente para verificar compilação via script
// Gerencia Stop Loss, Take Profit, Breakeven e Trailing por símbolo
// Projetado para uso com RealAccountEA_v1.mq5
//=====================================================================
#ifndef __STOP_MANAGER_V1_MQH__
#define __STOP_MANAGER_V1_MQH__
#property strict

#include "DailyLog_v1.mqh"

// Convenções:
// - Todos os pontos referem-se a "points" do símbolo (SYMBOL_POINT)
// - SL/TP calculados em preço absoluto com base em price +/- points*SYMBOL_POINT

struct SStopCfg
{
   string symbol;
   double sl_points;                 // distância do stop em pontos
   double tp_points;                 // distância do take em pontos
   int    mode;                      // 0=tick,1=atr (expandible)
   int    atr_period;                // período do ATR quando mode==atr
   double atr_mult;                  // multiplicador do ATR
   // MA-based stop params
   int    ma_period;                 // período da MA quando mode==ma
   int    ma_method;                 // método MA (MODE_SMA, MODE_EMA, ...)
   int    ma_shift;                  // shift da MA
   double ma_offset_points;         // deslocamento em pontos em relação à MA (SL = MA - offset para buy)
   bool   breakeven_enabled;         // ativar breakeven automático
   double breakeven_start_points;    // quando lucro em pontos >= este valor, mover SL para breakeven
   double breakeven_buffer_points;   // buffer acima do preço de entrada (pontos)
   bool   trailing_enabled;          // ativar trailing
   double trailing_start_points;     // começar trailing quando lucro atingir estes pontos
   double trailing_step_points;      // passo do trailing (mover SL a cada X pontos)
   int    atr_handle;                // indicator handle para ATR (INVALID_HANDLE quando não criado)
   int    ma_handle;                 // indicator handle para MA (INVALID_HANDLE quando não criado)
   int    atr_create_attempts;       // número de tentativas já efetuadas para criar handle ATR
   int    ma_create_attempts;        // número de tentativas já efetuadas para criar handle MA
};

enum EStopMode { SM_TICK=0, SM_ATR=1, SM_MA=2 };

class CStopManager
{
private:
   SStopCfg m_cfg[];
   SStopCfg m_default;
   CDailyLog_v1 *m_log;
   string m_name;

   void Log(const string &s)
   {
      if(m_log != NULL)
      {
         (*m_log).Logs(true, true, "[StopM] ", s);
      }
   }

   int FindConfigIndex(const string symbol)
   {
      for(int i=0;i<ArraySize(m_cfg);i++)
      {
         if(m_cfg[i].symbol == symbol)
         {
            return i;
         }
      }
      return -1;
   }

   // devolve o cfg aplicável (por símbolo ou default)
   SStopCfg GetConfig(const string symbol)
   {
      int idx = FindConfigIndex(symbol);
      if(idx >= 0)
      {
         return m_cfg[idx];
      }
      return m_default;
   }

   // converte pontos (inteiros) para preço (double) e normaliza conforme digitos do símbolo
   double PointsToPrice(const string symbol, const double points, const int dir)
   {
      double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
      if(!MathIsValidNumber(point) || point <= 0) { return 0.0; }
      double price = 0.0;
      if(dir > 0) // buy direction addition (e.g. TP)
      {
         price = SymbolInfoDouble(symbol, SYMBOL_ASK) + points * point;
      }
      else // sell direction subtraction (e.g. TP for sell)
      {
         price = SymbolInfoDouble(symbol, SYMBOL_BID) - points * point;
      }
      int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
      return NormalizeDouble(price, digits);
   }

   double PriceFromEntryByPoints(const string symbol, const double entry_price, const double points, const int dir)
   {
      double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
      if(!MathIsValidNumber(point) || point <= 0) { return 0.0; }
      double price = entry_price + dir * points * point;
      int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
      return NormalizeDouble(price, digits);
   }

   double EnsureMinimalDistance(const string symbol, const double price, const int dir)
   {
      // garante que o SL/TP respeite SYMBOL_TRADE_STOPS_LEVEL (distância mínima em pontos)
      long min_level = (long)SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
      double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
      if(min_level < 0) { min_level = 0; }
      double min_distance = min_level * point;
      double current_price = (dir > 0 ? SymbolInfoDouble(symbol, SYMBOL_BID) : SymbolInfoDouble(symbol, SYMBOL_ASK));
      if(min_distance <= 0) { return price; }
      if(dir > 0)
      {
         if((current_price - price) < min_distance)
         {
            // move stop further away
            double adj = current_price - min_distance;
            int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
            return NormalizeDouble(adj, digits);
         }
      }
      else
      {
         if((price - current_price) < min_distance)
         {
            double adj = current_price + min_distance;
            int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
            return NormalizeDouble(adj, digits);
         }
      }
      return price;
   }

   // modifica SL/TP da posição (usa TRADE_ACTION_SLTP com position ticket)
   bool ModifyPositionStops(const ulong position_ticket, const string symbol, const double new_sl, const double new_tp)
   {
         MqlTradeRequest req;
         MqlTradeResult  res;

         int attempts = 0;
         while(attempts < 10)
         {
            // refresh position before each attempt
            if(!PositionSelectByTicket(position_ticket))
            {
               Log(StringFormat("ModifyPositionStops: position not found ticket=%I64u on attempt=%d", position_ticket, attempts+1));
               return false; // position no longer exists
            }

            ZeroMemory(req);
            ZeroMemory(res);
            req.action = TRADE_ACTION_SLTP;
            req.position = position_ticket;
            req.symbol = symbol;
            req.sl = new_sl;
            req.tp = new_tp;
            req.magic = 0;

            if(OrderSend(req, res))
            {
               if((int)res.retcode == TRADE_RETCODE_DONE)
               {
                  Log(StringFormat("ModifyPositionStops OK ticket=%I64u sl=%.5f tp=%.5f", position_ticket, new_sl, new_tp));
                  return true;
               }
               else
               {
                  Log(StringFormat("ModifyPositionStops attempt=%d ticket=%I64u ret=%d comment=%s", attempts+1, position_ticket, (int)res.retcode, res.comment));
               }
            }
            else
            {
               Log(StringFormat("ModifyPositionStops OrderSend falhou tentativa=%d ticket=%I64u", attempts+1, position_ticket));
            }

            attempts++;
            Sleep(200);
         }

         Log(StringFormat("ModifyPositionStops FAIL after retries ticket=%I64u", position_ticket));
         return false;
   }

public:
   CStopManager()
   {
      ArrayResize(m_cfg,0);
      m_log = NULL;
      m_name = "StopManager_v1";
      // defaults sensatos (podem ser sobrescritos)
      m_default.sl_points = 200.0; // 200 points
      m_default.tp_points = 400.0; // 400 points
      m_default.breakeven_enabled = true;
      m_default.breakeven_start_points = 100.0;
      m_default.breakeven_buffer_points = 2.0;
      m_default.trailing_enabled = false;
      m_default.trailing_start_points = 200.0;
      m_default.trailing_step_points = 20.0;
      m_default.symbol = "";
   m_default.mode = SM_TICK;
   m_default.atr_period = 14;
   m_default.atr_mult = 1.5;
   m_default.atr_handle = INVALID_HANDLE;
   m_default.atr_create_attempts = 0;
   // MA defaults
   m_default.ma_period = 50;
   m_default.ma_method = MODE_EMA;
   m_default.ma_shift = 0;
   m_default.ma_offset_points = 0.0;
   m_default.ma_handle = INVALID_HANDLE;
      m_default.ma_create_attempts = 0;
   }

   void SetLog(CDailyLog_v1 &logRef)
   {
      m_log = &logRef;
   }

   void SetDefault(const double sl_points, const double tp_points, const bool breakeven_enabled, const double breakeven_start_points, const double breakeven_buffer_points, const bool trailing_enabled, const double trailing_start_points, const double trailing_step_points)
   {
      m_default.sl_points = sl_points;
      m_default.tp_points = tp_points;
      m_default.breakeven_enabled = breakeven_enabled;
      m_default.breakeven_start_points = breakeven_start_points;
      m_default.breakeven_buffer_points = breakeven_buffer_points;
      m_default.trailing_enabled = trailing_enabled;
      m_default.trailing_start_points = trailing_start_points;
      m_default.trailing_step_points = trailing_step_points;
   }

   void SetSymbolConfig(const string symbol, const double sl_points, const double tp_points, const bool breakeven_enabled, const double breakeven_start_points, const double breakeven_buffer_points, const bool trailing_enabled, const double trailing_start_points, const double trailing_step_points)
   {
      int idx = FindConfigIndex(symbol);
      SStopCfg cfg;
      cfg.symbol = symbol;
      cfg.sl_points = sl_points;
      cfg.tp_points = tp_points;
      cfg.mode = m_default.mode;
      cfg.atr_period = m_default.atr_period;
      cfg.atr_mult = m_default.atr_mult;
      cfg.atr_handle = INVALID_HANDLE;
      cfg.ma_period = m_default.ma_period;
      cfg.ma_method = m_default.ma_method;
      cfg.ma_shift = m_default.ma_shift;
      cfg.ma_offset_points = m_default.ma_offset_points;
      cfg.ma_handle = INVALID_HANDLE;
   cfg.atr_create_attempts = 0;
   cfg.ma_create_attempts = 0;
      cfg.breakeven_enabled = breakeven_enabled;
      cfg.breakeven_start_points = breakeven_start_points;
      cfg.breakeven_buffer_points = breakeven_buffer_points;
      cfg.trailing_enabled = trailing_enabled;
      cfg.trailing_start_points = trailing_start_points;
      cfg.trailing_step_points = trailing_step_points;
      if(idx >= 0)
      {
         m_cfg[idx] = cfg;
      }
      else
      {
         int n = ArraySize(m_cfg);
         ArrayResize(m_cfg, n+1);
         m_cfg[n] = cfg;
      }
   }

   // define modo de stop para um símbolo (por ex. ATR)
   void SetSymbolMode(const string symbol, const int mode, const int atr_period=14, const double atr_mult=1.5, const int ma_period=50, const int ma_method=MODE_EMA, const int ma_shift=0, const double ma_offset_points=0.0)
   {
      int idx = FindConfigIndex(symbol);
      if(idx < 0)
      {
         SStopCfg cfg; cfg.symbol = symbol; cfg.sl_points = m_default.sl_points; cfg.tp_points = m_default.tp_points; cfg.breakeven_enabled = m_default.breakeven_enabled; cfg.breakeven_start_points = m_default.breakeven_start_points; cfg.breakeven_buffer_points = m_default.breakeven_buffer_points; cfg.trailing_enabled = m_default.trailing_enabled; cfg.trailing_start_points = m_default.trailing_start_points; cfg.trailing_step_points = m_default.trailing_step_points; cfg.atr_handle = INVALID_HANDLE; cfg.ma_handle = INVALID_HANDLE; cfg.ma_period = m_default.ma_period; cfg.ma_method = m_default.ma_method; cfg.ma_shift = m_default.ma_shift; cfg.ma_offset_points = m_default.ma_offset_points; int n=ArraySize(m_cfg); ArrayResize(m_cfg,n+1); m_cfg[n]=cfg; idx = n;
      }
      m_cfg[idx].mode = mode;
      m_cfg[idx].atr_period = atr_period;
      m_cfg[idx].atr_mult = atr_mult;
      m_cfg[idx].atr_handle = INVALID_HANDLE;
   m_cfg[idx].atr_create_attempts = 0;
      m_cfg[idx].ma_period = ma_period;
      m_cfg[idx].ma_method = ma_method;
      m_cfg[idx].ma_shift = ma_shift;
      m_cfg[idx].ma_offset_points = ma_offset_points;
      m_cfg[idx].ma_handle = INVALID_HANDLE;
   m_cfg[idx].ma_create_attempts = 0;
   }

   // trim simples (remove espaços e tabs nas pontas)
   string Trim(const string src)
   {
      int len = StringLen(src);
      if(len == 0) return src;
      int i = 0; int j = len - 1;
      while(i <= j)
      {
         int c = StringGetCharacter(src, i);
         if(c == 32 || c == 9) i++; else break;
      }
      while(j >= i)
      {
         int c = StringGetCharacter(src, j);
         if(c == 32 || c == 9) j--; else break;
      }
      if(i == 0 && j == len-1) return src;
      if(i > j) return "";
      return StringSubstr(src, i, j - i + 1);
   }

   // Popular m_cfg[] a partir de uma string CSV de símbolos.
   // Não cria handles aqui: Init() continuará criando handles persistentes conforme o mode de cada cfg.
   // optional_mode: se >=0, aplica esse modo a todos os símbolos; caso contrário usa m_default.mode
   void PopulateFromCSV(const string symbols_csv, const int optional_mode = -1)
   {
      // limpa configs anteriores
      ClearSymbolConfigs();
      if(StringLen(symbols_csv) == 0) return;
      string parts[];
      int cnt = StringSplit(symbols_csv, ',', parts);
      for(int k = 0; k < cnt; k++)
      {
         string s = Trim(parts[k]);
         if(StringLen(s) == 0) continue;
         // cria cfg com defaults
         SetSymbolConfig(s, m_default.sl_points, m_default.tp_points, m_default.breakeven_enabled, m_default.breakeven_start_points, m_default.breakeven_buffer_points, m_default.trailing_enabled, m_default.trailing_start_points, m_default.trailing_step_points);
         if(optional_mode >= 0)
         {
            SetSymbolMode(s, optional_mode, m_default.atr_period, m_default.atr_mult, m_default.ma_period, m_default.ma_method, m_default.ma_shift, m_default.ma_offset_points);
         }
      }
   }

   // inicializa recursos (chamar em OnInit do EA)
   void Init()
   {
      // cria handles persistentes no OnInit para os modos configurados
      for(int i=0;i<ArraySize(m_cfg);i++)
      {
         // ATR handle
         if(m_cfg[i].mode == SM_ATR)
         {
            int attempts = 0;
            while(attempts < 10 && m_cfg[i].atr_handle == INVALID_HANDLE)
            {
               ENUM_TIMEFRAMES tf = (ENUM_TIMEFRAMES)Period();
               int h = iATR(m_cfg[i].symbol, tf, m_cfg[i].atr_period);
               if(h != INVALID_HANDLE)
               {
                  m_cfg[i].atr_handle = h;
                  break;
               }
               attempts++;
               Sleep(50);
            }
            m_cfg[i].atr_create_attempts = attempts;
            if(m_cfg[i].atr_handle == INVALID_HANDLE)
            {
               // fallback
               ApplyFallbackForIndex(i);
            }
         }
         // MA handle
         if(m_cfg[i].mode == SM_MA)
         {
            int attempts = 0;
            while(attempts < 10 && m_cfg[i].ma_handle == INVALID_HANDLE)
            {
               ENUM_TIMEFRAMES tf = (ENUM_TIMEFRAMES)Period();
               int h = iMA(m_cfg[i].symbol, tf, m_cfg[i].ma_period, m_cfg[i].ma_shift, (ENUM_MA_METHOD)m_cfg[i].ma_method, PRICE_CLOSE);
               if(h != INVALID_HANDLE)
               {
                  m_cfg[i].ma_handle = h;
                  break;
               }
               attempts++;
               Sleep(50);
            }
            m_cfg[i].ma_create_attempts = attempts;
            if(m_cfg[i].ma_handle == INVALID_HANDLE)
            {
               // fallback
               ApplyFallbackForIndex(i);
            }
         }
      }
      // default: criar handles se default mode exigir
      if(m_default.mode == SM_ATR)
      {
         int attempts = 0;
         while(attempts < 10 && m_default.atr_handle == INVALID_HANDLE)
         {
            ENUM_TIMEFRAMES tf = (ENUM_TIMEFRAMES)Period();
            int h = iATR(Symbol(), tf, m_default.atr_period);
            if(h != INVALID_HANDLE) { m_default.atr_handle = h; break; }
            attempts++; Sleep(50);
         }
         m_default.atr_create_attempts = attempts;
         if(m_default.atr_handle == INVALID_HANDLE) ApplyFallbackForDefault();
      }
      if(m_default.mode == SM_MA)
      {
         int attempts = 0;
         while(attempts < 10 && m_default.ma_handle == INVALID_HANDLE)
         {
            ENUM_TIMEFRAMES tf = (ENUM_TIMEFRAMES)Period();
            int h = iMA(Symbol(), tf, m_default.ma_period, m_default.ma_shift, (ENUM_MA_METHOD)m_default.ma_method, PRICE_CLOSE);
            if(h != INVALID_HANDLE) { m_default.ma_handle = h; break; }
            attempts++; Sleep(50);
         }
         m_default.ma_create_attempts = attempts;
         if(m_default.ma_handle == INVALID_HANDLE) ApplyFallbackForDefault();
      }
   }

   // libera recursos (chamar em OnDeinit do EA)
   void Deinit()
   {
      for(int i=0;i<ArraySize(m_cfg);i++)
      {
         if(m_cfg[i].atr_handle != INVALID_HANDLE)
         {
            IndicatorRelease(m_cfg[i].atr_handle);
            m_cfg[i].atr_handle = INVALID_HANDLE;
         }
            if(m_cfg[i].ma_handle != INVALID_HANDLE)
            {
               IndicatorRelease(m_cfg[i].ma_handle);
               m_cfg[i].ma_handle = INVALID_HANDLE;
            }
      }
      if(m_default.atr_handle != INVALID_HANDLE)
      {
         IndicatorRelease(m_default.atr_handle);
         m_default.atr_handle = INVALID_HANDLE;
      }
        if(m_default.ma_handle != INVALID_HANDLE)
        {
           IndicatorRelease(m_default.ma_handle);
           m_default.ma_handle = INVALID_HANDLE;
        }
   }

   // retorna handle ATR para o cfg, criando se necessário (usa timeframe do gráfico onde EA está rodando)
   int EnsureATRHandleByIndex(const int idx, const string symbol)
   {
      if(idx < 0) { return INVALID_HANDLE; }
      if(m_cfg[idx].atr_handle != INVALID_HANDLE) { return m_cfg[idx].atr_handle; }
      // try recreate if attempts < 10
      if(m_cfg[idx].atr_create_attempts >= 10)
      {
         // already failed too many times
         return INVALID_HANDLE;
      }
      ENUM_TIMEFRAMES tf = (ENUM_TIMEFRAMES)Period();
      int h = iATR(symbol, tf, m_cfg[idx].atr_period);
      if(h != INVALID_HANDLE)
      {
         m_cfg[idx].atr_handle = h;
         return h;
      }
      m_cfg[idx].atr_create_attempts++;
      if(m_cfg[idx].atr_create_attempts >= 10) ApplyFallbackForIndex(idx);
      return INVALID_HANDLE;
   }

   // MA handles (persistentes por símbolo quando configurado)
   int EnsureMAHandleByIndex(const int idx, const string symbol)
   {
      if(idx < 0) { return INVALID_HANDLE; }
      if(m_cfg[idx].ma_handle != INVALID_HANDLE) { return m_cfg[idx].ma_handle; }
      if(m_cfg[idx].ma_create_attempts >= 10)
      {
         return INVALID_HANDLE;
      }
      ENUM_TIMEFRAMES tf = (ENUM_TIMEFRAMES)Period();
      int h = iMA(symbol, tf, m_cfg[idx].ma_period, m_cfg[idx].ma_shift, (ENUM_MA_METHOD)m_cfg[idx].ma_method, PRICE_CLOSE);
      if(h != INVALID_HANDLE)
      {
         m_cfg[idx].ma_handle = h;
         return h;
      }
      m_cfg[idx].ma_create_attempts++;
      if(m_cfg[idx].ma_create_attempts >= 10) ApplyFallbackForIndex(idx);
      return INVALID_HANDLE;
   }

   int EnsureATRHandleDefault(const string symbol)
   {
      // use persistent default handle created in Init(); try recreate limited times if missing
      if(m_default.atr_handle != INVALID_HANDLE) return m_default.atr_handle;
      if(m_default.atr_create_attempts >= 10) { return INVALID_HANDLE; }
      ENUM_TIMEFRAMES tf = (ENUM_TIMEFRAMES)Period();
      int h = iATR(symbol, tf, m_default.atr_period);
      if(h != INVALID_HANDLE)
      {
         m_default.atr_handle = h;
         return h;
      }
      m_default.atr_create_attempts++;
      if(m_default.atr_create_attempts >= 10) ApplyFallbackForDefault();
      return INVALID_HANDLE;
   }

   int EnsureMAHandleDefault(const string symbol)
   {
      // use persistent default handle created in Init(); try recreate limited times if missing
      if(m_default.ma_handle != INVALID_HANDLE) return m_default.ma_handle;
      if(m_default.ma_create_attempts >= 10) { return INVALID_HANDLE; }
      ENUM_TIMEFRAMES tf = (ENUM_TIMEFRAMES)Period();
      int h = iMA(symbol, tf, m_default.ma_period, m_default.ma_shift, (ENUM_MA_METHOD)m_default.ma_method, PRICE_CLOSE);
      if(h != INVALID_HANDLE)
      {
         m_default.ma_handle = h;
         return h;
      }
      m_default.ma_create_attempts++;
      if(m_default.ma_create_attempts >= 10) ApplyFallbackForDefault();
      return INVALID_HANDLE;
   }

   // calc SL baseado em ATR, retorna price (normalized) ou EMPTY_VALUE em falha
   double CalcSL_ByATR(const string symbol, const double entry_price, const int dir, const SStopCfg &cfg, const int cfgIndex)
   {
      int handle = INVALID_HANDLE;
      bool temporary_handle = false;
      if(cfgIndex >= 0)
      {
         handle = EnsureATRHandleByIndex(cfgIndex, symbol);
      }
      else
      {
         handle = EnsureATRHandleDefault(symbol);
         temporary_handle = true;
      }
   if(handle == INVALID_HANDLE) { return EMPTY_VALUE; }
      double arr[]; ArrayResize(arr,1);
      int copied = CopyBuffer(handle, 0, 0, 1, arr);
      if(copied <= 0 || !MathIsValidNumber(arr[0]))
      {
         if(temporary_handle) { IndicatorRelease(handle); }
         // fallback to points-based SL
         return PriceFromEntryByPoints(symbol, entry_price, cfg.sl_points, -dir);
      }
      double atr = arr[0]; // ATR in price units
      double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
      if(!MathIsValidNumber(point) || point<=0)
      {
         if(temporary_handle) { IndicatorRelease(handle); }
         return PriceFromEntryByPoints(symbol, entry_price, cfg.sl_points, -dir);
      }
      double points = (atr * cfg.atr_mult) / point;
      double sl_price = PriceFromEntryByPoints(symbol, entry_price, points, -dir);
      int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
      double result = NormalizeDouble(sl_price, digits);
   if(temporary_handle) { IndicatorRelease(handle); }
   return result;
   }

   // calc SL baseado em MA, retorna price (normalized) ou EMPTY_VALUE em falha
   double CalcSL_ByMA(const string symbol, const double entry_price, const int dir, const SStopCfg &cfg, const int cfgIndex)
   {
      int handle = INVALID_HANDLE;
      bool temporary_handle = false;
      if(cfgIndex >= 0)
      {
         handle = EnsureMAHandleByIndex(cfgIndex, symbol);
      }
      else
      {
         handle = EnsureMAHandleDefault(symbol);
         temporary_handle = true;
      }
   if(handle == INVALID_HANDLE) { return EMPTY_VALUE; }
      double arr[]; ArrayResize(arr,1);
      int copied = CopyBuffer(handle, 0, 0, 1, arr);
      if(copied <= 0 || !MathIsValidNumber(arr[0]))
      {
         if(temporary_handle) { IndicatorRelease(handle); }
         // fallback to points-based SL
         return PriceFromEntryByPoints(symbol, entry_price, cfg.sl_points, -dir);
      }
      double ma = arr[0]; // MA value in price units
      double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
      if(!MathIsValidNumber(point) || point<=0)
      {
         if(temporary_handle) { IndicatorRelease(handle); }
         return PriceFromEntryByPoints(symbol, entry_price, cfg.sl_points, -dir);
      }
      // offset in price units
      double offset_price = cfg.ma_offset_points * point;
      double sl_price = ma - dir * offset_price; // for buy (dir=+1) SL = MA - offset; for sell dir=-1 SL = MA + offset
      int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
      double result = NormalizeDouble(sl_price, digits);
   if(temporary_handle) { IndicatorRelease(handle); }
   return result;
   }

   void ClearSymbolConfigs()
   {
      ArrayResize(m_cfg, 0);
   }

   // retorna próximo modo de fallback: ATR -> MA -> TICK
   int NextFallbackMode(const int current)
   {
      if(current == SM_ATR) return SM_MA;
      return SM_TICK;
   }

   // aplica fallback para um índice de cfg quando excedeu tentativas
   void ApplyFallbackForIndex(const int idx)
   {
      if(idx < 0 || idx >= ArraySize(m_cfg)) return;
      int cur = m_cfg[idx].mode;
      int next = NextFallbackMode(cur);
      Log(StringFormat("ApplyFallbackForIndex: symbol=%s mode %d->%d after failures", m_cfg[idx].symbol, cur, next));
      m_cfg[idx].mode = next;
      // reset attempts counters
      m_cfg[idx].atr_create_attempts = 0;
      m_cfg[idx].ma_create_attempts = 0;
      // release any handles
      if(m_cfg[idx].atr_handle != INVALID_HANDLE) { IndicatorRelease(m_cfg[idx].atr_handle); m_cfg[idx].atr_handle = INVALID_HANDLE; }
      if(m_cfg[idx].ma_handle != INVALID_HANDLE) { IndicatorRelease(m_cfg[idx].ma_handle); m_cfg[idx].ma_handle = INVALID_HANDLE; }
      // ensure tick-based distances exist when fallback to TICK
      if(m_cfg[idx].mode == SM_TICK)
      {
         if(m_cfg[idx].sl_points <= 0) m_cfg[idx].sl_points = m_default.sl_points > 0 ? m_default.sl_points : 200.0;
         if(m_cfg[idx].tp_points <= 0) m_cfg[idx].tp_points = m_default.tp_points > 0 ? m_default.tp_points : 400.0;
      }
   }

   // aplica fallback para default
   void ApplyFallbackForDefault()
   {
      int cur = m_default.mode;
      int next = NextFallbackMode(cur);
      Log(StringFormat("ApplyFallbackForDefault: mode %d->%d after failures", cur, next));
      m_default.mode = next;
      m_default.atr_create_attempts = 0;
      m_default.ma_create_attempts = 0;
      if(m_default.atr_handle != INVALID_HANDLE) { IndicatorRelease(m_default.atr_handle); m_default.atr_handle = INVALID_HANDLE; }
      if(m_default.ma_handle != INVALID_HANDLE) { IndicatorRelease(m_default.ma_handle); m_default.ma_handle = INVALID_HANDLE; }
      if(m_default.mode == SM_TICK)
      {
         if(m_default.sl_points <= 0) m_default.sl_points = 200.0;
         if(m_default.tp_points <= 0) m_default.tp_points = 400.0;
      }
   }

   // método principal: deve ser chamado em OnTick do EA
   void OnTick()
   {
      int total = PositionsTotal();
      for(int i=0;i<total;i++)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0) { continue; }
            // Seleciona explicitamente a posição pelo ticket antes de ler campos
            if(!PositionSelectByTicket(ticket))
            {
               Log(StringFormat("OnTick: falha PositionSelectByTicket ticket=%I64u", ticket));
               continue;
            }
            string sym = PositionGetString(POSITION_SYMBOL);
         if(StringLen(sym) == 0) { continue; }
         int ptype = (int)PositionGetInteger(POSITION_TYPE);
         double vol = PositionGetDouble(POSITION_VOLUME);
         double entry = PositionGetDouble(POSITION_PRICE_OPEN);
         double cur_price = (ptype == POSITION_TYPE_BUY ? SymbolInfoDouble(sym, SYMBOL_BID) : SymbolInfoDouble(sym, SYMBOL_ASK));
         double cur_sl = PositionGetDouble(POSITION_SL);
         double cur_tp = PositionGetDouble(POSITION_TP);
         double profit = PositionGetDouble(POSITION_PROFIT);
         int dir = (ptype == POSITION_TYPE_BUY ? +1 : -1);

         SStopCfg cfg = GetConfig(sym);
         int cfgIndex = FindConfigIndex(sym);
         // calcula SL/TP desejados com base no cfg e estado atual
         double desired_sl = EMPTY_VALUE;
         if(cfg.mode == SM_MA)
         {
            double sl_ma = CalcSL_ByMA(sym, entry, dir, cfg, cfgIndex);
            if(MathIsValidNumber(sl_ma) && sl_ma>0) { desired_sl = sl_ma; }
         }
         else if(cfg.mode == SM_ATR)
         {
            double sl_atr = CalcSL_ByATR(sym, entry, dir, cfg, cfgIndex);
            if(MathIsValidNumber(sl_atr) && sl_atr>0) { desired_sl = sl_atr; }
         }
         if(!MathIsValidNumber(desired_sl) || desired_sl<=0)
         {
            // fallback para pontos
            desired_sl = PriceFromEntryByPoints(sym, entry, cfg.sl_points, -dir); // cuidado com sinal: SL é do outro lado
         }

         double desired_tp = PriceFromEntryByPoints(sym, entry, cfg.tp_points, dir);

         // breakeven: move SL para entry + buffer quando lucro em pontos >= start
         if(cfg.breakeven_enabled)
         {
            double profit_points = ( (ptype == POSITION_TYPE_BUY) ? (cur_price - entry) : (entry - cur_price) ) / SymbolInfoDouble(sym, SYMBOL_POINT);
            if(profit_points >= cfg.breakeven_start_points)
            {
               double be_price = PriceFromEntryByPoints(sym, entry, cfg.breakeven_buffer_points, dir);
               // para buy, be_price = entry + buffer; para sell, entry - buffer
               
               // ajustar desired_sl dependendo do tipo: o SL deve ficar mais próximo do preço (maior) para buy
               
               if(dir == +1)
               {
                  if(be_price > desired_sl) { desired_sl = be_price; }
               }
               else
               {
                  if(be_price < desired_sl) { desired_sl = be_price; }
               }
            }
         }

         // trailing: se ativado, e lucro > start, mover SL incrementalmente
         
         if(cfg.trailing_enabled)
         {
            double profit_points = ( (ptype == POSITION_TYPE_BUY) ? (cur_price - entry) : (entry - cur_price) ) / SymbolInfoDouble(sym, SYMBOL_POINT);
            if(profit_points >= cfg.trailing_start_points)
            {
               // calcula novo SL baseado no último step completo
               double steps = MathFloor((profit_points - cfg.trailing_start_points) / cfg.trailing_step_points);
               if(steps >= 0)
               {
                  double new_sl_by_steps = PriceFromEntryByPoints(sym, entry, cfg.trailing_start_points + steps * cfg.trailing_step_points, dir);
                  if(dir == +1)
                  {
                     if(new_sl_by_steps > desired_sl) { desired_sl = new_sl_by_steps; }
                  }
                  else
                  {
                     if(new_sl_by_steps < desired_sl) { desired_sl = new_sl_by_steps; }
                  }
               }
            }
         }

         // garante distância mínima e normaliza
         desired_sl = EnsureMinimalDistance(sym, desired_sl, dir);
         desired_tp = EnsureMinimalDistance(sym, desired_tp, -dir);

         // decide se precisa alterar SL/TP
         
         bool need_modify = false;
         // comparar com SL/TP atuais com tolerância de 1 point
         
         double point = SymbolInfoDouble(sym, SYMBOL_POINT);
         if(MathAbs(cur_sl - desired_sl) > (point * 0.5)) { need_modify = true; }
         if(MathAbs(cur_tp - desired_tp) > (point * 0.5)) { need_modify = true; }

         if(need_modify)
         {
            ModifyPositionStops(ticket, sym, desired_sl, desired_tp);
         }
      }
   }
};

#endif // __STOP_MANAGER_V1_MQH__
