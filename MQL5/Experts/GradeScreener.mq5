//+------------------------------------------------------------------+
//| GradeScreener.mq5                                                |
//| Market Watch pullback-grade screener for MT5 Build 6090+         |
//| No trading. Attach to any chart.                                 |
//+------------------------------------------------------------------+
#property copyright "RL-Screener"
#property link      "https://github.com/monty313/RL-Screener"
#property version   "1.30"
#property description "Scans Market Watch. Three-clock grade: L / near / far."
#property description "S1 1m-15m-30m | S2 5m-30m-1h | S3 15m-1h-4h | S4 30m-4h-1d"
#property strict

#include <Canvas/Canvas.mqh>

enum ENUM_GRADE_SET
  {
   SET_S1 = 0,  // 1m / 15m / 30m
   SET_S2 = 1,  // 5m / 30m / 1h
   SET_S3 = 2,  // 15m / 1h / 4h
   SET_S4 = 3   // 30m / 4h / 1d
  };

enum ENUM_ROW_FILTER
  {
   FILTER_ALL = 0,
   FILTER_LEGAL = 1,
   FILTER_Q4 = 2
  };

enum ENUM_DIR_FILTER
  {
   DIR_BOTH = 0,
   DIR_LONG = 1,
   DIR_SHORT = 2
  };

input group "Screener"
input ENUM_GRADE_SET   InpSet            = SET_S3;
input ENUM_ROW_FILTER  InpFilter         = FILTER_ALL;
input ENUM_DIR_FILTER  InpDirection      = DIR_BOTH;
input bool             InpClosedBar      = true;
input int              InpMinGradeQ4     = 15;
input int              InpCciGate        = 30;
input int              InpBbPeriod       = 20;
input int              InpCciPeriod      = 14;
input int              InpGateShift      = 4;
input int              InpRefreshMs      = 1500;
input int              InpBatch          = 10;
input int              InpMaxSymbols     = 80;

input group "Watch hygiene"
input bool             InpSkipNoTrade    = true;
input bool             InpSkipNoQuote    = true;
input bool             InpHideUnready    = true;
input double           InpMaxSpreadPips  = 0;      // 0 = off
input bool             InpRememberLayout = true;

input group "Alerts"
input bool             InpAlerts         = true;
input bool             InpAlertPopup     = true;
input bool             InpAlertSound     = true;
input bool             InpAlertPush      = false;
input bool             InpAlertQ5Only    = false;
input int              InpAlertCooldown  = 180;    // seconds per symbol

input group "Panel"
input int              InpX              = 16;
input int              InpY              = 16;
input int              InpWidth          = 1040;
input int              InpVisibleRows    = 16;

#define BB_BARS     40
#define ROW_H       32
#define HDR_H       70
#define CHIP_Y      74
#define CHIP2_Y     106
#define FOOT_H      78
#define TABLE_TOP   158
#define GV_PREFIX   "GradeScr21_"

struct SRow
  {
   string   symbol;
   double   z_l;
   double   z_n;
   double   z_f;
   double   cci_f;
   double   grade;
   double   bid;
   double   spread_pips;
   bool     align;
   bool     legal;
   bool     ready;
   bool     tradeable;
   int      dir;
   int      alert_lvl;
   datetime alert_at;
  };

CCanvas g_cv;
SRow    g_rows[];
int     g_order[];
int     g_count = 0;
int     g_scan = 0;
int     g_set;
int     g_filter;
int     g_dir;
bool    g_alerts_on;
bool    g_collapsed = false;
int     g_full_h;
int     g_last_click_row = -1;
uint    g_last_click_ms = 0;
int     g_scroll = 0;
int     g_sel = -1;
int     g_px;
int     g_py;
int     g_width;
int     g_height;
int     g_visible;
bool    g_drag = false;
int     g_drag_dx = 0;
int     g_drag_dy = 0;
datetime g_last_draw = 0;

uint C_BG;
uint C_PANEL;
uint C_WASH;
uint C_LINE;
uint C_BRASS;
uint C_BRASS_DIM;
uint C_BRASS_HOT;
uint C_INK;
uint C_CREAM;
uint C_MUTED;
uint C_LONG;
uint C_SHORT;
uint C_DEAD;
uint C_CHIP;
uint C_CHIP_ON;
uint C_ROW;
uint C_ROW2;

//+------------------------------------------------------------------+
uint ARGBC(const uchar a,const color clr)
  {
   return ColorToARGB(clr, a);
  }

//+------------------------------------------------------------------+
void Palette(void)
  {
   C_BG        = ARGBC(255, C'8,10,14');
   C_PANEL     = ARGBC(255, C'14,16,22');
   C_WASH      = ARGBC(255, C'10,12,18');
   C_LINE      = ARGBC(255, C'36,42,56');
   C_BRASS     = ARGBC(255, C'56,210,230');
   C_BRASS_DIM = ARGBC(255, C'28,90,110');
   C_BRASS_HOT = ARGBC(255, C'120,240,255');
   C_INK       = ARGBC(255, C'8,10,14');
   C_CREAM     = ARGBC(255, C'226,232,242');
   C_MUTED     = ARGBC(255, C'122,132,148');
   C_LONG      = ARGBC(255, C'46,214,140');
   C_SHORT     = ARGBC(255, C'255,82,110');
   C_DEAD      = ARGBC(255, C'70,78,92');
   C_CHIP      = ARGBC(255, C'22,26,36');
   C_CHIP_ON   = ARGBC(255, C'18,48,58');
   C_ROW       = ARGBC(255, C'18,20,28');
   C_ROW2      = ARGBC(255, C'16,18,24');
  }

