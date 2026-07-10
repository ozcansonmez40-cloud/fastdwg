#include <jni.h>
#include <chrono>
#include <cmath>
#include <cctype>
#include <cstring>
#include <cstdlib>
#include <algorithm>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <tuple>
#include <vector>

#ifdef FASTDWG_WITH_LIBREDWG
extern "C" {
#include <dwg.h>
#include <dwg_api.h>
}
#endif

namespace {

std::string escape_json(const std::string& value) {
  std::ostringstream escaped;
  for (unsigned char ch : value) {
    switch (ch) {
      case '"':  escaped << "\\\""; break;
      case '\\': escaped << "\\\\"; break;
      case '\n': escaped << "\\n";  break;
      case '\r': escaped << "\\r";  break;
      case '\t': escaped << "\\t";  break;
      default:
        if (ch < 0x20) {
          escaped << "\\u00";
          const char hex[] = "0123456789abcdef";
          escaped << hex[(ch >> 4) & 0xF] << hex[ch & 0xF];
        } else {
          escaped << (char)ch;
        }
        break;
    }
  }
  return escaped.str();
}

double safe_number(double value, double fallback) {
  return std::isfinite(value) ? value : fallback;
}

#ifdef FASTDWG_WITH_LIBREDWG
constexpr double kPi = 3.14159265358979323846;
// Scene budgets. The scene is handed to Flutter via a temp file (not the
// platform channel), so these are bounded by render speed + memory, not the
// Java heap. Large site/survey DWGs (160 MB+) exceed 4M segments and were being
// truncated (drawing came out very incomplete), so lines are raised to 8M —
// ~180 MB packed, which a modern phone handles; viewport culling keeps pan/zoom
// light since most segments fall off-screen or sub-pixel at any given zoom.
constexpr int kMaxLines   = 8000000;
constexpr int kMaxCircles =  400000;
constexpr int kMaxTexts   =  150000;
constexpr int kMaxFills   =   60000; // solid-hatch fill polygons
constexpr int kMaxDots    =  400000; // DOT/DASHDOT linetype point marks

// ── ACI color lookup ──────────────────────────────────────────────────────────
// Uses LibreDWG's exact AutoCAD palette instead of an approximation.

static uint32_t aci_to_rgb(int aci) {
  if (aci <= 0 || aci > 255) return 0xFFFFFF;
  return (uint32_t)(dwg_rgb_palette_index((BITCODE_BS)aci) & 0xFFFFFF);
}

// ── Layer table ──────────────────────────────────────────────────────────────
// Real AutoCAD layers, exported so the viewer can toggle them. Index 0 is the
// fallback for entities whose layer cannot be resolved.
struct LayerInfo {
  std::string name;
  uint32_t rgb;
  bool visible;
  int16_t lineweight = -1; // DWG $LWEIGHT code; <0 = default/unset
};
static std::vector<LayerInfo> g_layers;
static std::map<unsigned long long, uint16_t> g_layer_idx; // LAYER handle → index
static uint16_t g_layer0_idx = 0;     // index of layer "0" (block default)
static uint16_t g_layer_override = 0; // INSERT's layer, inherited by layer-0 children
// Layer of the entity currently being emitted (set in render_entity).
static uint16_t g_cur_layer = 0;
// Handle of the entity currently being rendered (diagnostic tracing).
static unsigned long long g_cur_handle = 0;
// Effective color of the enclosing INSERT, inherited by BYBLOCK children.
static uint32_t g_color_override = 0xFFFFFF;

// Solid-fill polygons (filled regions, e.g. solid hatches). Each record:
//   u32 color; u16 layer; u16 numLoops; { u32 numPts; pts[2×f32] }
static std::ostringstream g_fill_bin;
static int g_fill_count = 0;
// DOT/DASHDOT linetype marks, emitted as fixed-screen-size points (packed:
// f32 x, f32 y, u32 color, u16 layer) so they never fall under the painter's
// short-segment cull when zoomed out.
static std::ostringstream g_dot_bin;
static int g_dot_count = 0;

// Open-time profiling: "read_ms=… build_ms=…", written to a sidecar file so we
// can see where the wait goes (LibreDWG parse vs our scene build) without logcat.
static std::string g_timing;

// De-dup guard for text: ideCAD-style files render a text-bearing block both via
// its INSERT and again in the orphan pass (both at the same world location, since
// those blocks are inserted at origin/scale 1), so the same label gets drawn
// twice and looks bold/garbled. Keyed by quantized position + string, so the
// same text at the SAME spot is dropped while repeated labels (e.g. dimension
// "26"s) at different spots are kept.
static std::set<std::string> g_text_keys;

// DEBUG: per-dxfname census of every entity in the file vs entities the
// renderer actually reached, plus skip counters — dumped into .timing so a
// "most of the drawing is missing" report can be pinned to a concrete cause
// (unsupported type / xref skip / unresolvable handle) without guesswork.
static std::map<std::string, int> g_dbg_file_types, g_dbg_reach_types;
static int g_dbg_xref_skip = 0, g_dbg_ins_unres = 0, g_dbg_ref_unres = 0;
// Recovery counters: entities reached via the linked-list fallback walk and
// via the model-space entmode sweep (see expand_block / the sweep below).
static int g_dbg_ll_rec = 0, g_dbg_ms_rec = 0;
// Unresolved-ref breakdown: ref chased to nothing vs to a non-entity object
// (and which types those are); model-space child count vs its unresolved.
static int g_dbg_ref_null = 0, g_dbg_ref_wrong = 0;
static std::map<std::string, int> g_dbg_wrong_types;
static int g_dbg_ms_owned = 0, g_dbg_ms_unres = 0;
// Every entity handle render_entity actually saw this parse — lets the
// model-space sweep draw only what the ref-chase walks missed.
static std::set<unsigned long long> g_rendered_handles;

// DEBUG: leader/hatch statistics
static int g_ldr_seen = 0, g_ldr_drawn = 0, g_ldr_pts = 0;
static int g_mldr_seen = 0, g_hatch_seen = 0, g_hatch_solid = 0;
// Hatch drop/degrade points: boundary too complex (pts cap), lattice
// decimated (dense), family budget exhausted mid-fill.
static int g_hatch_ptscap = 0, g_hatch_decim = 0, g_hatch_budget = 0;
static int g_hatch_sig_skip = 0;
// Pattern hatches that emitted ZERO lines, with enough detail to see why.
static int g_hatch_zero = 0;
static std::string g_hatch_zero_log;
static int g_mldr_nodes = 0, g_mldr_lines = 0, g_mldr_pts = 0, g_mldr_segs = 0;

// Decodes a HATCH/DWG name (UTF-16LE in R2007+, plain ASCII otherwise) into an
// uppercased ASCII string. Used to recognise the "SOLID" pattern, which some
// files store as a named pattern with is_solid_fill unset.
static std::string decode_dwg_name(const char* name) {
  if (!name) return std::string();
  const unsigned char* p = (const unsigned char*)name;
  std::string s;
  const bool utf16 = (p[0] != 0 && p[1] == 0);
  if (utf16) {
    for (int i = 0; i < 64; i += 2) { if (p[i] == 0) break; s += (char)p[i]; }
  } else {
    for (int i = 0; i < 32; ++i) { if (p[i] == 0) break; s += (char)p[i]; }
  }
  for (auto& c : s) c = (char)std::toupper((unsigned char)c);
  return s;
}

// ── Linetype (dash pattern) table ────────────────────────────────────────────
// Dash patterns from the LTYPE table; entities reference them BYLAYER/BYBLOCK
// or directly. Lengths are in model units (× LTSCALE × entity ltype_scale).
struct PatElem {
  double len;
  bool draw;
  bool dot = false; // a DOT element → emit a fixed-size point, not a segment
};
static std::map<unsigned long long, std::vector<PatElem>> g_ltypes;
// Per layer-table index: pattern of the layer's linetype (nullptr = continuous).
static std::vector<const std::vector<PatElem>*> g_layer_pat;
// Pattern of the entity currently being emitted + running phase along it.
static const std::vector<PatElem>* g_cur_pat = nullptr;
static const std::vector<PatElem>* g_pat_override = nullptr; // INSERT's, for BYBLOCK
static double g_pat_scale = 1.0;
static double g_pat_phase = 0.0;
static double g_ltscale = 1.0;

static uint16_t entity_layer_idx(Dwg_Object* obj) {
  if (!obj || !obj->tio.entity || !obj->tio.entity->layer) return 0;
  auto it = g_layer_idx.find(
      (unsigned long long)obj->tio.entity->layer->absolute_ref);
  uint16_t idx = (it == g_layer_idx.end()) ? 0 : it->second;
  // CAD semantics: block contents on layer "0" inherit the INSERT's layer.
  if (idx == g_layer0_idx && g_layer_override != 0) return g_layer_override;
  return idx;
}

// ── Per-entity color resolution ───────────────────────────────────────────────
// CMC method semantics (see Dwg_Color_Method): 0xC0=BYLAYER 0xC1=BYBLOCK
// 0xC2=ACI-index (index may live in the low byte of rgb) 0xC3=TRUECOLOR.

// Unified CMC resolution. Measured reality (raw dumps from real files):
//   method 0xC3 + payload < 0x100  → ACI index (0 = BYBLOCK, 0x100 = BYLAYER)
//   method 0xC3 + payload >= 0x100 → writer put a real RGB there
//   method 0xC2                    → truecolor RGB in the low 24 bits
//   method 0xC0 / 0xC1             → BYLAYER / BYBLOCK
//   method 0 (legacy, pre-R2004)   → plain `index` field (256 = BYLAYER)
enum CmcKind { CMC_RGB, CMC_BYLAYER, CMC_BYBLOCK };

static CmcKind cmc_resolve(const Dwg_Color& c, uint32_t* out_rgb) {
  *out_rgb = 0xFFFFFF;
  switch (c.method) {
    case 0xC2: // truecolor
      *out_rgb = (uint32_t)(c.rgb & 0xFFFFFF);
      return CMC_RGB;
    case 0xC3: { // indexed (usually); some writers store rgb here
      const uint32_t v = (uint32_t)(c.rgb & 0xFFFFFF);
      if (v == 0x100) return CMC_BYLAYER;
      if (v == 0) return CMC_BYBLOCK;
      *out_rgb = (v < 0x100) ? aci_to_rgb((int)v) : v;
      return CMC_RGB;
    }
    case 0xC1:
      return CMC_BYBLOCK;
    case 0xC0:
      return CMC_BYLAYER;
    case 0xC5: // foreground
      return CMC_RGB;
    default: { // legacy: only `index` is meaningful
      int idx = c.index;
      if (idx == 256) return CMC_BYLAYER;
      if (idx == 0) return CMC_BYBLOCK;
      if (idx < 0) idx = -idx; // layer "off" keeps the colour magnitude
      if (idx >= 1 && idx <= 255) {
        *out_rgb = aci_to_rgb(idx);
        return CMC_RGB;
      }
      return CMC_BYLAYER;
    }
  }
}

// Layer-table colors: BYLAYER/BYBLOCK make no sense on a layer → white.
static uint32_t table_color_rgb(const Dwg_Color& c) {
  uint32_t rgb;
  return cmc_resolve(c, &rgb) == CMC_RGB ? rgb : 0xFFFFFF;
}

static uint32_t resolve_entity_color(Dwg_Object* obj) {
  if (!obj || !obj->tio.entity) return 0xFFFFFF;
  uint32_t rgb;
  switch (cmc_resolve(obj->tio.entity->color, &rgb)) {
    case CMC_RGB:
      return rgb;
    case CMC_BYBLOCK: // inherit the enclosing INSERT's color
      return g_color_override;
    case CMC_BYLAYER:
    default:
      // Layer table lookup survives broken refs (built via handle map).
      if (!g_layers.empty()) return g_layers[entity_layer_idx(obj)].rgb;
      return 0xFFFFFF;
  }
}

// ── Text encoding ────────────────────────────────────────────────────────────
// R2007+ (AC1021+) DWGs store strings as UTF-16LE. LibreDWG keeps the raw
// pointer, so reading it as a C string stops at the first 0x00 byte (e.g. "22"
// becomes "2"). Convert wide text to UTF-8 when the file is R2007+.
static bool g_wide_text = false;
// Handles of BLOCK_HEADERs that were actually expanded via an INSERT, so the
// orphan pass can render text-bearing blocks whose INSERTs failed to decode.
static std::set<unsigned long long> g_expanded_blocks;

static std::string utf16le_to_utf8(const uint16_t* w) {
  std::string out;
  if (!w) return out;
  for (size_t i = 0; w[i]; ++i) {
    uint32_t cp = w[i];
    if (cp >= 0xD800 && cp <= 0xDBFF && w[i + 1] >= 0xDC00 && w[i + 1] <= 0xDFFF) {
      cp = 0x10000 + ((cp - 0xD800) << 10) + (w[i + 1] - 0xDC00);
      ++i;
    }
    if (cp < 0x80) {
      out += (char)cp;
    } else if (cp < 0x800) {
      out += (char)(0xC0 | (cp >> 6));
      out += (char)(0x80 | (cp & 0x3F));
    } else if (cp < 0x10000) {
      out += (char)(0xE0 | (cp >> 12));
      out += (char)(0x80 | ((cp >> 6) & 0x3F));
      out += (char)(0x80 | (cp & 0x3F));
    } else {
      out += (char)(0xF0 | (cp >> 18));
      out += (char)(0x80 | ((cp >> 12) & 0x3F));
      out += (char)(0x80 | ((cp >> 6) & 0x3F));
      out += (char)(0x80 | (cp & 0x3F));
    }
  }
  return out;
}

// True if the buffer is already well-formed UTF-8 (with at least ASCII).
// Used to avoid double-converting strings LibreDWG already transcoded.
static bool is_valid_utf8(const unsigned char* p) {
  while (*p) {
    if (*p < 0x80) { ++p; continue; }
    int n = (*p >= 0xF0) ? 3 : (*p >= 0xE0) ? 2 : (*p >= 0xC0) ? 1 : -1;
    if (n < 0) return false;
    ++p;
    for (int i = 0; i < n; ++i, ++p)
      if ((*p & 0xC0) != 0x80) return false;
  }
  return true;
}

// Windows-1254 (Turkish) → UTF-8. Pre-R2007 DWGs store strings in the drawing
// codepage, not Unicode; Turkish drawings use CP1254, which is Latin-1 plus
// Ğ İ Ş ğ ı ş in six slots. Passing the raw bytes through as "UTF-8" turned
// every accented letter into the replacement box.
static std::string cp1254_to_utf8(const char* raw) {
  static const uint16_t hi[32] = {// 0x80..0x9F (Windows-125x common block)
      0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
      0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x008E, 0x008F,
      0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
      0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x009E, 0x0178};
  std::string out;
  for (const unsigned char* p = (const unsigned char*)raw; *p; ++p) {
    uint32_t cp = *p;
    if (cp >= 0x80 && cp <= 0x9F) cp = hi[cp - 0x80];
    else if (cp == 0xD0) cp = 0x011E;  // Ğ
    else if (cp == 0xDD) cp = 0x0130;  // İ
    else if (cp == 0xDE) cp = 0x015E;  // Ş
    else if (cp == 0xF0) cp = 0x011F;  // ğ
    else if (cp == 0xFD) cp = 0x0131;  // ı
    else if (cp == 0xFE) cp = 0x015F;  // ş
    // Remaining 0xA0..0xFF match Latin-1 == the Unicode code point.
    if (cp < 0x80) {
      out += (char)cp;
    } else if (cp < 0x800) {
      out += (char)(0xC0 | (cp >> 6));
      out += (char)(0x80 | (cp & 0x3F));
    } else {
      out += (char)(0xE0 | (cp >> 12));
      out += (char)(0x80 | ((cp >> 6) & 0x3F));
      out += (char)(0x80 | (cp & 0x3F));
    }
  }
  return out;
}

static std::string dwg_text_to_utf8(const char* raw) {
  if (!raw) return "";
  if (g_wide_text) return utf16le_to_utf8(reinterpret_cast<const uint16_t*>(raw));
  // Pure ASCII or already-valid UTF-8 passes through; anything else is the
  // drawing codepage (CP1254 for Turkish drawings).
  if (is_valid_utf8((const unsigned char*)raw)) return std::string(raw);
  return cp1254_to_utf8(raw);
}

// ── MTEXT format-code stripper + inline-height parser ────────────────────────

// Returns the first absolute \H<n>; height found in raw MTEXT, or 0.0 if none.
static double parse_mtext_inline_height(const char* raw) {
  if (!raw) return 0.0;
  for (const char* p = raw; *p; ++p) {
    if (*p == '\\' && (*(p+1) == 'H' || *(p+1) == 'h')) {
      p += 2;
      char buf[32]; int i = 0;
      while (*p && *p != ';' && *p != 'x' && i < 30) buf[i++] = *p++;
      buf[i] = '\0';
      // Only absolute heights (not relative \H0.5x;)
      if (*p != 'x') {
        double h = std::atof(buf);
        if (h > 0.0) return h;
      }
    }
  }
  return 0.0;
}

static std::string strip_mtext(const char* raw) {
  if (!raw) return "";
  std::string out;
  out.reserve(std::strlen(raw));
  const char* p = raw;
  while (*p) {
    if (*p == '\\') {
      ++p;
      if (!*p) break;
      char cmd = *p++;
      switch (cmd) {
        case 'P': case 'n': out += '\n'; break; // paragraph / line break
        case '~': out += ' '; break;
        case '\\': out += '\\'; break;
        case '{': out += '{'; break;
        case '}': out += '}'; break;
        case 'L': case 'l': case 'O': case 'o':
        case 'K': case 'k': break; // toggle codes
        case 'U': case 'M':
          // Unicode escape: \U+XXXX (and \M+NXXXX). Turkish chars in a
          // codepage-0 MTEXT run are stored this way; without decoding them the
          // old "skip to ;" ate the whole line (no ';' terminates \U+), so a
          // title collapsed to just its ASCII head + tail.
          if (*p == '+') {
            ++p;
            if (cmd == 'M' && std::isxdigit((unsigned char)*p)) ++p; // \M+N…
            char hx[5] = {0}; int hn = 0;
            while (hn < 4 && std::isxdigit((unsigned char)*p)) hx[hn++] = *p++;
            if (hn > 0) {
              uint32_t cp = (uint32_t)std::strtol(hx, nullptr, 16);
              if (cp < 0x80) out += (char)cp;
              else if (cp < 0x800) {
                out += (char)(0xC0 | (cp >> 6));
                out += (char)(0x80 | (cp & 0x3F));
              } else {
                out += (char)(0xE0 | (cp >> 12));
                out += (char)(0x80 | ((cp >> 6) & 0x3F));
                out += (char)(0x80 | (cp & 0x3F));
              }
            }
          } else {
            while (*p && *p != ';') ++p;
            if (*p == ';') ++p;
          }
          break;
        default:
          while (*p && *p != ';') ++p;
          if (*p == ';') ++p;
          break;
      }
    } else if (*p == '{' || *p == '}') {
      ++p;
    } else {
      out += *p++;
    }
  }
  return out;
}

// Splits stripped MTEXT (with '\n' paragraph breaks) into display lines, word-
// wrapping each paragraph to maxChars (0 = no wrap, just split on '\n'). This is
// what restores AutoCAD's 2–3 line callouts that we were drawing as one long
// line. Wrapping is by byte count (good enough; multi-byte UTF-8 wraps a touch
// early, which is harmless).
static std::vector<std::string> wrap_mtext_lines(const std::string& s,
                                                 int maxChars) {
  std::vector<std::string> lines;
  size_t start = 0;
  while (start <= s.size()) {
    size_t nl = s.find('\n', start);
    const std::string para =
        s.substr(start, nl == std::string::npos ? std::string::npos : nl - start);
    if (maxChars <= 0) {
      lines.push_back(para);
    } else {
      std::string cur;
      size_t i = 0;
      while (i < para.size()) {
        const size_t sp = para.find(' ', i);
        const std::string word =
            para.substr(i, sp == std::string::npos ? std::string::npos : sp - i);
        if (cur.empty())
          cur = word;
        else if ((int)(cur.size() + 1 + word.size()) <= maxChars)
          cur += ' ' + word;
        else { lines.push_back(cur); cur = word; }
        if (sp == std::string::npos) break;
        i = sp + 1;
      }
      lines.push_back(cur);
    }
    if (nl == std::string::npos) break;
    start = nl + 1;
  }
  return lines;
}

static bool is_dimension_placeholder(const char* raw) {
  if (!raw) return true;
  while (*raw == ' ' || *raw == '\t' || *raw == '\r' || *raw == '\n') ++raw;
  return raw[0] == '\0' ||
         (raw[0] == '<' && raw[1] == '>' && raw[2] == '\0');
}

// ── Transform (translate + 2×2 matrix) ───────────────────────────────────────

struct XForm {
  double tx = 0, ty = 0;
  double m00 = 1, m01 = 0, m10 = 0, m11 = 1;
};

static std::pair<double,double> xform_pt(const XForm& xf, double x, double y) {
  return { xf.tx + x * xf.m00 + y * xf.m01,
           xf.ty + x * xf.m10 + y * xf.m11 };
}

static double xform_scale(const XForm& xf) {
  return std::sqrt(xf.m00 * xf.m00 + xf.m10 * xf.m10);
}

static double xform_rotation(const XForm& xf) {
  return std::atan2(xf.m10, xf.m00);
}

static double cad_angle(double value) {
  if (!std::isfinite(value)) return 0.0;
  return std::abs(value) > kPi * 4.0 ? value * kPi / 180.0 : value;
}

static double normalize_arc_end(double start, double end) {
  while (end < start) end += kPi * 2.0;
  while (end - start > kPi * 2.0) end -= kPi * 2.0;
  if (end < start) end += kPi * 2.0;
  return end;
}

static XForm compose_xforms(const XForm& outer, const XForm& inner) {
  XForm r;
  r.tx  = outer.tx + inner.tx * outer.m00 + inner.ty * outer.m01;
  r.ty  = outer.ty + inner.tx * outer.m10 + inner.ty * outer.m11;
  r.m00 = outer.m00 * inner.m00 + outer.m01 * inner.m10;
  r.m01 = outer.m00 * inner.m01 + outer.m01 * inner.m11;
  r.m10 = outer.m10 * inner.m00 + outer.m11 * inner.m10;
  r.m11 = outer.m10 * inner.m01 + outer.m11 * inner.m11;
  return r;
}

static XForm make_insert_xform(double tx, double ty,
                                double sx, double sy, double rotation) {
  if (!std::isfinite(sx) || std::abs(sx) < 1e-15) sx = 1.0;
  if (!std::isfinite(sy) || std::abs(sy) < 1e-15) sy = 1.0;
  if (!std::isfinite(rotation)) rotation = 0.0;
  double c = std::cos(rotation), s = std::sin(rotation);
  XForm xf;
  xf.tx  = std::isfinite(tx) ? tx : 0;
  xf.ty  = std::isfinite(ty) ? ty : 0;
  xf.m00 = sx * c; xf.m01 = -sy * s;
  xf.m10 = sx * s; xf.m11 =  sy * c;
  return xf;
}

// AutoCAD mirrors 2D geometry by flipping an entity's extrusion to (0,0,-1) — a
// left-handed OCS — rather than by a negative INSERT scale. For OCS-based
// entities (ARC, CIRCLE, LWPOLYLINE, POLYLINE_2D, SOLID) the arbitrary-axis
// algorithm with normal (0,0,-1) maps a stored point (x,y) to WCS (-x, y).
// Ignoring it drew every arc of a mirrored furniture block on the wrong side,
// scrambling it into a scribble. Flip X when the extrusion points down.
static inline double ocs_x(double x, double ez) { return ez < 0 ? -x : x; }

// ── Binary appenders ─────────────────────────────────────────────────────────
// Geometry is streamed as packed little-endian binary instead of JSON: a JSON
// scene for a large drawing reaches ~100 MB and OOMs the platform channel,
// whereas the binary form is ~10x smaller and needs no text parsing in Dart.

static inline void put_f32(std::ostringstream& o, double v) {
  float f = (float)safe_number(v, 0.0);
  o.write(reinterpret_cast<const char*>(&f), 4);
}
static inline void put_u32(std::ostringstream& o, uint32_t v) {
  o.write(reinterpret_cast<const char*>(&v), 4);
}
static inline void put_u16(std::ostringstream& o, uint16_t v) {
  o.write(reinterpret_cast<const char*>(&v), 2);
}
static inline void put_u8(std::ostringstream& o, uint8_t v) {
  o.write(reinterpret_cast<const char*>(&v), 1);
}

static void append_line_solid(std::ostringstream& j,
                              double x1, double y1, double x2, double y2,
                              uint32_t color, int& count) {
  if (count >= kMaxLines) return;
  put_f32(j, x1); put_f32(j, y1); put_f32(j, x2); put_f32(j, y2);
  put_u32(j, color);
  put_u16(j, g_cur_layer);
  ++count;
}

// Emits the segment, expanded into dashes when the current entity carries a
// non-continuous linetype. The dash phase runs along the whole entity, so
// polylines and tessellated arcs dash continuously across their segments.
static void append_line(std::ostringstream& j,
                        double x1, double y1, double x2, double y2,
                        uint32_t color, int& count) {
  if (count >= kMaxLines) return;
  if (!g_cur_pat || g_cur_pat->empty()) {
    append_line_solid(j, x1, y1, x2, y2, color, count);
    return;
  }
  const std::vector<PatElem>& pat = *g_cur_pat;
  double total = 0;
  for (const PatElem& e : pat) total += e.len;
  total *= g_pat_scale;
  const double dx = x2 - x1, dy = y2 - y1;
  const double L = std::sqrt(dx * dx + dy * dy);
  // Degenerate pattern, dot-like segment, or absurd dash counts → solid.
  if (total < 1e-9 || L < 1e-12 || L / total > 400.0) {
    append_line_solid(j, x1, y1, x2, y2, color, count);
    return;
  }
  const double ux = dx / L, uy = dy / L;

  // Locate the element the running phase falls into.
  double ph = std::fmod(g_pat_phase, total);
  size_t ei = 0;
  double erem = 0;
  for (size_t i = 0;; i = (i + 1) % pat.size()) {
    const double el = pat[i].len * g_pat_scale;
    if (ph <= el) { ei = i; erem = el - ph; break; }
    ph -= el;
  }

  double t = 0;
  int guard = 0;
  while (t < L - 1e-9 && count < kMaxLines && ++guard < 2000) {
    const double step = (erem < (L - t)) ? erem : (L - t);
    if (pat[ei].draw) {
      if (pat[ei].dot) {
        // A DOT element → emit a fixed-screen-size point (the painter draws it
        // as a round dot). A tiny segment would be dropped by the short-segment
        // cull once zoomed out, making the whole dotted line vanish.
        if (g_dot_count < kMaxDots) {
          put_f32(g_dot_bin, x1 + ux * t);
          put_f32(g_dot_bin, y1 + uy * t);
          put_u32(g_dot_bin, color);
          put_u16(g_dot_bin, g_cur_layer);
          ++g_dot_count;
        }
      } else if (step > 1e-9) {
        append_line_solid(j, x1 + ux * t, y1 + uy * t,
                          x1 + ux * (t + step), y1 + uy * (t + step),
                          color, count);
      }
    }
    t += step;
    erem -= step;
    if (erem <= 1e-9) {
      ei = (ei + 1) % pat.size();
      erem = pat[ei].len * g_pat_scale;
    }
  }
  g_pat_phase += L;
}

static void append_bulge_arc(std::ostringstream& j,
                             double x1, double y1, double x2, double y2,
                             double bulge, const XForm& xf,
                             uint32_t color, int& count) {
  if (!std::isfinite(bulge) || std::abs(bulge) < 1e-12) {
    auto [tx1,ty1] = xform_pt(xf, x1, y1);
    auto [tx2,ty2] = xform_pt(xf, x2, y2);
    append_line(j, tx1,ty1, tx2,ty2, color, count);
    return;
  }

  const double dx = x2 - x1;
  const double dy = y2 - y1;
  const double chord = std::sqrt(dx * dx + dy * dy);
  if (chord <= 1e-12) return;

  const double theta = 4.0 * std::atan(bulge);
  const double radius = chord * (1.0 + bulge * bulge) / (4.0 * std::abs(bulge));
  const double mx = (x1 + x2) * 0.5;
  const double my = (y1 + y2) * 0.5;
  const double nx = -dy / chord;
  const double ny = dx / chord;
  const double centerOffset = chord * (1.0 - bulge * bulge) / (4.0 * bulge);
  const double cx = mx + nx * centerOffset;
  const double cy = my + ny * centerOffset;
  const double start = std::atan2(y1 - cy, x1 - cx);
  const int segs = std::max(8, std::min(48, (int)(std::abs(theta) / (kPi / 24.0))));

  auto [px,py] = xform_pt(xf, x1, y1);
  for (int i = 1; i <= segs; ++i) {
    const double angle = start + theta * i / segs;
    auto [nxp,nyp] = xform_pt(xf,
        cx + std::cos(angle) * radius,
        cy + std::sin(angle) * radius);
    append_line(j, px,py, nxp,nyp, color, count);
    px = nxp;
    py = nyp;
  }
}

static void append_circle(std::ostringstream& j,
                          double cx, double cy, double r,
                          uint32_t color, int& count) {
  if (count >= kMaxCircles) return;
  put_f32(j, cx); put_f32(j, cy); put_f32(j, r);
  put_u32(j, color);
  put_u16(j, g_cur_layer);
  ++count;
}

// anchor byte: (valign << 4) | halign
//   halign: 0=left 1=center 2=right
//   valign: 0=baseline 1=bottom 2=middle 3=top
static void append_text(std::ostringstream& j,
                        double x, double y, double height, double rotation,
                        const std::string& value, uint32_t color, int& count,
                        uint8_t anchor = 0) {
  if (count >= kMaxTexts) return;
  const std::string trimmed = [&]{
    std::string s = value;
    size_t a = s.find_first_not_of(" \t\r\n");
    if (a == std::string::npos) return std::string{};
    size_t b = s.find_last_not_of(" \t\r\n");
    return s.substr(a, b - a + 1);
  }();
  if (trimmed.empty()) return;
  // Drop a label already emitted at the same spot (double-render guard).
  {
    const long kx = std::lround(x * 10.0);
    const long ky = std::lround(y * 10.0);
    std::string key = std::to_string(kx);
    key += ',';
    key += std::to_string(ky);
    key += ':';
    key += trimmed;
    if (!g_text_keys.insert(std::move(key)).second) return;
  }
  size_t len = trimmed.size();
  if (len > 0xFFFF) len = 0xFFFF;
  put_f32(j, x); put_f32(j, y);
  put_f32(j, height <= 0 ? 12.0 : height);
  put_f32(j, rotation);
  put_u32(j, color);
  put_u8(j, anchor);
  put_u16(j, g_cur_layer);
  put_u16(j, (uint16_t)len);
  j.write(trimmed.data(), (std::streamsize)len);
  ++count;
}

// ── Geometry renderers ────────────────────────────────────────────────────────

static void render_line(std::ostringstream& lj, Dwg_Entity_LINE* e,
                        const XForm& xf, uint32_t color, int& lc) {
  if (!e) return;
  auto [x1,y1] = xform_pt(xf, e->start.x, e->start.y);
  auto [x2,y2] = xform_pt(xf, e->end.x,   e->end.y);
  append_line(lj, x1,y1, x2,y2, color, lc);
}

static void render_arc(std::ostringstream& lj, Dwg_Entity_ARC* e,
                       const XForm& xf, uint32_t color, int& lc) {
  if (!e || e->radius <= 0) return;
  double start = cad_angle(e->start_angle);
  double end   = normalize_arc_end(start, cad_angle(e->end_angle));
  double sweep = end - start;
  // Segment count scales with ARC LENGTH (radius × sweep), ~1 segment per 2
  // model units, clamped [4,48]. Furniture blocks pack dozens of sub-unit
  // detail arcs (radius ~0.9); a flat 12–48 segments each turned a table into
  // a solid blob of thousands of micro-segments. Tiny arcs now get ~4 segments.
  int segs = (int)(e->radius * sweep / 2.0);
  if (segs < 4) segs = 4;
  if (segs > 48) segs = 48;
  const double ez = e->extrusion.z; // (0,0,-1) OCS ⇒ mirror across X (see ocs_x)
  auto [px,py] = xform_pt(xf,
      ocs_x(e->center.x + std::cos(start) * e->radius, ez),
      e->center.y + std::sin(start) * e->radius);
  for (int i = 1; i <= segs; ++i) {
    double angle = start + sweep * i / segs;
    auto [nx,ny] = xform_pt(xf,
        ocs_x(e->center.x + std::cos(angle) * e->radius, ez),
        e->center.y + std::sin(angle) * e->radius);
    append_line(lj, px,py, nx,ny, color, lc);
    px = nx; py = ny;
  }
}

static void render_circle(std::ostringstream& lj, std::ostringstream& cj,
                          Dwg_Entity_CIRCLE* e, const XForm& xf,
                          uint32_t color, int& lc, int& cc) {
  if (!e || e->radius <= 0) return;
  // Mirror-via-extrusion (0,0,-1) flips the centre across X; the circle is
  // symmetric so only the centre moves (see ocs_x).
  const double ecx = ocs_x(e->center.x, e->extrusion.z);
  // A dashed/dotted circle must be tessellated into segments so its linetype
  // pattern shows — a solid circle primitive can't carry a dash. Continuous
  // circles stay the cheap primitive (the common case).
  if (g_cur_pat && !g_cur_pat->empty()) {
    const int segs = 96; // smooth full circle, matches arc tessellation density
    auto [px,py] = xform_pt(xf, ecx + e->radius, e->center.y);
    for (int i = 1; i <= segs; ++i) {
      const double a = kPi * 2.0 * i / segs;
      auto [nx,ny] = xform_pt(xf,
          ecx + std::cos(a) * e->radius,
          e->center.y + std::sin(a) * e->radius);
      append_line(lj, px, py, nx, ny, color, lc);
      px = nx; py = ny;
    }
    return;
  }
  auto [cx,cy] = xform_pt(xf, ecx, e->center.y);
  double r = e->radius * xform_scale(xf);
  append_circle(cj, cx, cy, r, color, cc);
}

static void render_lwpolyline(std::ostringstream& lj, Dwg_Entity_LWPOLYLINE* e,
                               const XForm& xf, uint32_t color, int& lc) {
  if (!e || !e->points || e->num_points < 2) return;

  // Mirror-via-extrusion (0,0,-1): map each vertex X to WCS (-x) and flip the
  // bulge sign (a mirror turns CCW arcs into CW) so the arc bulges the correct
  // way. Without this a mirrored furniture outline scrambles (see ocs_x).
  const double ez = e->extrusion.z;
  const double bsign = (ez < 0) ? -1.0 : 1.0;
  for (BITCODE_BL i = 1; i < e->num_points; ++i) {
    append_bulge_arc(
        lj,
        ocs_x(e->points[i-1].x, ez), e->points[i-1].y,
        ocs_x(e->points[i  ].x, ez), e->points[i  ].y,
        bsign * ((e->bulges && i - 1 < e->num_bulges) ? e->bulges[i - 1] : 0.0),
        xf, color, lc);
  }
  if ((e->flag & FLAG_LWPOLYLINE_CLOSED) && e->num_points > 2) {
    append_bulge_arc(
        lj,
        ocs_x(e->points[e->num_points-1].x, ez), e->points[e->num_points-1].y,
        ocs_x(e->points[0].x, ez), e->points[0].y,
        bsign * ((e->bulges && e->num_points - 1 < e->num_bulges)
            ? e->bulges[e->num_points - 1]
            : 0.0),
        xf, color, lc);
  }
}

static void render_polyline2d(std::ostringstream& lj, Dwg_Object* obj,
                              const XForm& xf, uint32_t color, int& lc) {
  // Walk the owned VERTEX_2D sub-entities so we can honour per-vertex bulges
  // (arc segments). Falls back to nothing if vertices are unavailable.
  //
  // Spline/curve-fit polylines (smoothed contour lines) carry TWO kinds of
  // vertices in one stream: the displayed curve points and the control-frame
  // points (flag 16). AutoCAD hides the frame (SPLFRAME=0); connecting them
  // in sequence draws a long straight chord from the curve's end into the
  // frame — the "diagonal lines across the contours" artifact. Skip them.
  std::vector<double> vx, vy, vb;
  Dwg_Object* v = get_first_owned_subentity(obj);
  int guard = 0;
  while (v && guard < 200000) {
    if (dwg_object_get_fixedtype(v) == DWG_TYPE_VERTEX_2D && v->tio.entity) {
      Dwg_Entity_VERTEX_2D* vert = v->tio.entity->tio.VERTEX_2D;
      if (vert &&
          !(vert->flag & FLAG_VERTEX_SPLINE_FRAME_CONTROL_POINT)) {
        vx.push_back(vert->point.x);
        vy.push_back(vert->point.y);
        vb.push_back(vert->bulge);
      }
    }
    v = get_next_owned_subentity(obj, v);
    ++guard;
  }

  const size_t n = vx.size();
  if (n < 2) return;
  // Mirror-via-extrusion (0,0,-1): flip vertex X to WCS and the bulge sign.
  Dwg_Entity_POLYLINE_2D* pl = dwg_object_to_POLYLINE_2D(obj);
  const double ez = pl ? pl->extrusion.z : 1.0;
  const double bsign = (ez < 0) ? -1.0 : 1.0;
  for (size_t i = 1; i < n; ++i) {
    append_bulge_arc(lj, ocs_x(vx[i-1], ez), vy[i-1], ocs_x(vx[i], ez), vy[i],
                     bsign * vb[i-1], xf, color, lc);
  }

  if (pl && (pl->flag & FLAG_POLYLINE_CLOSED) && n > 2) {
    append_bulge_arc(lj, ocs_x(vx[n-1], ez), vy[n-1], ocs_x(vx[0], ez), vy[0],
                     bsign * vb[n-1], xf, color, lc);
  }
}

static void render_polyline3d(std::ostringstream& lj, Dwg_Object* obj,
                              const XForm& xf, uint32_t color, int& lc) {
  int err = 0;
  BITCODE_BL n = dwg_object_polyline_3d_get_numpoints(obj, &err);
  if (err || n < 2) return;
  dwg_point_3d* pts = dwg_object_polyline_3d_get_points(obj, &err);
  if (err || !pts) return;
  for (BITCODE_BL i = 1; i < n; ++i) {
    auto [x1,y1] = xform_pt(xf, pts[i-1].x, pts[i-1].y);
    auto [x2,y2] = xform_pt(xf, pts[i  ].x, pts[i  ].y);
    append_line(lj, x1,y1, x2,y2, color, lc);
  }
  std::free(pts);
}

// Approximate arc segment for hatch boundaries
static void arc_to_lines(std::ostringstream& lj,
                         double cx, double cy, double r,
                         double a0, double a1, bool ccw,
                         const XForm& xf, uint32_t color, int& lc) {
  if (r <= 0) return;
  a0 = cad_angle(a0);
  a1 = cad_angle(a1);
  if (!ccw && a1 > a0) a1 -= kPi * 2.0;
  if ( ccw && a1 < a0) a1 += kPi * 2.0;
  double sweep = std::abs(a1 - a0);
  int segs = (int)std::fmax(10.0, std::fmin(40.0, sweep / (kPi / 20.0)));
  auto [px,py] = xform_pt(xf, cx + std::cos(a0)*r, cy + std::sin(a0)*r);
  for (int i = 1; i <= segs; ++i) {
    double a = a0 + (a1 - a0) * i / segs;
    auto [nx,ny] = xform_pt(xf, cx + std::cos(a)*r, cy + std::sin(a)*r);
    append_line(lj, px,py, nx,ny, color, lc);
    px = nx; py = ny;
  }
}

// Repairs a corrupt solid-hatch boundary loop by splitting it at "connector"
// edges — edges far longer than the loop's own size. Some writers concatenate
// two disjoint contours (e.g. a glyph and a far-away fragment) into one path, or
// emit a stray outlier vertex; either way the loop acquires one or two giant
// edges, and filling it balloons into a huge grey wedge over the artwork
// (channel-letter signage "LA MER…"). Cutting at those edges restores the
// separate sub-contours, so each glyph fills on its own. A clean loop has no
// edge longer than 8× its median radius, so normal shapes — rectangles, glyphs,
// and the granite pattern's boundaries — are returned untouched (and this only
// runs for solid fills, never pattern hatches).
static void split_solid_loop(const std::vector<std::pair<double, double>>& poly,
                             std::vector<std::vector<std::pair<double, double>>>& out) {
  const size_t n = poly.size();
  if (n < 3) return;
  if (n < 4) { out.push_back(poly); return; }

  // Robust centre (median X, median Y) and median radius — unaffected by a
  // minority of outlier vertices.
  std::vector<double> xs(n), ys(n);
  for (size_t i = 0; i < n; ++i) { xs[i] = poly[i].first; ys[i] = poly[i].second; }
  std::nth_element(xs.begin(), xs.begin() + n / 2, xs.end());
  std::nth_element(ys.begin(), ys.begin() + n / 2, ys.end());
  const double cx = xs[n / 2], cy = ys[n / 2];
  std::vector<double> rad(n);
  for (size_t i = 0; i < n; ++i)
    rad[i] = std::hypot(poly[i].first - cx, poly[i].second - cy);
  std::vector<double> rs = rad;
  std::nth_element(rs.begin(), rs.begin() + n / 2, rs.end());
  double medr = rs[n / 2];
  if (medr < 1e-9) medr = 1e-9;
  const double cut = medr * 8.0;

  // Connector edges (poly[i] → poly[i+1], cyclic) longer than the threshold.
  std::vector<size_t> breaks;
  for (size_t i = 0; i < n; ++i) {
    const auto& a = poly[i];
    const auto& b = poly[(i + 1) % n];
    if (std::hypot(b.first - a.first, b.second - a.second) > cut) breaks.push_back(i);
  }
  if (breaks.empty()) { out.push_back(poly); return; }

  // Each arc spans the vertices between two consecutive connector edges. Keep
  // only arcs that sit near the loop's robust centre; arcs that lie far away
  // are the stray excursions that caused the wedge, so they are dropped. The
  // largest arc is always kept as a fallback (it is the real contour).
  std::vector<std::vector<std::pair<double, double>>> arcs;
  size_t bestArc = 0, bestSize = 0;
  for (size_t k = 0; k < breaks.size(); ++k) {
    const size_t start = (breaks[k] + 1) % n;
    const size_t end = breaks[(k + 1) % breaks.size()];
    std::vector<std::pair<double, double>> arc;
    for (size_t i = start;; i = (i + 1) % n) {
      arc.push_back(poly[i]);
      if (i == end || arc.size() > n) break;
    }
    if (arc.size() >= 3) {
      if (arc.size() > bestSize) { bestSize = arc.size(); bestArc = arcs.size(); }
      arcs.push_back(std::move(arc));
    }
  }
  if (arcs.empty()) { out.push_back(poly); return; }
  // Keep ALL sub-contours. We only split at the giant connector edges (to drop
  // the spurious filled strip those edges would draw); we no longer discard the
  // far-away arcs, because with even-odd filling every real sub-contour must
  // survive — dropping them was a nonzero-era hack that erased real geometry.
  (void)bestArc;
  for (size_t a = 0; a < arcs.size(); ++a)
    out.push_back(std::move(arcs[a]));
}

static void render_hatch(std::ostringstream& lj, Dwg_Entity_HATCH* e,
                         const XForm& xf, uint32_t color, int& lc) {
  ++g_hatch_seen;
  if (e && e->is_solid_fill) ++g_hatch_solid;
  // TRACE one user-reported missing hatch (LIST → Handle = 1a5c40) end to end.
  const bool trace = (g_cur_handle == 0x1a5c40);
  if (trace) g_hatch_zero_log += "\nTRACE reached solid=" +
      std::to_string(e ? (int)e->is_solid_fill : -1) +
      " paths=" + std::to_string(e ? (int)e->num_paths : -1);
  if (!e || !e->paths || e->num_paths == 0) return;

  // Fill only the patterns that the reference draws as a flat coloured area:
  //   • "SOLID"   — the literal solid pattern (some writers leave the flag unset)
  //   • "AR-SAND" — dense sand/stone texture; reads as a flat fill (the stone
  //                 cladding "Doğal Taş Kaplama").
  // The line/symbol motifs stay as drawn patterns, matching the reference:
  //   • ANSI31/32/33/36 — diagonal hatching (steel/section)
  //   • AR-CONC         — concrete dot/triangle stipple
  // Filling those as solid produced wrong white triangles/rectangles over the
  // section bands, so they are kept as patterns.
  const std::string pat = decode_dwg_name((const char*)e->name);
  const bool name_solid = pat == "SOLID" || pat == "AR-SAND";
  const bool solid_fill = e->is_solid_fill || name_solid;
  const int lc_entry = lc;
  // Log any pattern hatch that ends up emitting nothing (diagnosis).
  auto log_zero = [&](const char* why, size_t npolys, size_t npts) {
    if (solid_fill || g_hatch_zero++ >= 40) return;
    g_hatch_zero_log += "\nzero_hatch pat=" + pat + " why=" + std::string(why) +
        " paths=" + std::to_string((int)e->num_paths) +
        " polys=" + std::to_string((int)npolys) +
        " pts=" + std::to_string((int)npts) +
        " defs=" + std::to_string((int)e->num_deflines) +
        " layer=" + std::to_string((int)g_cur_layer);
  };

  // Collect the boundary loops as polygons (arcs/bulges tessellated). They are
  // drawn as outlines and used to clip the pattern lines (even-odd rule).
  typedef std::pair<double, double> Pt;
  std::vector<std::vector<Pt>> polys;
  size_t total_pts = 0;

  // Solid fills only emit polygons (no per-scanline clipping), so they can
  // afford far more loops/points. This matters for multi-loop solid hatches
  // such as channel-letter signage ("LA MER…"), where each glyph is one loop:
  // truncating at 16 loops leaves the even-odd fill open and it floods into a
  // grey blob. Pattern hatches keep the tighter bound that caps clipping cost.
  // Pattern hatches were capped at 16 loops, which silently dropped every loop
  // past the 16th — a single HATCH that shades many columns at once (one loop
  // per column) lost most of its columns. Raised so multi-region pattern
  // hatches render fully; the point budget still bounds worst-case clipping.
  const BITCODE_BL max_loops = solid_fill ? 1024 : 400;
  const size_t max_total_pts = solid_fill ? 40000 : 12000;

  for (BITCODE_BL pi = 0; pi < e->num_paths && pi < max_loops; ++pi) {
    Dwg_HATCH_Path* path = &e->paths[pi];
    if (!path) continue;
    BITCODE_BL n = path->num_segs_or_paths;
    if (n == 0) continue;
    std::vector<Pt> poly;

    auto tess_bulge_into = [&](double x1, double y1, double x2, double y2,
                               double b) {
      if (!std::isfinite(b) || std::abs(b) < 1e-12) {
        poly.emplace_back(x2, y2);
        return;
      }
      const double dx = x2 - x1, dy = y2 - y1;
      const double chord = std::sqrt(dx * dx + dy * dy);
      if (chord <= 1e-12) return;
      const double theta = 4.0 * std::atan(b);
      const double radius = chord * (1.0 + b * b) / (4.0 * std::abs(b));
      const double mx = (x1 + x2) * 0.5, my = (y1 + y2) * 0.5;
      const double nx = -dy / chord, ny = dx / chord;
      const double co = chord * (1.0 - b * b) / (4.0 * b);
      const double cx = mx + nx * co, cy = my + ny * co;
      const double start = std::atan2(y1 - cy, x1 - cx);
      const int segs =
          std::max(4, std::min(24, (int)(std::abs(theta) / (kPi / 12.0))));
      for (int i = 1; i <= segs; ++i) {
        const double a = start + theta * i / segs;
        poly.emplace_back(cx + std::cos(a) * radius, cy + std::sin(a) * radius);
      }
    };

    const bool is_poly = (path->flag & 2) != 0;
    if (is_poly && path->polyline_paths && n >= 2) {
      poly.emplace_back(path->polyline_paths[0].point.x,
                        path->polyline_paths[0].point.y);
      for (BITCODE_BL i = 1; i < n; ++i) {
        tess_bulge_into(path->polyline_paths[i - 1].point.x,
                        path->polyline_paths[i - 1].point.y,
                        path->polyline_paths[i].point.x,
                        path->polyline_paths[i].point.y,
                        path->polyline_paths[i - 1].bulge);
      }
      tess_bulge_into(path->polyline_paths[n - 1].point.x,
                      path->polyline_paths[n - 1].point.y,
                      path->polyline_paths[0].point.x,
                      path->polyline_paths[0].point.y,
                      path->polyline_paths[n - 1].bulge);
    } else if (!is_poly && path->segs && n >= 1) {
      for (BITCODE_BL si = 0; si < n; ++si) {
        Dwg_HATCH_PathSeg* seg = &path->segs[si];
        if (!seg) continue;
        if (seg->curve_type == 1) { // LINE
          if (poly.empty())
            poly.emplace_back(seg->first_endpoint.x, seg->first_endpoint.y);
          poly.emplace_back(seg->second_endpoint.x, seg->second_endpoint.y);
        } else if (seg->curve_type == 2) { // CIRCULAR ARC
          double a0 = cad_angle(seg->start_angle);
          double a1 = cad_angle(seg->end_angle);
          if (!seg->is_ccw && a1 > a0) a1 -= kPi * 2.0;
          if (seg->is_ccw && a1 < a0) a1 += kPi * 2.0;
          const double sweep = std::abs(a1 - a0);
          const int segs2 =
              std::max(6, std::min(32, (int)(sweep / (kPi / 16.0))));
          if (poly.empty())
            poly.emplace_back(seg->center.x + std::cos(a0) * seg->radius,
                              seg->center.y + std::sin(a0) * seg->radius);
          for (int i = 1; i <= segs2; ++i) {
            const double a = a0 + (a1 - a0) * i / segs2;
            poly.emplace_back(seg->center.x + std::cos(a) * seg->radius,
                              seg->center.y + std::sin(a) * seg->radius);
          }
        } else if (seg->curve_type == 3) { // ELLIPTICAL ARC
          // endpoint is the major half-axis vector (relative to center); the
          // minor axis is its perpendicular scaled by minor_major_ratio. Without
          // this the segment is dropped and the boundary loop closes with a
          // straight chord — which is exactly what turns curved channel-letter
          // glyphs into solid grey blobs.
          const double mjx = seg->endpoint.x, mjy = seg->endpoint.y;
          const double majLen = std::hypot(mjx, mjy);
          if (majLen < 1e-12) continue;
          const double minLen = majLen * seg->minor_major_ratio;
          const double ux = mjx / majLen, uy = mjy / majLen; // major unit
          const double vx = -uy, vy = ux;                    // minor unit
          double a0 = cad_angle(seg->start_angle);
          double a1 = cad_angle(seg->end_angle);
          if (!seg->is_ccw && a1 > a0) a1 -= kPi * 2.0;
          if (seg->is_ccw && a1 < a0) a1 += kPi * 2.0;
          const double sweep = std::abs(a1 - a0);
          const int segs3 = std::max(8, std::min(48, (int)(sweep / (kPi / 24.0))));
          auto ept = [&](double t) {
            const double c = std::cos(t), s = std::sin(t);
            return std::pair<double, double>(
                seg->center.x + ux * majLen * c + vx * minLen * s,
                seg->center.y + uy * majLen * c + vy * minLen * s);
          };
          if (poly.empty()) {
            auto p = ept(a0);
            poly.emplace_back(p.first, p.second);
          }
          for (int i = 1; i <= segs3; ++i) {
            auto p = ept(a0 + (a1 - a0) * i / segs3);
            poly.emplace_back(p.first, p.second);
          }
        } else if (seg->curve_type == 4) { // SPLINE
          // Prefer fit points (they lie on the curve); otherwise fall back to the
          // control polygon. Either way the loop is closed by the curve rather
          // than a straight chord, so glyph outlines stay sharp instead of
          // flooding into a blob.
          if (seg->num_fitpts >= 2 && seg->fitpts) {
            if (poly.empty())
              poly.emplace_back(seg->fitpts[0].x, seg->fitpts[0].y);
            for (BITCODE_BL i = 1; i < seg->num_fitpts; ++i)
              poly.emplace_back(seg->fitpts[i].x, seg->fitpts[i].y);
          } else if (seg->num_control_points >= 2 && seg->control_points) {
            if (poly.empty())
              poly.emplace_back(seg->control_points[0].point.x,
                                seg->control_points[0].point.y);
            for (BITCODE_BL i = 1; i < seg->num_control_points; ++i)
              poly.emplace_back(seg->control_points[i].point.x,
                                seg->control_points[i].point.y);
          }
        }
      }
    }

    if (poly.size() >= 3) {
      if (solid_fill) {
        // Repair corrupt boundaries (merged/disjoint contours, stray spikes)
        // by splitting at giant connector edges, so each glyph fills cleanly.
        std::vector<std::vector<Pt>> pieces;
        split_solid_loop(poly, pieces);
        for (auto& piece : pieces) {
          total_pts += piece.size();
          polys.push_back(std::move(piece));
        }
      } else {
        total_pts += poly.size();
        polys.push_back(std::move(poly));
      }
    }
    if (total_pts > max_total_pts) break;
  }
  if (trace) g_hatch_zero_log += " polys=" + std::to_string((int)polys.size()) +
      " pts=" + std::to_string((int)total_pts);
  if (polys.empty()) {
    if (trace) g_hatch_zero_log += " EXIT=no_polys";
    return;
  }

  // Skip the solid fill of a channel-letter / signage HATCH. Diagnostics on the
  // real drawing showed these are one HATCH packing dozens of SMALL boundary
  // loops (each glyph + counter, all ~50–150 units). AutoCAD renders the
  // reference with these letters as hollow outlines — never filled — so filling
  // the many small loops here only produced grey blobs and full-circle discs
  // (the loops are line+arc boundaries, some a full-turn arc). The line geometry
  // already draws the glyph outlines, so we drop just the fill. Large-loop solid
  // hatches (granite bases, landscape areas, pools) have a big median loop and
  // are kept. Guard ≥6 loops so simple single-region solids are never touched.
  // NOTE: only TRUE solid hatches (e->is_solid_fill) are signage glyphs; the
  // name-based fills (AR-CONC section fills etc.) are material areas and must
  // never be skipped even when grey and small-looped, so they are excluded here.
  if (e->is_solid_fill && polys.size() >= 6) {
    // Drop the fill of a true solid HATCH that is really a TEXT / signage mask:
    // a title-block background box or channel-letter sign. Its defining trait is
    // that MOST of its boundary loops are tiny glyph/counter contours; the fill
    // then only produces a grey box (with letter-shaped holes) that AutoCAD does
    // not draw — the letters already exist as line geometry. Wall/slab poché, by
    // contrast, is a handful of long thin bands (few or no tiny loops), so it is
    // kept. Judging by the FRACTION of small loops — not the max loop — lets a
    // title box (big outer box + many tiny letters) be skipped while a wall
    // (all medium bands) is filled. Only TRUE solid hatches reach here;
    // name-based material fills (AR-SAND/CONC) are is_solid_fill=false.
    int small = 0;
    for (const auto& poly : polys) {
      double x0 = 1e30, y0 = 1e30, x1 = -1e30, y1 = -1e30;
      for (const auto& p : poly) {
        x0 = std::min(x0, p.first);  x1 = std::max(x1, p.first);
        y0 = std::min(y0, p.second); y1 = std::max(y1, p.second);
      }
      if (std::hypot(x1 - x0, y1 - y0) < 300.0) ++small;
    }
    // Text/signage = MANY tiny glyph loops (a wall poché has only a few loops,
    // some of them small openings, so gate on both the count and the fraction).
    if (polys.size() >= 10 && small >= 8 &&
        (double)small / (double)polys.size() >= 0.7) {
      return; // mostly tiny loops → text/signage mask, don't fill
    }
  }

  // Boundary outlines — ONLY for pattern hatches. For a solid fill the filled
  // polygon already covers the area, so stroking the boundary is redundant; and
  // for self-intersecting glyph outlines (channel-letter signage) those strokes
  // pile up into a scribble on top of the clean fill. Pattern hatches still need
  // the outline because their interior is only sparse pattern lines.
  if (!solid_fill) {
    for (const auto& poly : polys) {
      for (size_t i = 1; i < poly.size(); ++i) {
        auto [x1, y1] = xform_pt(xf, poly[i - 1].first, poly[i - 1].second);
        auto [x2, y2] = xform_pt(xf, poly[i].first, poly[i].second);
        append_line(lj, x1, y1, x2, y2, color, lc);
      }
      auto [x1, y1] = xform_pt(xf, poly.back().first, poly.back().second);
      auto [x2, y2] = xform_pt(xf, poly.front().first, poly.front().second);
      append_line(lj, x1, y1, x2, y2, color, lc);
    }
  }

  // Solid fill → emit the boundary loops as a filled polygon (Flutter fills it
  // with even-odd winding, so nested inner loops become holes).
  if (solid_fill) {
    if (trace) g_hatch_zero_log += " EXIT=fill_emitted fillcount=" +
        std::to_string(g_fill_count) + "/" + std::to_string(kMaxFills);
    if (g_fill_count < kMaxFills) {
      uint16_t nloops = (uint16_t)(polys.size() > 0xFFFF ? 0xFFFF : polys.size());
      put_u32(g_fill_bin, color);
      put_u16(g_fill_bin, g_cur_layer);
      put_u16(g_fill_bin, nloops);
      for (uint16_t li2 = 0; li2 < nloops; ++li2) {
        const auto& poly = polys[li2];
        uint32_t np = (uint32_t)poly.size();
        put_u32(g_fill_bin, np);
        for (const auto& p : poly) {
          auto [px, py] = xform_pt(xf, p.first, p.second);
          put_f32(g_fill_bin, px);
          put_f32(g_fill_bin, py);
        }
      }
      ++g_fill_count;
    }
    return;
  }
  if (e->num_deflines == 0 || !e->deflines) {
    log_zero("nodefs", polys.size(), total_pts);
    return;
  }
  if (total_pts > 8000) { ++g_hatch_ptscap; return; } // bound clipping cost
  if (lc > (kMaxLines * 17) / 20) return; // protect the global line budget

  // Budget is split across the defline families — multi-angle patterns
  // (granite, concrete) need every family to show, not just the first.
  const int families = (e->num_deflines < 6) ? e->num_deflines : 6;
  // 9000 used to cut 4 big hatches mid-fill (bottom rows missing). 30k covers
  // the largest hatch in the 50MB reference file; row decimation above still
  // bounds pathological lattices, so the worst case stays small.
  const int fam_budget_base = 30000 / (families > 0 ? families : 1);
  for (BITCODE_BS di = 0; di < e->num_deflines && di < 6; ++di) {
    int fam_budget = fam_budget_base;
    Dwg_HATCH_DefLine* dl = &e->deflines[di];
    const double ang = safe_number(dl->angle, 0.0);
    const double dirx = std::cos(ang), diry = std::sin(ang);

    // The defline's own dash pattern (this is what turns continuous lines
    // into the sparse ticks/dots of granite/concrete-style patterns).
    std::vector<PatElem> dpat;
    double dtotal = 0;
    {
      double sum_abs = 0;
      for (BITCODE_BS dd = 0; dd < dl->num_dashes && dl->dashes; ++dd)
        sum_abs += std::abs(safe_number(dl->dashes[dd], 0.0));
      if (sum_abs > 1e-9) {
        const double dot_len = sum_abs * 0.04;
        bool has_gap = false;
        for (BITCODE_BS dd = 0; dd < dl->num_dashes; ++dd) {
          const double len = safe_number(dl->dashes[dd], 0.0);
          if (len > 1e-9) {
            dpat.push_back({len, true});
          } else if (len < -1e-9) {
            dpat.push_back({-len, false});
            has_gap = true;
          } else {
            dpat.push_back({dot_len, true}); // dot
          }
        }
        if (!has_gap) dpat.clear(); // no gaps → effectively continuous
        for (const PatElem& pe : dpat) dtotal += pe.len;
      }
    }
    // The stored offset is in pattern space → rotate by the line angle.
    const double ox = safe_number(dl->offset.x, 0.0);
    const double oy = safe_number(dl->offset.y, 0.0);
    const double wox = ox * dirx - oy * diry;
    const double woy = ox * diry + oy * dirx;
    const double nx = -diry, ny = dirx; // unit normal
    const double step = wox * nx + woy * ny;
    if (std::abs(step) < 1e-9) continue;
    const double bpx = safe_number(dl->pt0.x, 0.0);
    const double bpy = safe_number(dl->pt0.y, 0.0);
    const double bproj = bpx * nx + bpy * ny;

    double pmin = INFINITY, pmax = -INFINITY;
    for (const auto& poly : polys) {
      for (const Pt& p : poly) {
        const double pr = p.first * nx + p.second * ny;
        if (pr < pmin) pmin = pr;
        if (pr > pmax) pmax = pr;
      }
    }
    double klo = (pmin - bproj) / step, khi = (pmax - bproj) / step;
    if (klo > khi) std::swap(klo, khi);
    const long k0 = (long)std::ceil(klo - 1e-9);
    const long k1 = (long)std::floor(khi + 1e-9);
    // A dense lattice (same pattern over a LARGE area) used to be skipped
    // outright (`continue`), which made the identical hatch show on a small
    // room but silently vanish on a big landing. Decimate instead: draw every
    // Nth pattern line so the hatch stays visible at bounded cost.
    long kstep = 1;
    if (k1 - k0 > 3000) { kstep = (k1 - k0) / 3000 + 1; ++g_hatch_decim; }

    // Collects the boundary crossings for one pattern row.
    auto row_ts = [&](long k, std::vector<double>& out) {
      const double px = bpx + k * wox, py = bpy + k * woy;
      out.clear();
      for (const auto& poly : polys) {
        const size_t m = poly.size();
        for (size_t i = 0; i < m; ++i) {
          const Pt& A = poly[i];
          const Pt& B = poly[(i + 1) % m];
          const double ex = B.first - A.first, ey = B.second - A.second;
          const double denom = dirx * ey - diry * ex;
          if (std::abs(denom) < 1e-12) continue;
          const double qx = A.first - px, qy = A.second - py;
          const double s = (qx * diry - qy * dirx) / denom;
          if (s < 0.0 || s >= 1.0) continue;
          out.push_back((qx * ey - qy * ex) / denom);
        }
      }
    };

    std::vector<double> ts;

    // Estimate the family's output from ~32 sampled rows and widen the row
    // step to fit the budget UP FRONT. Cutting off when the budget ran out
    // (the old behaviour) filled the first regions of a multi-area hatch and
    // left the rest empty — "the same hatch shows here but not there".
    {
      const long rows = (k1 - k0) / kstep + 1;
      const long sstep = rows > 32 ? ((k1 - k0) / 32 + 1) : kstep;
      double est = 0;
      int samples = 0;
      int ndraw = 0;
      for (const PatElem& pe : dpat)
        if (pe.draw) ++ndraw;
      for (long k = k0; k <= k1; k += sstep) {
        row_ts(k, ts);
        std::sort(ts.begin(), ts.end());
        for (size_t j = 0; j + 1 < ts.size(); j += 2) {
          const double span = ts[j + 1] - ts[j];
          if (span <= 1e-9) continue;
          // A dashed row emits one segment per drawn dash, not one per span.
          est += (dpat.empty() || dtotal < 1e-9 || span / dtotal > 400.0)
                     ? 1.0
                     : std::max(1.0, span / dtotal * ndraw);
        }
        ++samples;
      }
      if (samples > 0) {
        const double est_total = est / samples * (double)rows;
        if (est_total > fam_budget) {
          kstep = (long)((double)kstep * (est_total / fam_budget)) + 1;
          ++g_hatch_decim;
        }
      }
    }

    bool fam_done = false;
    for (long k = k0; k <= k1 && !fam_done; k += kstep) {
      const double px = bpx + k * wox, py = bpy + k * woy;
      row_ts(k, ts);
      if (ts.size() < 2) continue;
      std::sort(ts.begin(), ts.end());
      for (size_t j = 0; j + 1 < ts.size() && !fam_done; j += 2) {
        const double t0 = ts[j], t1 = ts[j + 1];
        if (t1 - t0 < 1e-9) continue;
        if (dpat.empty() || dtotal < 1e-9 || (t1 - t0) / dtotal > 400.0) {
          // Continuous pattern line.
          auto [x1, y1] = xform_pt(xf, px + dirx * t0, py + diry * t0);
          auto [x2, y2] = xform_pt(xf, px + dirx * t1, py + diry * t1);
          append_line_solid(lj, x1, y1, x2, y2, color, lc);
          if (lc > (kMaxLines * 17) / 20) return;
          if (--fam_budget <= 0) { fam_done = true; ++g_hatch_budget; }
          continue;
        }
        // Dashed pattern line; phase is anchored at the line's lattice origin,
        // so the dir-component of the offset staggers rows like AutoCAD does.
        double ph = std::fmod(t0, dtotal);
        if (ph < 0) ph += dtotal;
        size_t ei = 0;
        double erem = 0;
        for (size_t i = 0;; i = (i + 1) % dpat.size()) {
          const double el = dpat[i].len;
          if (ph <= el) { ei = i; erem = el - ph; break; }
          ph -= el;
        }
        double t = t0;
        int guard = 0;
        while (t < t1 - 1e-9 && !fam_done && ++guard < 2000) {
          const double step = (erem < (t1 - t)) ? erem : (t1 - t);
          if (dpat[ei].draw && step > 1e-9) {
            auto [x1, y1] = xform_pt(xf, px + dirx * t, py + diry * t);
            auto [x2, y2] =
                xform_pt(xf, px + dirx * (t + step), py + diry * (t + step));
            append_line_solid(lj, x1, y1, x2, y2, color, lc);
            if (lc > (kMaxLines * 17) / 20) return;
            if (--fam_budget <= 0) { fam_done = true; ++g_hatch_budget; }
          }
          t += step;
          erem -= step;
          if (erem <= 1e-9) {
            ei = (ei + 1) % dpat.size();
            erem = dpat[ei].len;
          }
        }
      }
    }
  }
  // Sparse-output diagnosis: a pattern hatch that emitted almost nothing looks
  // "missing" to the user even though it technically drew. Log its pattern,
  // boundary bbox (world), pattern step and output count to see why.
  if (!solid_fill && lc - lc_entry < 12 && g_hatch_zero++ < 40) {
    double x0 = 1e300, y0 = 1e300, x1 = -1e300, y1 = -1e300;
    for (const auto& poly : polys)
      for (const Pt& p : poly) {
        auto [wx2, wy2] = xform_pt(xf, p.first, p.second);
        if (wx2 < x0) x0 = wx2;
        if (wx2 > x1) x1 = wx2;
        if (wy2 < y0) y0 = wy2;
        if (wy2 > y1) y1 = wy2;
      }
    double step0 = 0;
    if (e->num_deflines && e->deflines) {
      const Dwg_HATCH_DefLine* dl = &e->deflines[0];
      const double a = safe_number(dl->angle, 0.0);
      const double ox = safe_number(dl->offset.x, 0.0);
      const double oy = safe_number(dl->offset.y, 0.0);
      const double wox = ox * std::cos(a) - oy * std::sin(a);
      const double woy = ox * std::sin(a) + oy * std::cos(a);
      step0 = -std::sin(a) * wox + std::cos(a) * woy;
    }
    g_hatch_zero_log += "\nsparse_hatch pat=" + pat +
        " emitted=" + std::to_string(lc - lc_entry) +
        " bbox=(" + std::to_string((long)x0) + "," + std::to_string((long)y0) +
        ")-(" + std::to_string((long)x1) + "," + std::to_string((long)y1) +
        ") step=" + std::to_string(step0) +
        " defs=" + std::to_string((int)e->num_deflines) +
        " polys=" + std::to_string((int)polys.size());
  }
}

// ── NURBS spline evaluation (de Boor) ────────────────────────────────────────

// Finds the knot span index for parameter u.
static int nurbs_find_span(int n, int p, double u, const double* U) {
  if (u >= U[n + 1]) return n;          // last valid span
  if (u <= U[p])     return p;
  int low = p, high = n + 1, mid = (low + high) / 2;
  while (u < U[mid] || u >= U[mid + 1]) {
    if (u < U[mid]) high = mid; else low = mid;
    mid = (low + high) / 2;
  }
  return mid;
}

// Evaluates a (rational) B-spline at u into out_x/out_y using de Boor.
// ctrl points are homogeneous: cx/cy already multiplied by weight, cw = weight.
static void nurbs_eval(int span, int p, double u, const double* U,
                       const double* cx, const double* cy, const double* cw,
                       double& out_x, double& out_y) {
  // Local copies of the p+1 active control points.
  double dx[16], dy[16], dw[16];
  if (p > 15) p = 15;
  for (int j = 0; j <= p; ++j) {
    int idx = span - p + j;
    dx[j] = cx[idx]; dy[j] = cy[idx]; dw[j] = cw[idx];
  }
  for (int r = 1; r <= p; ++r) {
    for (int j = p; j >= r; --j) {
      double left  = U[span - p + j];
      double right = U[span + 1 + j - r];
      double denom = right - left;
      double a = (denom > 1e-12) ? (u - left) / denom : 0.0;
      dx[j] = (1.0 - a) * dx[j - 1] + a * dx[j];
      dy[j] = (1.0 - a) * dy[j - 1] + a * dy[j];
      dw[j] = (1.0 - a) * dw[j - 1] + a * dw[j];
    }
  }
  double w = (std::abs(dw[p]) > 1e-12) ? dw[p] : 1.0;
  out_x = dx[p] / w;
  out_y = dy[p] / w;
}

static void render_spline(std::ostringstream& lj, Dwg_Entity_SPLINE* sp,
                          const XForm& xf, uint32_t color, int& lc) {
  if (!sp) return;
  const int p = (int)sp->degree;
  const int nc = (int)sp->num_ctrl_pts;
  const int nk = (int)sp->num_knots;

  // Proper NURBS path: need a valid knot vector (nk == nc + p + 1).
  if (p >= 1 && nc > p && sp->ctrl_pts && sp->knots && nk == nc + p + 1) {
    std::vector<double> cx(nc), cy(nc), cw(nc);
    for (int i = 0; i < nc; ++i) {
      double w = sp->ctrl_pts[i].w;
      if (!(std::abs(w) > 1e-12)) w = 1.0;   // non-rational → weight 1
      cw[i] = w;
      cx[i] = sp->ctrl_pts[i].x * w;
      cy[i] = sp->ctrl_pts[i].y * w;
    }
    const double* U = sp->knots;
    const int n = nc - 1;
    const double u0 = U[p], u1 = U[n + 1];
    if (std::isfinite(u0) && std::isfinite(u1) && u1 > u0) {
      const int segs = std::max(20, std::min(96, nc * 6));
      double px = 0, py = 0;
      for (int i = 0; i <= segs; ++i) {
        double u = u0 + (u1 - u0) * i / segs;
        if (i == segs) u = u1;
        double ex, ey;
        int span = nurbs_find_span(n, p, u, U);
        nurbs_eval(span, p, u, U, cx.data(), cy.data(), cw.data(), ex, ey);
        auto [tx, ty] = xform_pt(xf, ex, ey);
        if (i > 0) append_line(lj, px, py, tx, ty, color, lc);
        px = tx; py = ty;
      }
      return;
    }
  }

  // Fallback 1: fit points lie on the curve → polyline through them.
  if (sp->num_fit_pts >= 2 && sp->fit_pts) {
    auto [px, py] = xform_pt(xf, sp->fit_pts[0].x, sp->fit_pts[0].y);
    for (BITCODE_BL i = 1; i < sp->num_fit_pts; ++i) {
      auto [nx, ny] = xform_pt(xf, sp->fit_pts[i].x, sp->fit_pts[i].y);
      append_line(lj, px, py, nx, ny, color, lc);
      px = nx; py = ny;
    }
    return;
  }

  // Fallback 2: control polygon.
  if (nc >= 2 && sp->ctrl_pts) {
    auto [px, py] = xform_pt(xf, sp->ctrl_pts[0].x, sp->ctrl_pts[0].y);
    for (int i = 1; i < nc; ++i) {
      auto [nx, ny] = xform_pt(xf, sp->ctrl_pts[i].x, sp->ctrl_pts[i].y);
      append_line(lj, px, py, nx, ny, color, lc);
      px = nx; py = ny;
    }
  }
}

// ── SOLID / TRACE (2D filled quad, bowtie corner order) ──────────────────────
static void render_solid(std::ostringstream& lj, Dwg_Entity_SOLID* e,
                         const XForm& xf, uint32_t color, int& lc) {
  if (!e) return;
  (void)lj; (void)lc;
  // SOLID/TRACE are AutoCAD's FILLED quads (the grey steel and brown stone
  // bands in section details, arrowheads, etc.) — so emit them as a filled
  // polygon, not just a 4-edge outline (outline left the bands looking empty).
  // DWG stores the 4 corners in bowtie order; perimeter is 1-2-4-3.
  const double ez = e->extrusion.z; // mirror-via-extrusion flips corner X (ocs_x)
  double xs[4], ys[4];
  std::tie(xs[0], ys[0]) = xform_pt(xf, ocs_x(e->corner1.x, ez), e->corner1.y);
  std::tie(xs[1], ys[1]) = xform_pt(xf, ocs_x(e->corner2.x, ez), e->corner2.y);
  std::tie(xs[2], ys[2]) = xform_pt(xf, ocs_x(e->corner4.x, ez), e->corner4.y);
  std::tie(xs[3], ys[3]) = xform_pt(xf, ocs_x(e->corner3.x, ez), e->corner3.y);
  if (g_fill_count < kMaxFills) {
    put_u32(g_fill_bin, color);
    put_u16(g_fill_bin, g_cur_layer);
    put_u16(g_fill_bin, 1); // single loop
    put_u32(g_fill_bin, 4); // four corners
    for (int i = 0; i < 4; ++i) { put_f32(g_fill_bin, xs[i]); put_f32(g_fill_bin, ys[i]); }
    ++g_fill_count;
  }
}

// ── 3DFACE (quad/triangle outline) ───────────────────────────────────────────
static void render_3dface(std::ostringstream& lj, Dwg_Entity__3DFACE* e,
                          const XForm& xf, uint32_t color, int& lc) {
  if (!e) return;
  double xs[4], ys[4];
  std::tie(xs[0], ys[0]) = xform_pt(xf, e->corner1.x, e->corner1.y);
  std::tie(xs[1], ys[1]) = xform_pt(xf, e->corner2.x, e->corner2.y);
  std::tie(xs[2], ys[2]) = xform_pt(xf, e->corner3.x, e->corner3.y);
  std::tie(xs[3], ys[3]) = xform_pt(xf, e->corner4.x, e->corner4.y);
  for (int i = 0; i < 4; ++i) {
    int n = (i + 1) % 4;
    if (xs[i] == xs[n] && ys[i] == ys[n]) continue; // collapsed edge (triangle)
    append_line(lj, xs[i], ys[i], xs[n], ys[n], color, lc);
  }
}

// ── LEADER (polyline through its points) ─────────────────────────────────────
static void render_leader(std::ostringstream& lj, Dwg_Entity_LEADER* e,
                          const XForm& xf, uint32_t color, int& lc) {
  ++g_ldr_seen;
  if (e) g_ldr_pts += (int)e->num_points;
  if (!e || !e->points || e->num_points < 2) return;
  ++g_ldr_drawn;
  auto [px, py] = xform_pt(xf, e->points[0].x, e->points[0].y);
  for (BITCODE_BL i = 1; i < e->num_points; ++i) {
    auto [nx, ny] = xform_pt(xf, e->points[i].x, e->points[i].y);
    append_line(lj, px, py, nx, ny, color, lc);
    px = nx; py = ny;
  }
}

// ── MLINE (approximate as a polyline through base vertices) ───────────────────
static void render_mline(std::ostringstream& lj, Dwg_Entity_MLINE* e,
                         const XForm& xf, uint32_t color, int& lc) {
  if (!e || !e->verts || e->num_verts < 2) return;
  auto [px, py] = xform_pt(xf, e->verts[0].vertex.x, e->verts[0].vertex.y);
  for (BITCODE_BS i = 1; i < e->num_verts; ++i) {
    auto [nx, ny] = xform_pt(xf, e->verts[i].vertex.x, e->verts[i].vertex.y);
    append_line(lj, px, py, nx, ny, color, lc);
    px = nx; py = ny;
  }
}

// ── POINT (small cross so it is visible) ─────────────────────────────────────
static void render_point(std::ostringstream& lj, Dwg_Entity_POINT* e,
                         const XForm& xf, uint32_t color, int& lc) {
  if (!e) return;
  auto [x, y] = xform_pt(xf, e->x, e->y);
  const double d = 0.5 * xform_scale(xf);
  if (!std::isfinite(d) || d <= 0) return;
  append_line(lj, x - d, y, x + d, y, color, lc);
  append_line(lj, x, y - d, x, y + d, color, lc);
}

// ── Forward declaration ───────────────────────────────────────────────────────

static void render_entity(
    std::ostringstream& lj, std::ostringstream& cj, std::ostringstream& tj,
    Dwg_Object* obj, const XForm& xf,
    int& lc, int& cc, int& tc, int depth);

// ── Block expansion ───────────────────────────────────────────────────────────

static void expand_block(
    std::ostringstream& lj, std::ostringstream& cj, std::ostringstream& tj,
    Dwg_Object* bh_obj, const XForm& xf,
    int& lc, int& cc, int& tc, int depth) {
  if (!bh_obj || depth > 16) return;

  // Prefer the BLOCK_HEADER's full entities[] handle array — the linked-list
  // walk (get_next_owned_entity) can stop early on some files, dropping the
  // text that lives near the end of a block while keeping the geometry.
  Dwg_Object_BLOCK_HEADER* bh =
      bh_obj->tio.object ? bh_obj->tio.object->tio.BLOCK_HEADER : nullptr;
  if (bh && bh->entities && bh->num_owned > 0) {
    Dwg_Data* dwgp = bh_obj->parent;
    std::set<unsigned long long> drawn; // per-expansion, for the fallback walk
    int unres = 0;
    for (BITCODE_BL i = 0; i < bh->num_owned && i < 2000000; ++i) {
      int e2 = 0;
      Dwg_Object* e = dwg_ref_get_object(bh->entities[i], &e2);
      // In some exports (ideCAD) the ref cannot be chased; resolve the absolute
      // handle directly — without this, those entities (often the text) vanish.
      if ((!e || e2) && dwgp && bh->entities[i] && bh->entities[i]->absolute_ref) {
        e = dwg_resolve_handle(dwgp, bh->entities[i]->absolute_ref);
        e2 = 0;
      }
      if (e && e->supertype == DWG_SUPERTYPE_ENTITY) {
        drawn.insert((unsigned long long)e->handle.value);
        render_entity(lj, cj, tj, e, xf, lc, cc, tc, depth);
      } else {
        ++g_dbg_ref_unres;
        ++unres;
        if (!e) {
          ++g_dbg_ref_null;
        } else {
          ++g_dbg_ref_wrong;
          const char* dx = dwg_object_get_dxfname(e);
          ++g_dbg_wrong_types[dx ? dx : ("supertype" +
              std::to_string((int)e->supertype))];
        }
      }
    }
    if (depth == 0) { g_dbg_ms_owned = (int)bh->num_owned; g_dbg_ms_unres = unres; }
    // Recovery: some AutoCAD exports leave tens of thousands of entities[]
    // refs unchasable (large multi-xref site plans), silently dropping most of
    // the drawing. The owned-entity linked list usually still reaches them, so
    // re-walk it and render only what the array walk missed.
    if (unres > 0) {
      Dwg_Object* e = get_first_owned_entity(bh_obj);
      int guard = 0;
      while (e && guard < 500000) {
        if (!drawn.count((unsigned long long)e->handle.value)) {
          ++g_dbg_ll_rec;
          render_entity(lj, cj, tj, e, xf, lc, cc, tc, depth);
        }
        e = get_next_owned_entity(bh_obj, e);
        ++guard;
      }
    }
    return;
  }

  Dwg_Object* e = get_first_owned_entity(bh_obj);
  int guard = 0;
  while (e && guard < 500000) {
    render_entity(lj, cj, tj, e, xf, lc, cc, tc, depth);
    e = get_next_owned_entity(bh_obj, e);
    ++guard;
  }
}

// ── Main entity dispatcher ────────────────────────────────────────────────────

static void render_entity(
    std::ostringstream& lj, std::ostringstream& cj, std::ostringstream& tj,
    Dwg_Object* obj, const XForm& xf,
    int& lc, int& cc, int& tc, int depth) {
  if (!obj) return;
  if (lc >= kMaxLines && cc >= kMaxCircles && tc >= kMaxTexts) return;

  const int ft = dwg_object_get_fixedtype(obj);
  {
    const char* dx = dwg_object_get_dxfname(obj);
    ++g_dbg_reach_types[dx ? dx : "?"];
    g_cur_handle = (unsigned long long)obj->handle.value;
    g_rendered_handles.insert(g_cur_handle);
  }
  const uint32_t color = resolve_entity_color(obj);
  g_cur_layer = entity_layer_idx(obj);

  // Linetype: BYLAYER(0) / BYBLOCK(1) / CONTINUOUS(2) / direct handle(3).
  g_cur_pat = nullptr;
  g_pat_phase = 0.0;
  {
    Dwg_Object_Entity* ent = obj->tio.entity;
    double es = safe_number(ent->ltype_scale, 1.0);
    if (es <= 1e-9) es = 1.0;
    g_pat_scale = g_ltscale * es;
    switch (ent->ltype_flags) {
      case 0: // BYLAYER
        if (g_cur_layer < g_layer_pat.size()) g_cur_pat = g_layer_pat[g_cur_layer];
        break;
      case 1: // BYBLOCK → the enclosing INSERT's pattern
        g_cur_pat = g_pat_override;
        break;
      case 3:
        if (ent->ltype && ent->ltype->absolute_ref) {
          auto it = g_ltypes.find((unsigned long long)ent->ltype->absolute_ref);
          if (it != g_ltypes.end()) g_cur_pat = &it->second;
        }
        break;
      default: // 2 = continuous
        break;
    }
  }

  // NOTE: never compare fixedtype against DWG_TYPE_*_r11 values — those legacy
  // enums collide with modern ones (LINE_r11==TEXT, POINT_r11==ATTRIB,
  // CIRCLE_r11==ATTDEF, ARC_r11==MINSERT) and silently swallow text entities.
  if (ft == DWG_TYPE_LINE) {
    render_line(lj, dwg_object_to_LINE(obj), xf, color, lc);

  } else if (ft == DWG_TYPE_ARC) {
    render_arc(lj, dwg_object_to_ARC(obj), xf, color, lc);

  } else if (ft == DWG_TYPE_CIRCLE) {
    render_circle(lj, cj, dwg_object_to_CIRCLE(obj), xf, color, lc, cc);

  } else if (ft == DWG_TYPE_POINT) {
    render_point(lj, obj->tio.entity->tio.POINT, xf, color, lc);

  } else if (ft == DWG_TYPE_SOLID || ft == DWG_TYPE_TRACE) {
    // SOLID and TRACE share the same 4-corner layout.
    render_solid(lj, (Dwg_Entity_SOLID*)obj->tio.entity->tio.SOLID, xf, color, lc);

  } else if (ft == DWG_TYPE__3DFACE) {
    render_3dface(lj, obj->tio.entity->tio._3DFACE, xf, color, lc);

  } else if (ft == DWG_TYPE_LEADER) {
    render_leader(lj, obj->tio.entity->tio.LEADER, xf, color, lc);

  } else if (ft == DWG_TYPE_MLINE) {
    render_mline(lj, obj->tio.entity->tio.MLINE, xf, color, lc);

  } else if (ft == DWG_TYPE_MULTILEADER) {
    Dwg_Entity_MULTILEADER* ml = obj->tio.entity->tio.MULTILEADER;
    ++g_mldr_seen;
    if (ml) {
      // MULTILEADER geometry. The stored leader line usually holds only the
      // ARROW point; the rest is derived: points → lastleaderlinepoint →
      // dogleg (lastpoint + dogleg_vector × dogleg_length) → text landing.
      double arrow = safe_number(ml->arrow_size, 0.0);
      if (arrow <= 0.0) arrow = safe_number(ml->ctx.text_height, 0.0);
      if (arrow <= 0.0) arrow = 2.5;
      double land_x = 0, land_y = 0; // dogleg end ≈ where the text sits
      bool has_landing = false;
      bool land_right = true;        // dogleg pointing +X → text on the right

      g_mldr_nodes += (int)ml->ctx.num_leaders;
      for (BITCODE_BL li = 0; li < ml->ctx.num_leaders && ml->ctx.leaders; ++li) {
        Dwg_LEADER_Node* nd = &ml->ctx.leaders[li];
        g_mldr_lines += (int)nd->num_lines;
        const bool has_last = nd->has_lastleaderlinepoint;
        const double lx = nd->lastleaderlinepoint.x;
        const double ly = nd->lastleaderlinepoint.y;
        // Dogleg segment after the last point.
        double dgx = lx, dgy = ly;
        if (has_last && nd->has_dogleg && nd->dogleg_length > 0) {
          dgx = lx + nd->dogleg_vector.x * nd->dogleg_length;
          dgy = ly + nd->dogleg_vector.y * nd->dogleg_length;
          land_right = nd->dogleg_vector.x >= 0;
        }
        if (has_last) {
          land_x = dgx; land_y = dgy; has_landing = true;
          if (dgx != lx || dgy != ly) {
            auto [x1,y1] = xform_pt(xf, lx, ly);
            auto [x2,y2] = xform_pt(xf, dgx, dgy);
            append_line(lj, x1,y1, x2,y2, color, lc);
            ++g_mldr_segs;
          }
        }
        for (BITCODE_BL si = 0; si < nd->num_lines && nd->lines; ++si) {
          Dwg_LEADER_Line* ln = &nd->lines[si];
          g_mldr_pts += (int)ln->num_points;
          if (!ln->points || ln->num_points == 0) continue;
          // Polyline through the stored points.
          for (BITCODE_BL pi = 1; pi < ln->num_points; ++pi) {
            auto [x1,y1] = xform_pt(xf, ln->points[pi-1].x, ln->points[pi-1].y);
            auto [x2,y2] = xform_pt(xf, ln->points[pi].x,   ln->points[pi].y);
            append_line(lj, x1,y1, x2,y2, color, lc);
            ++g_mldr_segs;
          }
          // Close the gap from the last stored point to the node's last point.
          const BITCODE_BL last = ln->num_points - 1;
          if (has_last &&
              (ln->points[last].x != lx || ln->points[last].y != ly)) {
            auto [x1,y1] = xform_pt(xf, ln->points[last].x, ln->points[last].y);
            auto [x2,y2] = xform_pt(xf, lx, ly);
            append_line(lj, x1,y1, x2,y2, color, lc);
            ++g_mldr_segs;
          }
          // Arrowhead (open V) at the first point, oriented along the line.
          double tipx = ln->points[0].x, tipy = ln->points[0].y;
          double tox, toy; // direction the line leaves the tip
          if (ln->num_points >= 2) { tox = ln->points[1].x; toy = ln->points[1].y; }
          else if (has_last)       { tox = lx;              toy = ly; }
          else continue;
          double dx = tox - tipx, dy = toy - tipy;
          const double len = std::sqrt(dx*dx + dy*dy);
          if (len < 1e-9) continue;
          dx /= len; dy /= len;
          // Open-V arrowhead at the tip, oriented along the leader line.
          const double s = arrow;
          const double c15 = 0.9659, s15 = 0.2588; // 15° wings
          auto [ax0, ay0] = xform_pt(xf, tipx, tipy);
          auto [ax1, ay1] = xform_pt(xf, tipx + s * (dx * c15 - dy * s15),
                                          tipy + s * (dy * c15 + dx * s15));
          auto [ax2, ay2] = xform_pt(xf, tipx + s * (dx * c15 + dy * s15),
                                          tipy + s * (dy * c15 - dx * s15));
          append_line(lj, ax0, ay0, ax1, ay1, color, lc);
          append_line(lj, ax0, ay0, ax2, ay2, color, lc);
          append_line(lj, ax1, ay1, ax2, ay2, color, lc);
        }
      }

      // Embedded MTEXT content (the callout text). Anchor it at the landing
      // end of the dogleg — that's where AutoCAD puts it; the stored content
      // location is unreliable in some writers.
      if (ml->ctx.has_content_txt && ml->ctx.content.txt.default_text) {
        std::string raw = dwg_text_to_utf8((const char*)ml->ctx.content.txt.default_text);
        std::string val = strip_mtext(raw.c_str());
        if (!val.empty()) {
          // ctx.text_height is the real character height; content.txt.height is
          // the text-box extent and varies with the wrapped content — unusable.
          double hh = safe_number(ml->ctx.text_height, 0.0);
          if (hh <= 0.0) hh = 2.5;
          double px, py;
          uint8_t anchor;
          if (has_landing) {
            const double gap = 0.6 * arrow;
            px = land_x + (land_right ? gap : -gap);
            py = land_y;
            // middle valign; halign left when text extends to the right
            anchor = (uint8_t)((2 << 4) | (land_right ? 0 : 2));
          } else {
            px = ml->ctx.content.txt.location.x;
            py = ml->ctx.content.txt.location.y;
            anchor = 0x30;
          }
          double rot = safe_number(ml->ctx.content.txt.rotation, 0.0) + xform_rotation(xf);
          const double hsc = hh * xform_scale(xf);
          // Multi-line callouts: \P breaks + word-wrap to the content box width,
          // so long descriptions render as the 2–3 lines AutoCAD shows instead
          // of one overflowing line.
          const double tw = safe_number(ml->ctx.content.txt.width, 0.0);
          const double cw = hh * 0.62;
          const int maxc = (tw > 1e-6 && cw > 1e-6)
                               ? std::max(4, (int)(tw / cw)) : 0;
          std::vector<std::string> lines = wrap_mtext_lines(val, maxc);
          double lsf = safe_number(ml->ctx.content.txt.line_spacing_factor, 1.0);
          if (lsf <= 0.1) lsf = 1.0;
          const double line_h_model = hh * 1.5 * lsf;
          const double th = safe_number(ml->ctx.content.txt.rotation, 0.0);
          const double ddx = std::sin(th) * line_h_model;  // "down" model space
          const double ddy = -std::cos(th) * line_h_model;
          const int va = anchor >> 4;                       // 3=top 2=mid 1=bottom
          const double off0 = (va == 2) ? -((double)(lines.size() - 1) / 2.0)
                            : (va == 1) ? -((double)(lines.size() - 1)) : 0.0;
          for (size_t li = 0; li < lines.size(); ++li) {
            if (lines[li].empty()) continue;
            const double f = (double)li + off0;
            auto [lx, ly] = xform_pt(xf, px + f * ddx, py + f * ddy);
            append_text(tj, lx, ly, hsc, rot, lines[li], color, tc, anchor);
          }
        }
      }
    }

  } else if (ft == DWG_TYPE_POLYLINE_2D) {
    render_polyline2d(lj, obj, xf, color, lc);

  } else if (ft == DWG_TYPE_POLYLINE_3D) {
    render_polyline3d(lj, obj, xf, color, lc);

  } else if (ft == DWG_TYPE_TEXT) {
    Dwg_Entity_TEXT* text = dwg_object_to_TEXT(obj);
    if (text && text->text_value) {
      std::string val = dwg_text_to_utf8((const char*)text->text_value);
      if (!val.empty()) {
        const int ha = text->horiz_alignment;
        const int va = text->vert_alignment;
        // Non-default alignment positions the text at alignment_pt (DXF 11).
        double px = text->ins_pt.x, py = text->ins_pt.y;
        if (ha != 0 || va != 0) { px = text->alignment_pt.x; py = text->alignment_pt.y; }
        uint8_t halign = (ha == 1 || ha == 4) ? 1 : (ha == 2 ? 2 : 0);
        uint8_t valign = (va >= 1 && va <= 3) ? (uint8_t)va : 0;
        auto [tx,ty] = xform_pt(xf, px, py);
        double h_raw = safe_number(text->height, 0.0);
        if (h_raw <= 0.0) h_raw = 2.5;
        double h   = h_raw * xform_scale(xf);
        double rot = safe_number(text->rotation, 0.0) + xform_rotation(xf);
        append_text(tj, tx, ty, h, rot, val, color, tc, (uint8_t)((valign << 4) | halign));
      }
    }

  } else if (ft == DWG_TYPE_MTEXT) {
    Dwg_Entity_MTEXT* mtext = dwg_object_to_MTEXT(obj);
    if (mtext && mtext->text) {
      std::string raw = dwg_text_to_utf8((const char*)mtext->text);
      if (!raw.empty()) {
        auto [tx,ty] = xform_pt(xf, mtext->ins_pt.x, mtext->ins_pt.y);
        double h_raw = safe_number(mtext->text_height, 0.0);
        if (h_raw <= 0.0) h_raw = parse_mtext_inline_height(raw.c_str());
        if (h_raw <= 0.0) {
          double rh = safe_number(mtext->rect_height, 0.0);
          h_raw = (rh > 0.0) ? rh * 0.35 : 2.5;
        }
        double h   = h_raw * xform_scale(xf);
        double rot = std::atan2(mtext->x_axis_dir.y, mtext->x_axis_dir.x) + xform_rotation(xf);
        std::string val = strip_mtext(raw.c_str());
        // MTEXT attachment (DXF 71) 1..9 → top/mid/bottom × left/center/right.
        int att = mtext->attachment; if (att < 1 || att > 9) att = 1;
        uint8_t halign = (uint8_t)((att - 1) % 3);              // 0=L 1=C 2=R
        int row = (att - 1) / 3;                                 // 0=top 1=mid 2=bot
        uint8_t valign = row == 0 ? 3 : (row == 1 ? 2 : 1);      // top/mid/bottom
        if (!val.empty()) {
          // Break into display lines: honour \P breaks (already '\n') AND word-
          // wrap to the MTEXT box width so multi-line callouts render as the
          // 2–3 lines AutoCAD shows, not one long overflowing line.
          const double rect_w = safe_number(mtext->rect_width, 0.0);
          const double cw = h_raw * 0.62;                  // approx glyph advance
          const int maxc = (rect_w > 1e-6 && cw > 1e-6)
                               ? std::max(4, (int)(rect_w / cw)) : 0;
          std::vector<std::string> lines = wrap_mtext_lines(val, maxc);
          double lsf = safe_number(mtext->linespace_factor, 1.0);
          if (lsf <= 0.1) lsf = 1.0;
          const double line_h_model = h_raw * 1.5 * lsf;   // model-space row pitch
          const double th = std::atan2(mtext->x_axis_dir.y, mtext->x_axis_dir.x);
          const double ddx = std::sin(th) * line_h_model;  // "down" in model space
          const double ddy = -std::cos(th) * line_h_model;
          const uint8_t anchor = (uint8_t)((valign << 4) | halign);
          for (size_t li = 0; li < lines.size(); ++li) {
            if (lines[li].empty()) continue;
            auto [lx, ly] = xform_pt(xf, mtext->ins_pt.x + (double)li * ddx,
                                         mtext->ins_pt.y + (double)li * ddy);
            append_text(tj, lx, ly, h, rot, lines[li], color, tc, anchor);
          }
        }
      }
    }

  } else if (ft == DWG_TYPE_HATCH) {
    Dwg_Entity_HATCH* hatch = dwg_object_to_HATCH(obj);
    render_hatch(lj, hatch, xf, color, lc);

  } else if (ft == DWG_TYPE_SPLINE) {
    render_spline(lj, dwg_object_to_SPLINE(obj), xf, color, lc);

  } else if (ft == DWG_TYPE_ELLIPSE) {
    Dwg_Entity_ELLIPSE* ell = dwg_object_to_ELLIPSE(obj);
    if (ell) {
      double ax = ell->sm_axis.x, ay = ell->sm_axis.y;
      double major_r = std::sqrt(ax*ax + ay*ay);
      if (major_r > 1e-15) {
        double minor_r = major_r * std::abs(safe_number(ell->axis_ratio, 1.0));
        double rot = std::atan2(ay, ax);
        double start = safe_number(ell->start_angle, 0.0);
        double end   = safe_number(ell->end_angle, kPi * 2.0);
        if (end <= start) end += kPi * 2.0;
        double sweep = end - start;
        // Segment count scales with the arc's actual LENGTH (major_r * sweep),
        // ~one segment per 8 model units, clamped [6,64]. A furniture drawing
        // packs hundreds of tiny decorative ellipses (upholstery buttons, knobs)
        // — giving each a flat 24–64 segments flooded a table with tens of
        // thousands of micro-segments that read as a solid blob. Small ellipses
        // now get a handful of segments; large ones stay smooth.
        int segs = (int)(major_r * sweep / 8.0);
        if (segs < 6) segs = 6;
        if (segs > 64) segs = 64;
        // ELLIPSE is a WCS-based entity: center and the major axis are already
        // in WCS, and the extrusion only sets the plane normal. AutoCAD mirrors
        // 2D geometry by flipping the normal to (0,0,-1) rather than by a
        // negative INSERT scale, which reverses the minor-axis direction
        // (minor = normal × major). Ignoring it drew every partial ellipse arc
        // of a mirrored furniture block on the wrong side — scrambling the
        // chair. Flip the minor sign when the normal points down.
        const double msign = (ell->extrusion.z < 0) ? -1.0 : 1.0;
        double cosr = std::cos(rot), sinr = std::sin(rot);
        auto ellpt = [&](double a) {
          double lx = ell->center.x + major_r*std::cos(a)*cosr - msign*minor_r*std::sin(a)*sinr;
          double ly = ell->center.y + major_r*std::cos(a)*sinr + msign*minor_r*std::sin(a)*cosr;
          return xform_pt(xf, lx, ly);
        };
        auto [px,py] = ellpt(start);
        for (int i = 1; i <= segs; ++i) {
          auto [nx,ny] = ellpt(start + sweep * i / segs);
          append_line(lj, px,py, nx,ny, color, lc);
          px = nx; py = ny;
        }
      }
    }

  } else if (ft == DWG_TYPE_ATTRIB) {
    Dwg_Entity_ATTRIB* attr = dwg_object_to_ATTRIB(obj);
    if (attr && attr->text_value) {
      std::string val = dwg_text_to_utf8((const char*)attr->text_value);
      if (!val.empty()) {
        const int ha = attr->horiz_alignment, va = attr->vert_alignment;
        double px = attr->ins_pt.x, py = attr->ins_pt.y;
        if (ha != 0 || va != 0) { px = attr->alignment_pt.x; py = attr->alignment_pt.y; }
        uint8_t halign = (ha == 1 || ha == 4) ? 1 : (ha == 2 ? 2 : 0);
        uint8_t valign = (va >= 1 && va <= 3) ? (uint8_t)va : 0;
        auto [tx,ty] = xform_pt(xf, px, py);
        double h_raw = safe_number(attr->height, 0.0);
        if (h_raw <= 0.0) h_raw = 2.5;
        double h   = h_raw * xform_scale(xf);
        double rot = safe_number(attr->rotation, 0.0) + xform_rotation(xf);
        append_text(tj, tx, ty, h, rot, val, color, tc, (uint8_t)((valign << 4) | halign));
      }
    }

  } else if (ft == DWG_TYPE_ATTDEF) {
    Dwg_Entity_ATTDEF* ad = dwg_object_to_ATTDEF(obj);
    if (ad && ad->default_value) {
      std::string val = dwg_text_to_utf8((const char*)ad->default_value);
      if (!val.empty()) {
        const int ha = ad->horiz_alignment, va = ad->vert_alignment;
        double px = ad->ins_pt.x, py = ad->ins_pt.y;
        if (ha != 0 || va != 0) { px = ad->alignment_pt.x; py = ad->alignment_pt.y; }
        uint8_t halign = (ha == 1 || ha == 4) ? 1 : (ha == 2 ? 2 : 0);
        uint8_t valign = (va >= 1 && va <= 3) ? (uint8_t)va : 0;
        auto [tx,ty] = xform_pt(xf, px, py);
        double h_raw = safe_number(ad->height, 0.0);
        if (h_raw <= 0.0) h_raw = 2.5;
        double h   = h_raw * xform_scale(xf);
        double rot = safe_number(ad->rotation, 0.0) + xform_rotation(xf);
        append_text(tj, tx, ty, h, rot, val, color, tc, (uint8_t)((valign << 4) | halign));
      }
    }

  } else if (
      ft == DWG_TYPE_DIMENSION_LINEAR   ||
      ft == DWG_TYPE_DIMENSION_ALIGNED  ||
      ft == DWG_TYPE_DIMENSION_ANG2LN   ||
      ft == DWG_TYPE_DIMENSION_ANG3PT   ||
      ft == DWG_TYPE_DIMENSION_RADIUS   ||
     ft == DWG_TYPE_DIMENSION_DIAMETER ||
     ft == DWG_TYPE_DIMENSION_ORDINATE) {
    // All DIMENSION types share DIMENSION_COMMON layout; use LINEAR as proxy
    // to reach the `block` handle (same offset in all variants).
    Dwg_Entity_DIMENSION_LINEAR* dim =
        (Dwg_Entity_DIMENSION_LINEAR*)obj->tio.entity->tio.DIMENSION_LINEAR;
    std::string dim_raw = dim ? dwg_text_to_utf8((const char*)dim->user_text) : "";
    if (dim && !is_dimension_placeholder(dim_raw.c_str())) {
      auto [tx,ty] = xform_pt(xf, dim->text_midpt.x, dim->text_midpt.y);
      std::string val = strip_mtext(dim_raw.c_str());
      if (!val.empty()) {
        // Dimension text is centred on text_midpt.
        append_text(tj, tx, ty, 2.5 * xform_scale(xf), xform_rotation(xf),
                    val, color, tc, (uint8_t)((2 << 4) | 1));
      }
    }
    if (dim && dim->block && depth < 8) {
      int err2 = 0;
      Dwg_Object* bh2 = dwg_ref_get_object(dim->block, &err2);
      if (bh2 && !err2) {
        // A dimension's lines/arrows live in an anonymous block whose children
        // are layer-0 + BYBLOCK (CAD semantics). Propagate the dimension's own
        // layer and color so they inherit them instead of defaulting to white —
        // exactly as the INSERT branch below does for its block.
        const uint16_t saved_layer = g_layer_override;
        const uint32_t saved_color = g_color_override;
        const uint16_t dim_layer = entity_layer_idx(obj);
        if (dim_layer != g_layer0_idx) g_layer_override = dim_layer;
        g_color_override = color;
        expand_block(lj, cj, tj, bh2, xf, lc, cc, tc, depth + 1);
        g_layer_override = saved_layer;
        g_color_override = saved_color;
      }
    }

  } else if (ft == DWG_TYPE_INSERT || ft == DWG_TYPE_MINSERT) {
    if (depth >= 16) return;
    // INSERT and MINSERT are distinct structs — dwg_object_to_INSERT returns
    // NULL for a MINSERT, which used to drop every block array (rows×cols of
    // repeated units, e.g. villas on a site plan) from the drawing entirely.
    double ipx = 0, ipy = 0, sx = 1, sy = 1, rot = 0, iez = 1.0;
    Dwg_Object_Ref* bh_ref = nullptr;
    int mrows = 1, mcols = 1;
    double rsp = 0, csp = 0;
    if (ft == DWG_TYPE_MINSERT) {
      Dwg_Entity_MINSERT* mi = dwg_object_to_MINSERT(obj);
      if (!mi || !mi->block_header) return;
      ipx = mi->ins_pt.x; ipy = mi->ins_pt.y;
      sx = safe_number(mi->scale.x, 1.0);
      sy = safe_number(mi->scale.y, 1.0);
      rot = mi->rotation;
      iez = mi->extrusion.z;
      bh_ref = mi->block_header;
      mrows = std::max(1, (int)mi->num_rows);
      mcols = std::max(1, (int)mi->num_cols);
      rsp = safe_number(mi->row_spacing, 0.0);
      csp = safe_number(mi->col_spacing, 0.0);
      // A corrupt count could explode the expansion; clamp to a sane grid.
      if (mrows > 256) mrows = 256;
      if (mcols > 256) mcols = 256;
    } else {
      Dwg_Entity_INSERT* ins = dwg_object_to_INSERT(obj);
      if (!ins || !ins->block_header) return;
      ipx = ins->ins_pt.x; ipy = ins->ins_pt.y;
      sx = safe_number(ins->scale.x, 1.0);
      sy = safe_number(ins->scale.y, 1.0);
      rot = ins->rotation;
      iez = ins->extrusion.z;
      bh_ref = ins->block_header;
    }
    int err = 0;
    Dwg_Object* bh_obj = dwg_ref_get_object(bh_ref, &err);
    // Fallback: some exports (ideCAD) leave refs that dwg_ref_get_object cannot
    // chase; resolve via the absolute handle instead.
    if ((!bh_obj || err) && obj->parent && bh_ref->absolute_ref) {
      bh_obj = dwg_resolve_handle(obj->parent, bh_ref->absolute_ref);
      err = 0;
    }
    if (!bh_obj || bh_obj->fixedtype != DWG_TYPE_BLOCK_HEADER ||
        !bh_obj->tio.object) {
      ++g_dbg_ins_unres;
      return;
    }
    g_expanded_blocks.insert((unsigned long long)bh_obj->handle.value);
    Dwg_Object_BLOCK_HEADER* bh = bh_obj->tio.object->tio.BLOCK_HEADER;
    if (bh && (bh->blkisxref || bh->xrefoverlaid)) { ++g_dbg_xref_skip; return; }
    // Mirror-via-extrusion on the INSERT itself: with normal (0,0,-1) the whole
    // insert lives in a left-handed OCS — its insertion point, rotation and
    // block content are all expressed there, and OCS→WCS maps (x,y)→(-x,y).
    // Compose that mirror IN FRONT of the insert transform.
    XForm inner = make_insert_xform(ipx, ipy, sx, sy, rot);
    if (iez < 0) {
      XForm mir; // (x,y) → (-x,y)
      mir.m00 = -1.0;
      inner = compose_xforms(mir, inner);
    }
    // BLOCK BASE POINT: AutoCAD draws block content at
    //   ins_pt + R·S·(point − base_pt)
    // i.e. the definition is evaluated relative to the block's base point, not
    // the definition origin. Most blocks have base (0,0) so ignoring it went
    // unnoticed — but e.g. "KEYBOARD"/"IBMAT" (desk computer gear) keep their
    // geometry near (60,294) in definition space with the base point right
    // there; without the subtraction their content landed ~600 units away as
    // phantom furniture in the corridor while the desks lost their keyboards.
    // (Verified against accoreconsole ground truth on the tatilköyü file.)
    {
      const double bx = bh ? safe_number(bh->base_pt.x, 0.0) : 0.0;
      const double by = bh ? safe_number(bh->base_pt.y, 0.0) : 0.0;
      if (bx != 0.0 || by != 0.0) {
        XForm tb; // translate definition space by −base before scaling
        tb.tx = -bx;
        tb.ty = -by;
        inner = compose_xforms(inner, tb);
      }
    }
    const XForm base = compose_xforms(xf, inner);
    // Children on layer "0" inherit this INSERT's layer, and BYBLOCK children
    // inherit this INSERT's effective color (CAD semantics).
    const uint16_t saved_layer = g_layer_override;
    const uint32_t saved_color = g_color_override;
    const std::vector<PatElem>* saved_pat = g_pat_override;
    const uint16_t ins_layer = entity_layer_idx(obj);
    if (ins_layer != g_layer0_idx) g_layer_override = ins_layer;
    g_color_override = color;
    g_pat_override = g_cur_pat; // INSERT's own linetype, for BYBLOCK children
    // MINSERT spacing is applied in block coordinates (scaled + rotated with
    // the insert), matching AutoCAD/ezdxf semantics. Plain INSERT is the 1×1
    // case of the same loop.
    for (int r = 0; r < mrows; ++r) {
      for (int c = 0; c < mcols; ++c) {
        if (lc > (kMaxLines * 19) / 20) break;
        XForm inst = base;
        if (r != 0 || c != 0) {
          XForm off;
          off.tx = c * csp;
          off.ty = r * rsp;
          inst = compose_xforms(base, off);
        }
        expand_block(lj, cj, tj, bh_obj, inst, lc, cc, tc, depth + 1);
      }
    }
    g_layer_override = saved_layer;
    g_color_override = saved_color;
    g_pat_override = saved_pat;

    // Attached ATTRIBs (title-block field values, axis-bubble labels, etc.).
    // Use LibreDWG's own owned-subentity walk (resolves handles via dwg_ref_object).
    // ATTRIB positions are in world coordinates, so render with the outer xform.
    {
      Dwg_Object* sub = get_first_owned_subentity(obj);
      int g = 0;
      while (sub && g < 20000) {
        if (dwg_object_get_fixedtype(sub) == DWG_TYPE_ATTRIB) {
          render_entity(lj, cj, tj, sub, xf, lc, cc, tc, depth + 1);
        }
        sub = get_next_owned_subentity(obj, sub);
        ++g;
      }
    }

  } else {
    const char* dxf = dwg_object_get_dxfname(obj);
    if (dxf && std::strcmp(dxf, "LWPOLYLINE") == 0) {
      render_lwpolyline(lj, dwg_object_to_LWPOLYLINE(obj), xf, color, lc);
    }
  }
}

// ── Main parser ───────────────────────────────────────────────────────────────

// Reads the 6-byte DWG version string from the file header, e.g. "AC1032".
static std::string read_dwg_version_string(const char* file_path) {
  char buf[7] = {0};
  FILE* f = fopen(file_path, "rb");
  if (f) { fread(buf, 1, 6, f); fclose(f); }
  return buf;
}

// Binary scene format, little-endian:
//   u32 magic ('FDW1')
//   u32 errorFlag (0 ok, 1 critical decode error)
//   f32 minX, minY, maxX, maxY
//   u16 versionLen, <version bytes>
//   u16 insUnits ($INSUNITS: 0=unitless,1=in,2=ft,4=mm,5=cm,6=m,...)
//   u32 entityCount
//   u16 layerCount,  layerCount  * { u16 nameLen; bytes; u32 rgb; u8 visible;
//                                    i16 lineweight ($LWEIGHT code, <0=default) }
//   u32 lineCount,   lineCount   * { f32 x1,y1,x2,y2; u32 color; u16 layer }
//   u32 circleCount, circleCount * { f32 cx,cy,r;     u32 color; u16 layer }
//   u32 textCount,   textCount   * { f32 x,y,height,rot; u32 color; u8 anchor;
//                                    u16 layer; u16 len; bytes }
//   u32 fillCount,   fillCount   * { u32 color; u16 layer; u16 numLoops;
//                                    numLoops * { u32 numPts; pts[2×f32] } }
constexpr uint32_t kSceneMagic = 0x35574446; // "FDW5"

static void put_header(std::ostringstream& out, uint32_t err,
                       const std::string& ver,
                       double minX, double minY, double maxX, double maxY,
                       uint16_t insUnits) {
  put_u32(out, kSceneMagic);
  put_u32(out, err);
  put_f32(out, minX); put_f32(out, minY);
  put_f32(out, maxX); put_f32(out, maxY);
  uint16_t vlen = (uint16_t)std::min<size_t>(ver.size(), 0xFFFF);
  put_u16(out, vlen);
  out.write(ver.data(), (std::streamsize)vlen);
  put_u16(out, insUnits);
}

std::string parse_dwg_to_scene_json(const char* file_path, int* out_error) {
  using _clock = std::chrono::steady_clock;
  auto _ms = [](_clock::duration d) {
    return (long)std::chrono::duration_cast<std::chrono::milliseconds>(d).count();
  };
  const auto _tStart = _clock::now();

  // Read version before LibreDWG so we can always report it.
  const std::string ver = read_dwg_version_string(file_path);

  Dwg_Data dwg;
  std::memset(&dwg, 0, sizeof(Dwg_Data));

  const int error = dwg_read_file(file_path, &dwg);
  const auto _tParsed = _clock::now();
  if (out_error) *out_error = error;

  // Critical errors: file cannot be read at all.
  // Non-critical (< 128): CRC mismatch, unhandled classes, out-of-bounds values, etc.
  // DWG_ERR_NOTYETSUPPORTED (2): version may be newer than AC1032; try anyway.
  constexpr int kCritical = 0xFF80; // bits 7-15
  if (error & kCritical) {
    dwg_free(&dwg);
    std::ostringstream err;
    put_header(err, 1, ver, 0, 0, 100, 100, 0);
    put_u32(err, 0);   // entityCount
    put_u16(err, 0);   // layerCount
    put_u32(err, 0);   // lineCount
    put_u32(err, 0);   // circleCount
    put_u32(err, 0);   // textCount
    put_u32(err, 0);   // fillCount
    return err.str();
  }

  // R2007+ stores entity strings as UTF-16LE; remember so text is decoded right.
  g_wide_text = (dwg.header.version >= R_2007);
  g_expanded_blocks.clear();
  g_text_keys.clear();

  // Build the real layer table (name, color, visibility) and the handle→index
  // map used to tag every emitted entity with its AutoCAD layer.
  g_ldr_seen = g_ldr_drawn = g_ldr_pts = 0;
  g_mldr_seen = g_hatch_seen = g_hatch_solid = 0;
  g_hatch_ptscap = g_hatch_decim = g_hatch_budget = 0;
  g_hatch_sig_skip = 0;
  g_hatch_zero = 0;
  g_hatch_zero_log.clear();
  g_mldr_nodes = g_mldr_lines = g_mldr_pts = g_mldr_segs = 0;
  g_dbg_file_types.clear();
  g_dbg_reach_types.clear();
  g_dbg_xref_skip = g_dbg_ins_unres = g_dbg_ref_unres = 0;
  g_dbg_ll_rec = g_dbg_ms_rec = 0;
  g_dbg_ref_null = g_dbg_ref_wrong = 0;
  g_dbg_wrong_types.clear();
  g_dbg_ms_owned = g_dbg_ms_unres = 0;
  g_rendered_handles.clear();
  // Whole-file entity census by dxfname (includes entities inside every block
  // definition, used or not) — compared against g_dbg_reach_types in .timing.
  for (BITCODE_BL i = 0; i < dwg.num_objects; ++i) {
    Dwg_Object* o = &dwg.object[i];
    if (!o || o->supertype != DWG_SUPERTYPE_ENTITY) continue;
    const char* dx = dwg_object_get_dxfname(o);
    ++g_dbg_file_types[dx ? dx : "?"];
  }

  // Linetype dash patterns (LTYPE table). Done before layers, which refer to
  // linetypes by handle.
  g_ltypes.clear();
  g_cur_pat = nullptr;
  g_pat_override = nullptr;
  g_pat_phase = 0.0;
  g_ltscale = safe_number(dwg.header_vars.LTSCALE, 1.0);
  if (g_ltscale <= 1e-9) g_ltscale = 1.0;
  for (BITCODE_BL i = 0; i < dwg.num_objects; ++i) {
    Dwg_Object* o = &dwg.object[i];
    if (!o || o->supertype != DWG_SUPERTYPE_OBJECT) continue;
    if (o->fixedtype != DWG_TYPE_LTYPE || !o->tio.object) continue;
    Dwg_Object_LTYPE* lt = o->tio.object->tio.LTYPE;
    if (!lt || !lt->dashes || lt->numdashes < 2) continue;
    double total_abs = 0;
    for (int d = 0; d < lt->numdashes; ++d)
      total_abs += std::abs(safe_number(lt->dashes[d].length, 0.0));
    if (total_abs < 1e-9) continue; // continuous
    std::vector<PatElem> pat;
    bool has_gap = false;
    for (int d = 0; d < lt->numdashes; ++d) {
      const double len = safe_number(lt->dashes[d].length, 0.0);
      if (len > 1e-9) {
        pat.push_back({len, true});
      } else if (len < -1e-9) {
        pat.push_back({-len, false});
        has_gap = true;
      } else {
        // A zero-length "dot": mark it so append_line emits a fixed-size POINT
        // (not a tiny segment that the painter's short-segment cull drops when
        // zoomed out). The small reserved length just keeps the pattern spacing.
        pat.push_back({total_abs * 0.02, true, /*dot*/true});
      }
    }
    if (!has_gap || pat.empty()) continue; // no gaps → effectively continuous
    g_ltypes[(unsigned long long)o->handle.value] = std::move(pat);
  }

  g_layers.clear();
  g_layer_idx.clear();
  g_layer_pat.clear();
  g_layer0_idx = 0;
  g_layer_override = 0;
  g_color_override = 0xFFFFFF;
  g_cur_layer = 0;
  g_layers.push_back({"0", 0xFFFFFF, true, -1}); // index 0: fallback
  g_layer_pat.push_back(nullptr);
  for (BITCODE_BL i = 0; i < dwg.num_objects; ++i) {
    Dwg_Object* o = &dwg.object[i];
    if (!o || o->supertype != DWG_SUPERTYPE_OBJECT) continue;
    if (o->fixedtype != DWG_TYPE_LAYER || !o->tio.object) continue;
    Dwg_Object_LAYER* lay = o->tio.object->tio.LAYER;
    if (!lay || g_layers.size() >= 0xFFFF) continue;
    LayerInfo li;
    li.name = lay->name ? dwg_text_to_utf8((const char*)lay->name) : "";
    if (li.name.empty()) li.name = "?";
    li.rgb = table_color_rgb(lay->color);
    li.visible = !(lay->off || lay->frozen);
    li.lineweight = (int16_t)lay->linewt; // 1/100 mm code, or <0 for default
    const uint16_t idx = (uint16_t)g_layers.size();
    g_layer_idx[(unsigned long long)o->handle.value] = idx;
    if (li.name == "0") g_layer0_idx = idx;
    g_layers.push_back(li);
    // The layer's linetype pattern (for BYLAYER entities).
    const std::vector<PatElem>* lp = nullptr;
    if (lay->ltype && lay->ltype->absolute_ref) {
      auto lit = g_ltypes.find((unsigned long long)lay->ltype->absolute_ref);
      if (lit != g_ltypes.end()) lp = &lit->second;
    }
    g_layer_pat.push_back(lp);
  }

  const double min_x = safe_number(dwg_model_x_min(&dwg), 0);
  const double min_y = safe_number(dwg_model_y_min(&dwg), 0);
  const double max_x = safe_number(dwg_model_x_max(&dwg), 100);
  const double max_y = safe_number(dwg_model_y_max(&dwg), 100);
  const unsigned long entity_count =
      static_cast<unsigned long>(dwg_get_num_entities(&dwg));

  std::ostringstream lines_bin, circles_bin, texts_bin;
  int line_count = 0, circle_count = 0, text_count = 0;
  g_fill_bin.str("");
  g_fill_bin.clear();
  g_fill_count = 0;
  g_dot_bin.str("");
  g_dot_bin.clear();
  g_dot_count = 0;

  Dwg_Object* ms_obj = dwg_model_space_object(&dwg);
  if (ms_obj) {
    const XForm identity;
    // Use the same entities[]-array walk as blocks (complete list).
    expand_block(lines_bin, circles_bin, texts_bin, ms_obj, identity,
                 line_count, circle_count, text_count, 0);
  }

  // Recovery sweep: entities flagged as model-space content (entmode == 2)
  // that neither the entities[]-array walk nor the linked-list fallback
  // reached (their owner refs are unchasable in some AutoCAD site plans,
  // silently dropping most of the drawing). entmode==2 guarantees world
  // coordinates, so drawing them at identity is safe — unlike the orphan
  // block pass below, this cannot flood the scene with library garbage.
  {
    const XForm identity;
    for (BITCODE_BL i = 0; i < dwg.num_objects; ++i) {
      if (line_count > (kMaxLines * 19) / 20) break;
      Dwg_Object* o = &dwg.object[i];
      if (!o || o->supertype != DWG_SUPERTYPE_ENTITY || !o->tio.entity) continue;
      if (o->tio.entity->entmode != 2) continue;
      if (g_rendered_handles.count((unsigned long long)o->handle.value)) continue;
      ++g_dbg_ms_rec;
      render_entity(lines_bin, circles_bin, texts_bin, o, identity,
                    line_count, circle_count, text_count, 0);
    }
  }

  // Orphan pass: ideCAD-style exports wrap every element in its own block, and
  // some INSERTs referencing them fail to decode, so whole (mostly text-bearing)
  // blocks never get drawn. Those blocks store world coordinates (inserted at
  // origin, scale 1), so render any never-expanded, non-xref, named block whose
  // text sits inside the model extents.
  //
  // Gate: only run when the main pass clearly starved on text (the ideCAD
  // symptom). In normal AutoCAD files unused block definitions are legitimate
  // libraries — drawing them at origin floods the scene with garbage and burns
  // the line budget, hiding real geometry.
  int total_text_ents = 0;
  for (BITCODE_BL i = 0; i < dwg.num_objects; ++i) {
    Dwg_Object* o = &dwg.object[i];
    if (!o || o->supertype != DWG_SUPERTYPE_ENTITY) continue;
    const int t = dwg_object_get_fixedtype(o);
    if (t == DWG_TYPE_TEXT || t == DWG_TYPE_MTEXT) ++total_text_ents;
  }
  const bool text_starved =
      total_text_ents > 50 && text_count * 3 < total_text_ents;
  if (text_starved) {
    const XForm identity;
    const double mw = max_x - min_x, mh = max_y - min_y;
    const double mx0 = min_x - 0.5 * mw, mx1 = max_x + 0.5 * mw;
    const double my0 = min_y - 0.5 * mh, my1 = max_y + 0.5 * mh;
    if (ms_obj)
      g_expanded_blocks.insert((unsigned long long)ms_obj->handle.value);
    for (BITCODE_BL i = 0; i < dwg.num_objects; ++i) {
      // Never let orphan blocks starve the budget of real, placed geometry.
      if (line_count > (kMaxLines * 9) / 10) break;
      Dwg_Object* o = &dwg.object[i];
      if (!o || o->supertype != DWG_SUPERTYPE_OBJECT) continue;
      if (o->fixedtype != DWG_TYPE_BLOCK_HEADER || !o->tio.object) continue;
      if (g_expanded_blocks.count((unsigned long long)o->handle.value)) continue;
      Dwg_Object_BLOCK_HEADER* bh = o->tio.object->tio.BLOCK_HEADER;
      if (!bh || bh->blkisxref || bh->xrefoverlaid) continue;
      // Skip layout/anonymous blocks (*Model_Space, *Paper_Space, *D, *U...).
      std::string nm = bh->name ? dwg_text_to_utf8((const char*)bh->name) : "";
      if (nm.empty() || nm[0] == '*') continue;
      if (!bh->entities || bh->num_owned == 0) continue;
      // Only blocks holding text positioned inside the model extents.
      bool text_inside = false;
      for (BITCODE_BL k = 0; k < bh->num_owned && k < 20000 && !text_inside; ++k) {
        int e2 = 0;
        Dwg_Object* e = dwg_ref_get_object(bh->entities[k], &e2);
        if ((!e || e2) && bh->entities[k] && bh->entities[k]->absolute_ref)
          e = dwg_resolve_handle(&dwg, bh->entities[k]->absolute_ref);
        if (!e || e->supertype != DWG_SUPERTYPE_ENTITY || !e->tio.entity) continue;
        const int t = dwg_object_get_fixedtype(e);
        double px, py;
        if (t == DWG_TYPE_TEXT) {
          Dwg_Entity_TEXT* tx = e->tio.entity->tio.TEXT;
          if (!tx) continue;
          px = tx->ins_pt.x; py = tx->ins_pt.y;
        } else if (t == DWG_TYPE_MTEXT) {
          Dwg_Entity_MTEXT* mt = e->tio.entity->tio.MTEXT;
          if (!mt) continue;
          px = mt->ins_pt.x; py = mt->ins_pt.y;
        } else {
          continue;
        }
        if (px >= mx0 && px <= mx1 && py >= my0 && py <= my1) text_inside = true;
      }
      if (!text_inside) continue;
      expand_block(lines_bin, circles_bin, texts_bin, o, identity,
                   line_count, circle_count, text_count, 1);
    }
  }

  std::ostringstream out;
  // $INSUNITS lets the UI convert raw model lengths to mm/cm/m correctly.
  const uint16_t ins_units = (uint16_t)dwg.header_vars.INSUNITS;
  put_header(out, 0, ver, min_x, min_y, max_x, max_y, ins_units);
  put_u32(out, (uint32_t)entity_count);
  put_u16(out, (uint16_t)g_layers.size());
  for (const LayerInfo& li : g_layers) {
    const uint16_t nl = (uint16_t)std::min<size_t>(li.name.size(), 0xFFFF);
    put_u16(out, nl);
    out.write(li.name.data(), nl);
    put_u32(out, li.rgb);
    put_u8(out, li.visible ? 1 : 0);
    put_u16(out, (uint16_t)(int16_t)li.lineweight); // i16 lineweight code
  }
  put_u32(out, (uint32_t)line_count);   out << lines_bin.str();
  put_u32(out, (uint32_t)circle_count); out << circles_bin.str();
  put_u32(out, (uint32_t)text_count);   out << texts_bin.str();
  put_u32(out, (uint32_t)g_fill_count); out << g_fill_bin.str();
  // Dots section (appended last so older decoders simply stop after fills).
  put_u32(out, (uint32_t)g_dot_count);  out << g_dot_bin.str();

  const std::string result = out.str();
  const auto _tBuilt = _clock::now();
  g_timing = "read_ms=" + std::to_string(_ms(_tParsed - _tStart)) +
             " build_ms=" + std::to_string(_ms(_tBuilt - _tParsed)) +
             " total_ms=" + std::to_string(_ms(_tBuilt - _tStart)) +
             " lines=" + std::to_string(line_count) +
             " scene_mb=" + std::to_string(result.size() / (1024 * 1024));
  g_timing += "\nxref_skip=" + std::to_string(g_dbg_xref_skip) +
              " ins_unres=" + std::to_string(g_dbg_ins_unres) +
              " ref_unres=" + std::to_string(g_dbg_ref_unres) +
              " ll_rec=" + std::to_string(g_dbg_ll_rec) +
              " ms_rec=" + std::to_string(g_dbg_ms_rec);
  g_timing += "\nread_err=" + std::to_string(error) +
              " ref_null=" + std::to_string(g_dbg_ref_null) +
              " ref_wrong=" + std::to_string(g_dbg_ref_wrong) +
              " ms_owned=" + std::to_string(g_dbg_ms_owned) +
              " ms_unres=" + std::to_string(g_dbg_ms_unres) +
              " num_classes=" + std::to_string((int)dwg.num_classes);
  g_timing += "\nhatch_seen=" + std::to_string(g_hatch_seen) +
              " solid=" + std::to_string(g_hatch_solid) +
              " ptscap=" + std::to_string(g_hatch_ptscap) +
              " decimated=" + std::to_string(g_hatch_decim) +
              " budget_hit=" + std::to_string(g_hatch_budget) +
              " sig_skip=" + std::to_string(g_hatch_sig_skip) +
              " zero=" + std::to_string(g_hatch_zero);
  g_timing += g_hatch_zero_log;
  for (const auto& [name, n] : g_dbg_wrong_types)
    g_timing += "\nwrong_type " + name + ": " + std::to_string(n);
  for (BITCODE_BS ci = 0; ci < dwg.num_classes && ci < 200; ++ci) {
    const Dwg_Class& kl = dwg.dwg_class[ci];
    std::string dxn = kl.dxfname ? std::string(kl.dxfname) : "?";
    g_timing += "\nclass " + std::to_string((int)kl.number) + " " + dxn +
                " instances=" + std::to_string((int)kl.num_instances);
  }
  g_timing += "\ntype: file_count / reached_count";
  for (const auto& [name, n] : g_dbg_file_types) {
    const auto it = g_dbg_reach_types.find(name);
    g_timing += "\n" + name + ": " + std::to_string(n) + " / " +
                std::to_string(it == g_dbg_reach_types.end() ? 0 : it->second);
  }
  for (const auto& [name, n] : g_dbg_reach_types) {
    if (!g_dbg_file_types.count(name))
      g_timing += "\n" + name + ": 0 / " + std::to_string(n);
  }
  dwg_free(&dwg);
  return result;
}
#endif

// ── JNI entry points ──────────────────────────────────────────────────────────

}  // namespace