//+------------------------------------------------------------------+
uint MixU(const uint a,const uint b,const double t)
  {
   const double u = MathMax(0.0, MathMin(1.0, t));
   const uchar aa = (uchar)((a >> 24) & 0xFF);
   const uchar ar = (uchar)((a >> 16) & 0xFF);
   const uchar ag = (uchar)((a >> 8) & 0xFF);
   const uchar ab = (uchar)(a & 0xFF);
   const uchar ba = (uchar)((b >> 24) & 0xFF);
   const uchar br = (uchar)((b >> 16) & 0xFF);
   const uchar bg = (uchar)((b >> 8) & 0xFF);
   const uchar bb = (uchar)(b & 0xFF);
   return ((uint)(aa + (ba - aa) * u) << 24)
          | ((uint)(ar + (br - ar) * u) << 16)
          | ((uint)(ag + (bg - ag) * u) << 8)
          | (uint)(ab + (bb - ab) * u);
  }

//+------------------------------------------------------------------+
ENUM_TIMEFRAMES SetTf(const int set_id,const int clock)
  {
   if(set_id == 0)
     {
      if(clock == 0) return PERIOD_M1;
      if(clock == 1) return PERIOD_M15;
      return PERIOD_M30;
     }
   if(set_id == 1)
     {
      if(clock == 0) return PERIOD_M5;
      if(clock == 1) return PERIOD_M30;
      return PERIOD_H1;
     }
   if(set_id == 2)
     {
      if(clock == 0) return PERIOD_M15;
      if(clock == 1) return PERIOD_H1;
      return PERIOD_H4;
     }
   if(clock == 0) return PERIOD_M30;
   if(clock == 1) return PERIOD_H4;
   return PERIOD_D1;
  }

//+------------------------------------------------------------------+
string SetLabel(const int set_id)
  {
   switch(set_id)
     {
      case 0: return "S1  1m / 15m / 30m";
      case 1: return "S2  5m / 30m / 1h";
      case 2: return "S3  15m / 1h / 4h";
      case 3: return "S4  30m / 4h / 1d";
     }
   return "?";
  }

//+------------------------------------------------------------------+
string TfShort(const ENUM_TIMEFRAMES tf)
  {
   switch(tf)
     {
      case PERIOD_M1:  return "1m";
      case PERIOD_M5:  return "5m";
      case PERIOD_M15: return "15m";
      case PERIOD_M30: return "30m";
      case PERIOD_H1:  return "1h";
      case PERIOD_H4:  return "4h";
      case PERIOD_D1:  return "1d";
     }
   return "?";
  }

//+------------------------------------------------------------------+
bool ClockStats(const string symbol,const ENUM_TIMEFRAMES tf,const int shift,
                double &z,double &cci_v,bool &gate)
  {
   z = 0;
   cci_v = 0;
   gate = false;
   MqlRates rates[];
   const int need = InpBbPeriod + InpGateShift + InpCciPeriod + 4;
   if(CopyRates(symbol, tf, shift, need, rates) < need)
      return false;
   ArraySetAsSeries(rates, true);

   double sma = 0;
   for(int i = 0; i < InpBbPeriod; i++)
      sma += rates[i].close;
   sma /= InpBbPeriod;

   double var = 0;
   for(int i = 0; i < InpBbPeriod; i++)
     {
      const double d = rates[i].close - sma;
      var += d * d;
     }
   const double sd = MathSqrt(var / InpBbPeriod);
   if(sd <= 0)
      return false;
   z = (rates[0].close - sma) / sd;

   double tp[];
   ArrayResize(tp, InpCciPeriod);
   for(int i = 0; i < InpCciPeriod; i++)
      tp[i] = (rates[i].high + rates[i].low + rates[i].close) / 3.0;
   double tp_sma = 0;
   for(int i = 0; i < InpCciPeriod; i++)
      tp_sma += tp[i];
   tp_sma /= InpCciPeriod;
   double mad = 0;
   for(int i = 0; i < InpCciPeriod; i++)
      mad += MathAbs(tp[i] - tp_sma);
   mad /= InpCciPeriod;
   if(mad <= 0)
      return false;
   cci_v = (tp[0] - tp_sma) / (0.015 * mad);

   double sma_shift = 0;
   for(int i = InpGateShift; i < InpGateShift + InpBbPeriod; i++)
      sma_shift += rates[i].close;
   sma_shift /= InpBbPeriod;
   if(z > 0)
      gate = (rates[0].close > sma_shift);
   else if(z < 0)
      gate = (rates[0].close < sma_shift);
   else
      gate = false;
   return true;
  }

//+------------------------------------------------------------------+
double SpreadPips(const string symbol)
  {
   const double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   const double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(point <= 0 || bid <= 0 || ask <= 0)
      return 1.0e9;
   double spr = (ask - bid) / point;
   const int digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   if(digits == 3 || digits == 5)
      spr /= 10.0;
   return spr;
  }

//+------------------------------------------------------------------+
bool IsTradeable(const string symbol)
  {
   const long mode = SymbolInfoInteger(symbol, SYMBOL_TRADE_MODE);
   return (mode != SYMBOL_TRADE_MODE_DISABLED);
  }

//+------------------------------------------------------------------+
void FireAlert(const SRow &row,const int lvl)
  {
   if(!g_alerts_on || !InpAlerts)
      return;
   const string way = (row.dir > 0 ? "BUY" : "SELL");
   const string msg = StringFormat("%s %s  grade %.2f  %s  spr %.1f",
                                   way, row.symbol, row.grade,
                                   (lvl >= 5 ? "Q5" : "Q4"), row.spread_pips);
   if(InpAlertPopup)
      Alert(msg);
   else
      Print(msg);
   if(InpAlertSound)
      PlaySound("alert.wav");
   if(InpAlertPush)
      SendNotification(msg);
  }

//+------------------------------------------------------------------+
void MaybeAlert(SRow &row)
  {
   if(!row.ready || !row.legal)
     {
      row.alert_lvl = 0;
      return;
     }
   int lvl = 0;
   if(row.grade >= 2.0)
      lvl = 5;
   else if(row.grade >= InpMinGradeQ4 / 10.0)
      lvl = 4;
   if(lvl == 0)
     {
      row.alert_lvl = 0;
      return;
     }
   if(InpAlertQ5Only && lvl < 5)
      return;
   if(lvl <= row.alert_lvl)
      return;
   if(row.alert_at > 0 && (TimeCurrent() - row.alert_at) < InpAlertCooldown)
      return;
   FireAlert(row, lvl);
   row.alert_lvl = lvl;
   row.alert_at = TimeCurrent();
  }

//+------------------------------------------------------------------+
bool ScoreSymbol(const string symbol,SRow &row)
  {
   row.symbol = symbol;
   row.ready = false;
   row.legal = false;
   row.align = false;
   row.grade = 0;
   row.dir = 0;
   row.z_l = row.z_n = row.z_f = 0;
   row.cci_f = 0;
   row.bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   row.spread_pips = SpreadPips(symbol);
   row.tradeable = IsTradeable(symbol);

   if(!SymbolInfoInteger(symbol, SYMBOL_SELECT))
      SymbolSelect(symbol, true);
   if(InpSkipNoQuote && row.bid <= 0)
      return false;
   if(InpSkipNoTrade && !row.tradeable)
      return false;

   const int shift = InpClosedBar ? 1 : 0;
   double zl, zn, zf, cl, cn, cf;
   bool gl, gn, gf;
   if(!ClockStats(symbol, SetTf(g_set, 0), shift, zl, cl, gl))
      return false;
   if(!ClockStats(symbol, SetTf(g_set, 1), shift, zn, cn, gn))
      return false;
   if(!ClockStats(symbol, SetTf(g_set, 2), shift, zf, cf, gf))
      return false;

   row.z_l = zl;
   row.z_n = zn;
   row.z_f = zf;
   row.cci_f = cf;
   row.dir = (zf > 0 ? 1 : (zf < 0 ? -1 : 0));
   row.align = (MathSign(zf) == MathSign(zn) && zf != 0 && zn != 0);
   const bool cci_ok = (MathAbs(cf) >= InpCciGate);
   row.legal = (row.align && gn && gf && cci_ok);
   row.grade = (row.legal ? MathSign(zf) * (zf - zl) : 0.0);
   row.ready = true;
   MaybeAlert(row);
   return true;
  }

//+------------------------------------------------------------------+
int MathSign(const double v)
  {
   if(v > 0) return 1;
   if(v < 0) return -1;
   return 0;
  }

//+------------------------------------------------------------------+
void CollectSymbols(void)
  {
   const int watch = SymbolsTotal(true);
   g_count = 0;
   ArrayResize(g_rows, MathMin(watch, InpMaxSymbols));
   for(int i = 0; i < watch && g_count < InpMaxSymbols; i++)
     {
      const string s = SymbolName(i, true);
      if(s == "")
         continue;
      if(InpSkipNoTrade && !IsTradeable(s))
         continue;
      g_rows[g_count].symbol = s;
      g_rows[g_count].ready = false;
      g_rows[g_count].alert_lvl = 0;
      g_rows[g_count].alert_at = 0;
      g_count++;
     }
   ArrayResize(g_rows, g_count);
   ArrayResize(g_order, g_count);
   for(int i = 0; i < g_count; i++)
      g_order[i] = i;
   g_scan = 0;
   g_scroll = 0;
   g_sel = -1;
  }

//+------------------------------------------------------------------+
void ScanBatch(void)
  {
   if(g_count <= 0)
      return;
   for(int n = 0; n < InpBatch; n++)
     {
      ScoreSymbol(g_rows[g_scan].symbol, g_rows[g_scan]);
      g_scan++;
      if(g_scan >= g_count)
         g_scan = 0;
     }
   SortRows();
  }