extern "C" JNIEXPORT jstring JNICALL
Java_com_example_dwgfast_NativeDwgBridge_nativeProbe(
    JNIEnv* env, jobject /* this */) {
#ifdef FASTDWG_WITH_LIBREDWG
  return env->NewStringUTF("FastDWG native bridge loaded with LibreDWG.");
#else
  return env->NewStringUTF("FastDWG native bridge loaded. LibreDWG is not linked yet.");
#endif
}

// Parses the DWG and writes the packed scene straight to outPath. Returning a
// path instead of a byte array keeps multi-MB scenes off the Java heap (the
// platform-channel copies used to OOM the app on large drawings).
extern "C" JNIEXPORT jboolean JNICALL
Java_com_example_dwgfast_NativeDwgBridge_nativePrepareDrawing(
    JNIEnv* env, jobject /* this */,
    jstring filePath, jstring name, jstring outPath) {
  const char* nativePath = env->GetStringUTFChars(filePath, nullptr);
  const char* nativeName = env->GetStringUTFChars(name, nullptr);
  const char* nativeOut = env->GetStringUTFChars(outPath, nullptr);

  std::string scene;
#ifdef FASTDWG_WITH_LIBREDWG
  // Guard the whole parse: a corrupt/unsupported DWG must never take the app
  // down. C++ exceptions and bad_alloc are caught here and reported as a failed
  // decode (the app then shows a friendly "couldn't open" screen). A hard
  // SIGSEGV inside LibreDWG can't be caught in-process, but exceptions/OOM —
  // the common failure modes — are.
  try {
    int dwg_err = 0;
    scene = parse_dwg_to_scene_json(nativePath, &dwg_err);
  } catch (...) {
    scene.clear(); // → ok stays false → app shows "couldn't open", no crash
  }
#endif

  bool ok = false;
  if (!scene.empty() && nativeOut) {
    FILE* f = fopen(nativeOut, "wb");
    if (f) {
      ok = fwrite(scene.data(), 1, scene.size(), f) == scene.size();
      fclose(f);
    }
#ifdef FASTDWG_WITH_LIBREDWG
    // Sidecar profiling file (outPath + ".timing") for diagnosing open speed.
    std::string tpath = std::string(nativeOut) + ".timing";
    FILE* tf = fopen(tpath.c_str(), "wb");
    if (tf) {
      fwrite(g_timing.data(), 1, g_timing.size(), tf);
      fclose(tf);
    }
#endif
  }

  env->ReleaseStringUTFChars(outPath, nativeOut);
  env->ReleaseStringUTFChars(name, nativeName);
  env->ReleaseStringUTFChars(filePath, nativePath);
  return ok ? JNI_TRUE : JNI_FALSE;
}