//+------------------------------------------------------------------+
bool PassesFilter(const SRow &row)
  {
   if(!row.ready)
      return (!InpHideUnready && g_filter == FILTER_ALL);
   if(g_dir == DIR_LONG && row.dir <= 0)
      return false;
   if(g_dir == DIR_SHORT && row.dir >= 0)
      return false;
   if(InpMaxSpreadPips > 0 && row.spread_pips > InpMaxSpreadPips)
      return false;
   if(g_filter == FILTER_LEGAL)
      return row.legal;
   if(g_filter == FILTER_Q4)
      return (row.legal && row.grade >= InpMinGradeQ4 / 10.0);
   return true;
  }

//+------------------------------------------------------------------+
void SortRows(void)
  {
   int tmp[];
   int n = 0;
   ArrayResize(tmp, g_count);
   for(int i = 0; i < g_count; i++)
     {
      if(PassesFilter(g_rows[i]))
         tmp[n++] = i;
     }
   ArrayResize(tmp, n);
   for(int i = 0; i < n; i++)
     {
      int best = i;
      for(int j = i + 1; j < n; j++)
        {
         const SRow a = g_rows[tmp[j]];
         const SRow b = g_rows[tmp[best]];
         const int as = (SignalStrong(a) ? 2 : (SignalDir(a) != 0 ? 1 : 0));
         const int bs = (SignalStrong(b) ? 2 : (SignalDir(b) != 0 ? 1 : 0));
         if(as > bs) { best = j; continue; }
         if(as == bs && a.grade > b.grade)
            best = j;
        }
      const int sw = tmp[i];
      tmp[i] = tmp[best];
      tmp[best] = sw;
     }
   ArrayResize(g_order, n);
   for(int i = 0; i < n; i++)
      g_order[i] = tmp[i];
   if(g_scroll > MathMax(0, n - g_visible))
      g_scroll = MathMax(0, n - g_visible);
  }

//+------------------------------------------------------------------+
void FillRound(const int x1,const int y1,const int x2,const int y2,const int r,const uint clr)
  {
   g_cv.FillRectangle(x1 + r, y1, x2 - r, y2, clr);
   g_cv.FillRectangle(x1, y1 + r, x2, y2 - r, clr);
   g_cv.FillCircle(x1 + r, y1 + r, r, clr);
   g_cv.FillCircle(x2 - r, y1 + r, r, clr);
   g_cv.FillCircle(x1 + r, y2 - r, r, clr);
   g_cv.FillCircle(x2 - r, y2 - r, r, clr);
  }

//+------------------------------------------------------------------+
void Wash(void)
  {
   g_cv.FillRectangle(0, 0, g_width - 1, g_height - 1, C_PANEL);
   g_cv.FillRectangle(0, 0, 3, g_height - 1, C_BRASS);
  }

//+------------------------------------------------------------------+
void Frame(void)
  {
   g_cv.Rectangle(0, 0, g_width - 1, g_height - 1, C_LINE);
  }

//+------------------------------------------------------------------+
void Crest(const int cx,const int cy)
  {
   g_cv.FillRectangle(cx - 10, cy - 10, cx + 10, cy + 10, C_CHIP_ON);
   g_cv.Rectangle(cx - 10, cy - 10, cx + 10, cy + 10, C_BRASS);
   TextL(cx - 5, cy - 8, "G", C_BRASS_HOT, 13, true);
  }

//+------------------------------------------------------------------+
void TextL(const int x,const int y,const string t,const uint clr,const int sz,const bool bold = false)
  {
   g_cv.FontSet("Segoe UI", sz, bold ? FW_BOLD : FW_NORMAL);
   g_cv.TextOut(x, y, t, clr);
  }

//+------------------------------------------------------------------+
void TextStory(const int x,const int y,const string t,const uint clr,const int sz)
  {
   g_cv.FontSet("Segoe UI", sz, FW_BOLD);
   g_cv.TextOut(x, y, t, clr);
  }

//+------------------------------------------------------------------+
int SignalDir(const SRow &row)
  {
   if(!row.ready || !row.legal || row.dir == 0)
      return 0;
   return row.dir;
  }

//+------------------------------------------------------------------+
bool SignalStrong(const SRow &row)
  {
   return (SignalDir(row) != 0 && row.grade >= InpMinGradeQ4 / 10.0);
  }

//+------------------------------------------------------------------+
void DrawSignal(const int x,const int y,const SRow &row)
  {
   const int d = SignalDir(row);
   string lab = "WAIT";
   uint fg = C_MUTED;
   uint bg = C_CHIP;
   uint bd = C_LINE;
   if(d > 0)
     {
      lab = (SignalStrong(row) ? "BUY" : "buy");
      fg = (SignalStrong(row) ? C_INK : C_LONG);
      bg = (SignalStrong(row) ? C_LONG : C_CHIP);
      bd = C_LONG;
     }
   else if(d < 0)
     {
      lab = (SignalStrong(row) ? "SELL" : "sell");
      fg = (SignalStrong(row) ? C_CREAM : C_SHORT);
      bg = (SignalStrong(row) ? C_SHORT : C_CHIP);
      bd = C_SHORT;
     }
   FillRound(x, y, x + 58, y + 22, 4, bg);
   g_cv.Rectangle(x, y, x + 58, y + 22, bd);
   TextL(x + 10, y + 3, lab, fg, 12, true);
  }

//+------------------------------------------------------------------+
string ShellTxt(const double z)
  {
   const int s = (int)MathRound(z);
   const int c = (int)MathMax(-4, MathMin(4, s));
   if(c > 0)
      return "+" + IntegerToString(c);
   return IntegerToString(c);
  }

//+------------------------------------------------------------------+
uint GradeColor(const SRow &row)
  {
   if(!row.ready || !row.legal)
      return C_MUTED;
   if(row.grade >= 2.0)
      return C_BRASS_HOT;
   if(row.grade >= 1.5)
      return C_BRASS;
   if(row.grade > 0)
      return C_CREAM;
   return C_MUTED;
  }

//+------------------------------------------------------------------+
void DrawChip(const int x,const int y,const int w,const string label,const bool on)
  {
   FillRound(x, y, x + w, y + 26, 7, on ? C_CHIP_ON : C_CHIP);
   g_cv.Rectangle(x, y, x + w, y + 26, on ? C_BRASS : C_LINE);
   if(on)
      g_cv.LineHorizontal(x + 6, x + w - 6, y + 1, C_BRASS_HOT);
   TextL(x + 10, y + 5, label, on ? C_BRASS_HOT : C_MUTED, 11, on);
  }

//+------------------------------------------------------------------+
void DrawMeter(const int x,const int y,const double grade)
  {
   const int w = 72;
   const int h = 8;
   g_cv.FillRectangle(x, y, x + w, y + h, C_CHIP);
   g_cv.Rectangle(x, y, x + w, y + h, C_LINE);
   const double t = MathMax(0.0, MathMin(1.0, grade / 4.0));
   const int fill = (int)MathRound(t * (w - 2));
   if(fill > 0)
     {
      const uint c = (grade >= 2.0 ? C_BRASS_HOT : (grade >= 1.5 ? C_BRASS : C_BRASS_DIM));
      g_cv.FillRectangle(x + 1, y + 1, x + 1 + fill, y + h - 1, c);
     }
  }

//+------------------------------------------------------------------+
void DrawCoin(const int x,const int y,const double z)
  {
   const int mag = (int)MathMax(0, MathMin(4, MathAbs(MathRound(z))));
   uint c = C_DEAD;
   if(mag >= 3) c = C_BRASS_HOT;
   else if(mag == 2) c = C_BRASS;
   else if(mag == 1) c = C_BRASS_DIM;
   g_cv.FillCircle(x, y, 7, C_CHIP);
   g_cv.Circle(x, y, 7, c);
   TextL(x - 4, y - 6, ShellTxt(z), c, 9, true);
  }

//+------------------------------------------------------------------+
void DrawGeometry(const int x,const int y,const int w,const int h,const SRow &row)
  {
   FillRound(x, y, x + w, y + h, 8, C_CHIP);
   g_cv.Rectangle(x, y, x + w, y + h, C_LINE);
   if(!row.ready)
     {
      TextL(x + 14, y + 22, "Scanning Market Watch...", C_MUTED, 11);
      return;
     }
   const int mid = y + h / 2 + 4;
   g_cv.LineAA(x + 12, mid, x + w - 12, mid, C_LINE);
   const double scale = (h / 2 - 14) / 4.0;
   const int xf = x + w / 5;
   const int xn = x + w / 2;
   const int xl = x + 4 * w / 5;
   const int yf = mid - (int)MathRound(MathMax(-4, MathMin(4, row.z_f)) * scale);
   const int yn = mid - (int)MathRound(MathMax(-4, MathMin(4, row.z_n)) * scale);
   const int yl = mid - (int)MathRound(MathMax(-4, MathMin(4, row.z_l)) * scale);
   g_cv.LineAA(xf, yf, xn, yn, C_BRASS_DIM);
   g_cv.LineAA(xn, yn, xl, yl, C_BRASS);
   g_cv.FillCircle(xf, yf, 5, C_BRASS_HOT);
   g_cv.FillCircle(xn, yn, 5, C_CREAM);
   g_cv.FillCircle(xl, yl, 5, C_LONG);
   TextL(x + 12, y + 6, "far  " + DoubleToString(row.z_f, 2), C_BRASS, 10);
   TextL(x + w / 2 - 36, y + 6, "near  " + DoubleToString(row.z_n, 2), C_CREAM, 10);
   TextL(x + w - 92, y + 6, "anchor  " + DoubleToString(row.z_l, 2), C_LONG, 10);
  }

//+------------------------------------------------------------------+
void ApplyHeight(void)
  {
   g_height = g_collapsed ? 148 : g_full_h;
   g_cv.Resize(g_width, g_height);
   ObjectSetInteger(0, "GradeScreener", OBJPROP_XSIZE, g_width);
   ObjectSetInteger(0, "GradeScreener", OBJPROP_YSIZE, g_height);
  }

//+------------------------------------------------------------------+
void SaveLayout(void)
  {
   if(!InpRememberLayout)
      return;
   GlobalVariableSet(GV_PREFIX + "set", g_set);
   GlobalVariableSet(GV_PREFIX + "filter", g_filter);
   GlobalVariableSet(GV_PREFIX + "dir", g_dir);
   GlobalVariableSet(GV_PREFIX + "x", g_px);
   GlobalVariableSet(GV_PREFIX + "y", g_py);
   GlobalVariableSet(GV_PREFIX + "alerts", g_alerts_on ? 1 : 0);
   GlobalVariableSet(GV_PREFIX + "collapsed", g_collapsed ? 1 : 0);
  }

//+------------------------------------------------------------------+
void LoadLayout(void)
  {
   if(!InpRememberLayout)
      return;
   if(GlobalVariableCheck(GV_PREFIX + "set"))
      g_set = (int)GlobalVariableGet(GV_PREFIX + "set");
   if(GlobalVariableCheck(GV_PREFIX + "filter"))
      g_filter = (int)GlobalVariableGet(GV_PREFIX + "filter");
   if(GlobalVariableCheck(GV_PREFIX + "dir"))
      g_dir = (int)GlobalVariableGet(GV_PREFIX + "dir");
   if(GlobalVariableCheck(GV_PREFIX + "x"))
      g_px = (int)GlobalVariableGet(GV_PREFIX + "x");
   if(GlobalVariableCheck(GV_PREFIX + "y"))
      g_py = (int)GlobalVariableGet(GV_PREFIX + "y");
   if(GlobalVariableCheck(GV_PREFIX + "alerts"))
      g_alerts_on = (GlobalVariableGet(GV_PREFIX + "alerts") > 0.5);
   if(GlobalVariableCheck(GV_PREFIX + "collapsed"))
      g_collapsed = (GlobalVariableGet(GV_PREFIX + "collapsed") > 0.5);
  }

//+------------------------------------------------------------------+
void DrawPanel(void)
  {
   g_cv.Erase(C_BG);
   Wash();
   Frame();
   Crest(36, 36);

   TextStory(62, 16, "GRADE SCAN", C_CREAM, 20);
   TextL(64, 44, SetLabel(g_set) + "   ·   Market Watch   ·   signals only, no trades", C_MUTED, 11);
   g_cv.LineHorizontal(20, g_width - 20, 62, C_LINE);

   DrawChip(22, CHIP_Y, 46, "S1", g_set == 0);
   DrawChip(74, CHIP_Y, 46, "S2", g_set == 1);
   DrawChip(126, CHIP_Y, 46, "S3", g_set == 2);
   DrawChip(178, CHIP_Y, 46, "S4", g_set == 3);
   DrawChip(246, CHIP_Y, 56, "ALL", g_filter == FILTER_ALL);
   DrawChip(308, CHIP_Y, 72, "LEGAL", g_filter == FILTER_LEGAL);
   DrawChip(386, CHIP_Y, 64, "Q4+", g_filter == FILTER_Q4);
   DrawChip(22, CHIP2_Y, 56, "BUY", g_dir == DIR_LONG);
   DrawChip(84, CHIP2_Y, 64, "SELL", g_dir == DIR_SHORT);
   DrawChip(154, CHIP2_Y, 56, "BOTH", g_dir == DIR_BOTH);
   DrawChip(226, CHIP2_Y, 64, "BELL", g_alerts_on);
   DrawChip(296, CHIP2_Y, 46, g_collapsed ? "+" : "-", g_collapsed);

   int buys = 0, sells = 0, strong = 0;
   for(int i = 0; i < g_count; i++)
     {
      const int d = SignalDir(g_rows[i]);
      if(d > 0) buys++;
      if(d < 0) sells++;
      if(SignalStrong(g_rows[i])) strong++;
     }
   TextStory(g_width - 300, 16, IntegerToString(buys), C_LONG, 20);
   TextL(g_width - 268, 22, "BUY", C_LONG, 11, true);
   TextStory(g_width - 210, 16, IntegerToString(sells), C_SHORT, 20);
   TextL(g_width - 178, 22, "SELL", C_SHORT, 11, true);
   TextL(g_width - 300, 44, IntegerToString(strong) + " Q4+   " + IntegerToString(ArraySize(g_order)) + "/" + IntegerToString(g_count) + " rows", C_MUTED, 11);

   if(g_collapsed)
     {
      g_cv.Update();
      return;
     }

   const int col_y = TABLE_TOP - 20;
   TextL(24, col_y, "SIGNAL", C_MUTED, 10);
   TextL(96, col_y, "SYMBOL", C_MUTED, 10);
   TextL(210, col_y, "BID", C_MUTED, 10);
   TextL(300, col_y, "SPR", C_MUTED, 10);
   TextL(350, col_y, "GRADE", C_MUTED, 10);
   TextL(500, col_y, "L", C_MUTED, 10);
   TextL(540, col_y, "N", C_MUTED, 10);
   TextL(580, col_y, "F", C_MUTED, 10);
   TextL(630, col_y, "CCI", C_MUTED, 10);
   TextL(690, col_y, "TELLING", C_MUTED, 10);
   g_cv.LineHorizontal(18, g_width - 18, TABLE_TOP - 6, C_BRASS_DIM);

   const int shown = ArraySize(g_order);
   if(shown == 0)
     {
      TextL(24, TABLE_TOP + 12, "No rows. Click ALL if Q4+ is empty. Check Market Watch has symbols.", C_MUTED, 12);
     }
   const int start = g_scroll;
   const int stop = MathMin(shown, start + g_visible);
   for(int i = start; i < stop; i++)
     {
      const int idx = g_order[i];
      const SRow row = g_rows[idx];
      const int y = TABLE_TOP + (i - start) * ROW_H;
      const bool sel = (idx == g_sel);
      if(sel)
         FillRound(12, y - 2, g_width - 12, y + ROW_H - 6, 6, C_CHIP_ON);
      else
         g_cv.FillRectangle(12, y - 2, g_width - 12, y + ROW_H - 6, ((i - start) % 2) == 0 ? C_ROW : C_ROW2);

      if(!row.ready)
        {
         TextL(24, y + 6, "...", C_DEAD, 12);
         TextL(96, y + 6, row.symbol, C_MUTED, 12);
         continue;
        }
      DrawSignal(20, y + 3, row);
      TextL(88, y + 6, row.symbol, C_CREAM, 12, true);
      const int digits = (int)SymbolInfoInteger(row.symbol, SYMBOL_DIGITS);
      TextL(210, y + 6, DoubleToString(row.bid, digits), C_CREAM, 11);
      const uint sprc = (InpMaxSpreadPips > 0 && row.spread_pips > InpMaxSpreadPips) ? C_SHORT : C_MUTED;
      TextL(300, y + 6, DoubleToString(row.spread_pips, 1), sprc, 11);
      TextL(350, y + 4, DoubleToString(row.grade, 2), GradeColor(row), 13, true);
      DrawMeter(408, y + 10, row.grade);
      DrawCoin(508, y + 12, row.z_l);
      DrawCoin(548, y + 12, row.z_n);
      DrawCoin(588, y + 12, row.z_f);
      TextL(630, y + 6, DoubleToString(row.cci_f, 0), C_MUTED, 12);
      string st = "no signal";
      uint sc = C_DEAD;
      if(SignalStrong(row) && row.grade >= 2.0)
        { st = (row.dir > 0 ? "BUY Q5" : "SELL Q5"); sc = (row.dir > 0 ? C_LONG : C_SHORT); }
      else if(SignalStrong(row))
        { st = (row.dir > 0 ? "BUY Q4" : "SELL Q4"); sc = (row.dir > 0 ? C_LONG : C_SHORT); }
      else if(SignalDir(row) != 0)
        { st = (row.dir > 0 ? "BUY weak" : "SELL weak"); sc = C_MUTED; }
      else if(!row.align)
        { st = "HTF mismatch"; sc = C_DEAD; }
      else
        { st = "gated"; sc = C_DEAD; }
      TextL(690, y + 6, st, sc, 12, SignalDir(row) != 0);
     }

   const int fy = g_height - FOOT_H;
   g_cv.LineHorizontal(16, g_width - 16, fy, C_BRASS_DIM);
   SRow focus;
   if(g_sel >= 0 && g_sel < g_count)
      focus = g_rows[g_sel];
   else if(ArraySize(g_order) > 0)
      focus = g_rows[g_order[0]];
   else
     {
      focus.ready = false;
      focus.symbol = "";
     }
   TextStory(22, fy + 12, focus.symbol == "" ? "Select a row" : focus.symbol, C_CREAM, 16);
   string foot = "Click selects. Double-click opens the chart.";
   if(focus.ready)
      foot = StringFormat("spr %.1f pips   bid %s   %s",
                          focus.spread_pips,
                          DoubleToString(focus.bid, (int)SymbolInfoInteger(focus.symbol, SYMBOL_DIGITS)),
                          TimeToString(TimeCurrent(), TIME_SECONDS));
   TextL(22, fy + 42, foot, C_MUTED, 10);
   DrawGeometry(300, fy + 8, g_width - 320, FOOT_H - 16, focus);
   g_cv.Update();
  }

//+------------------------------------------------------------------+
bool HitChip(const int mx,const int my,const int x,const int y,const int w)
  {
   return (mx >= g_px + x && mx <= g_px + x + w && my >= g_py + y && my <= g_py + y + 26);
  }

//+------------------------------------------------------------------+
void OpenRow(const int idx)
  {
   if(idx < 0 || idx >= g_count)
      return;
   ChartSetSymbolPeriod(0, g_rows[idx].symbol, SetTf(g_set, 0));
  }

//+------------------------------------------------------------------+
void HandleClick(const int mx,const int my)
  {
   if(mx < g_px || my < g_py || mx > g_px + g_width || my > g_py + g_height)
      return;

   if(HitChip(mx, my, 22, CHIP_Y, 46))  { g_set = 0; CollectSymbols(); SaveLayout(); return; }
   if(HitChip(mx, my, 74, CHIP_Y, 46))  { g_set = 1; CollectSymbols(); SaveLayout(); return; }
   if(HitChip(mx, my, 126, CHIP_Y, 46)) { g_set = 2; CollectSymbols(); SaveLayout(); return; }
   if(HitChip(mx, my, 178, CHIP_Y, 46)) { g_set = 3; CollectSymbols(); SaveLayout(); return; }
   if(HitChip(mx, my, 246, CHIP_Y, 56)) { g_filter = FILTER_ALL; SortRows(); SaveLayout(); DrawPanel(); return; }
   if(HitChip(mx, my, 308, CHIP_Y, 72)) { g_filter = FILTER_LEGAL; SortRows(); SaveLayout(); DrawPanel(); return; }
   if(HitChip(mx, my, 386, CHIP_Y, 64)) { g_filter = FILTER_Q4; SortRows(); SaveLayout(); DrawPanel(); return; }
   if(HitChip(mx, my, 22, CHIP2_Y, 56))  { g_dir = DIR_LONG; SortRows(); SaveLayout(); DrawPanel(); return; }
   if(HitChip(mx, my, 84, CHIP2_Y, 64))  { g_dir = DIR_SHORT; SortRows(); SaveLayout(); DrawPanel(); return; }
   if(HitChip(mx, my, 154, CHIP2_Y, 56)) { g_dir = DIR_BOTH; SortRows(); SaveLayout(); DrawPanel(); return; }
   if(HitChip(mx, my, 226, CHIP2_Y, 64)) { g_alerts_on = !g_alerts_on; SaveLayout(); DrawPanel(); return; }
   if(HitChip(mx, my, 296, CHIP2_Y, 46))
     {
      g_collapsed = !g_collapsed;
      ApplyHeight();
      SaveLayout();
      DrawPanel();
      return;
     }

   if(my >= g_py && my <= g_py + HDR_H)
     {
      g_drag = true;
      g_drag_dx = mx - g_px;
      g_drag_dy = my - g_py;
      return;
     }

   if(g_collapsed)
      return;

   const int local_y = my - g_py;
   if(local_y >= TABLE_TOP && local_y < g_height - FOOT_H)
     {
      const int row_i = g_scroll + (local_y - TABLE_TOP) / ROW_H;
      if(row_i >= 0 && row_i < ArraySize(g_order))
        {
         const int idx = g_order[row_i];
         const uint now = GetTickCount();
         if(idx == g_last_click_row && (now - g_last_click_ms) < 400)
            OpenRow(idx);
         g_last_click_row = idx;
         g_last_click_ms = now;
         g_sel = idx;
         DrawPanel();
        }
     }
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   Palette();
   g_set = (int)InpSet;
   g_filter = (int)InpFilter;
   g_dir = (int)InpDirection;
   g_alerts_on = InpAlerts;
   g_px = InpX;
   g_py = InpY;
   LoadLayout();
   g_visible = MathMax(8, InpVisibleRows);
   g_width = InpWidth;
   g_full_h = TABLE_TOP + g_visible * ROW_H + FOOT_H + 8;
   g_height = g_collapsed ? 148 : g_full_h;

   if(!g_cv.CreateBitmapLabel(0, 0, "GradeScreener", g_px, g_py, g_width, g_height, COLOR_FORMAT_ARGB_NORMALIZE))
     {
      Print("GradeScreener: canvas failed");
      return INIT_FAILED;
     }
   ObjectSetInteger(0, "GradeScreener", OBJPROP_CORNER, CORNER_LEFT_UPPER);
   ObjectSetInteger(0, "GradeScreener", OBJPROP_BACK, false);
   ObjectSetInteger(0, "GradeScreener", OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, "GradeScreener", OBJPROP_HIDDEN, true);

   ChartSetInteger(0, CHART_EVENT_MOUSE_MOVE, true);
   ChartSetInteger(0, CHART_EVENT_MOUSE_WHEEL, true);

   CollectSymbols();
   ScanBatch();
   DrawPanel();
   EventSetMillisecondTimer(MathMax(400, InpRefreshMs));
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   SaveLayout();
   EventKillTimer();
   g_cv.Destroy();
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   ScanBatch();
   DrawPanel();
  }

//+------------------------------------------------------------------+
void OnTick()
  {
  }

//+------------------------------------------------------------------+
void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam)
  {
   if(id == CHARTEVENT_MOUSE_MOVE)
     {
      const int mx = (int)lparam;
      const int my = (int)dparam;
      const int keys = (int)StringToInteger(sparam);
      if(g_drag && (keys & 1) == 1)
        {
         g_px = mx - g_drag_dx;
         g_py = my - g_drag_dy;
         ObjectSetInteger(0, "GradeScreener", OBJPROP_XDISTANCE, g_px);
         ObjectSetInteger(0, "GradeScreener", OBJPROP_YDISTANCE, g_py);
         SaveLayout();
        }
      else
         g_drag = false;
     }
   if(id == CHARTEVENT_CLICK)
      HandleClick((int)lparam, (int)dparam);
   if(id == CHARTEVENT_MOUSE_WHEEL)
     {
      const int mx = (int)lparam;
      const int my = (int)dparam;
      if(mx >= g_px && mx <= g_px + g_width && my >= g_py && my <= g_py + g_height)
        {
         const uint flags = (uint)StringToInteger(sparam);
         const int delta = (short)(flags >> 16);
         if(delta < 0)
            g_scroll = MathMin(MathMax(0, ArraySize(g_order) - g_visible), g_scroll + 1);
         else if(delta > 0)
            g_scroll = MathMax(0, g_scroll - 1);
         DrawPanel();
        }
     }
  }
//+------------------------------------------------------------------+
