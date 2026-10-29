/* ============================================================
   FPGA 多音色合成器 · 网页控制台
   ------------------------------------------------------------
   纯前端、无依赖、离线可用。
   - 串口：Web Serial API（Chrome / Edge 89+）
   - 协议：A5 5A | TYPE | LEN | PAYLOAD | CRC8
   - 115200 8N1（和 src/uart_rx.v / uart_tx.v 一致）

   本文件同时被 tools/protocol_test.js 用 Node require 做协议自测，
   所以 DOM 相关代码全部收在 initUI() 里，Node 环境下不会执行。
   ============================================================ */
'use strict';

/* ============================================================
   1. 常量 / 寄存器表（必须和 src/param_regs.v 完全一致）
   ============================================================ */
const BAUD = 115200;
const SAMPLE_RATE = 48828.125;          // 3.125MHz / 64

const SOF0 = 0xA5;
const SOF1 = 0x5A;
const T = {
  SET : 0x01,
  GET : 0x02,
  PING: 0x03,
  VAL : 0x81,
  TELEM: 0x82,
  PONG: 0x83,
};

const R = {
  VERSION : 0x01,
  TIMBRE  : 0x10,
  WAVE    : 0x11,
  FM_RATIO: 0x12,
  FM_DEPTH: 0x13,
  H1      : 0x14,
  H2      : 0x15,
  H3      : 0x16,
  H4      : 0x17,
  VEL_PRESS: 0x18,
  ONESHOT : 0x19,
  MONO    : 0x1A,
  GLIDE_EN: 0x1B,
  GLIDE_SHIFT: 0x1C,
  VIB_EN  : 0x1D,
  VIB_RATE: 0x1E,
  VIB_DEPTH: 0x1F,
  RATE    : 0x20,
  EXP     : 0x21,
  ATK     : 0x22,
  DEC     : 0x23,
  SUS     : 0x24,
  REL     : 0x25,
  TRANSPOSE: 0x26,
  OCTAVE  : 0x27,
  SUSTAIN : 0x28,
  UNISON_ON: 0x29, UNISON_LAYERS: 0x2A, UNISON_DETUNE: 0x2B, UNISON_MIX: 0x2C,
  PWM_WIDTH: 0x2D, PWM_RATE: 0x2E, PWM_DEPTH: 0x2F,
  MIX_SHIFT: 0x30,
  MASTER  : 0x31,
  MUTE    : 0x32,
  KV0     : 0x38,        // 0x38..0x3F
  // ---- 全局效果 / 均衡（0x50..0x6F）----
  ECHO_ON : 0x50, ECHO_TIME: 0x51, ECHO_FB: 0x52, ECHO_MIX: 0x53,
  REV_ON  : 0x54, REV_SIZE : 0x55, REV_DAMP: 0x56, REV_MIX : 0x57,
  CHO_ON  : 0x58, CHO_RATE : 0x59, CHO_DEPTH:0x5A, CHO_MIX : 0x5B,
  PHA_ON  : 0x5C, PHA_RATE : 0x5D, PHA_DEPTH:0x5E, PHA_FB  : 0x5F,
  PHA_MIX : 0x60,
  DRV_ON  : 0x61, DRV_DRIVE: 0x62, DRV_TONE: 0x63, DRV_MIX : 0x64,
  LIM_ON  : 0x65, LIM_TH   : 0x66, LIM_CEIL: 0x67, LIM_REL : 0x68,
  EQ_ON   : 0x69, EQ_LOW   : 0x6A, EQ_LMID : 0x6B, EQ_MID : 0x6C,
  EQ_HMID : 0x6D, EQ_HIGH  : 0x6E, EQ_OUT  : 0x6F,
  // ---- 32 声道参数（0x80..0x9F / 0xA0..0xBF）----
  CHA0    : 0x80,
  CHB0    : 0xA0,
  ADS_VEL : 0x40,
  ADS_RAW : 0x41,
  POLY    : 0x42,
  PEAK    : 0x43,
  OCT     : 0x44,
  KEYS    : 0x45,
  FLAGS   : 0x46,
  ADS_ERR : 0x47,
};

// 所有可写寄存器（连接时一次性读回）
const RANGE = (a, b) => Array.from({ length: b - a + 1 }, (_, i) => a + i);
const WRITABLE_REGS = [
  R.TIMBRE, R.WAVE, R.FM_RATIO, R.FM_DEPTH,
  R.H1, R.H2, R.H3, R.H4, R.VEL_PRESS, R.ONESHOT,
  R.MONO, R.GLIDE_EN, R.GLIDE_SHIFT, R.VIB_EN, R.VIB_RATE, R.VIB_DEPTH,
  R.TRANSPOSE, R.OCTAVE, R.SUSTAIN,
  ...RANGE(R.UNISON_ON, R.UNISON_MIX),
  ...RANGE(R.PWM_WIDTH, R.PWM_DEPTH),
  R.RATE, R.EXP, R.ATK, R.DEC, R.SUS, R.REL,
  R.MIX_SHIFT, R.MASTER, R.MUTE,
  R.KV0, R.KV0+1, R.KV0+2, R.KV0+3, R.KV0+4, R.KV0+5, R.KV0+6, R.KV0+7,
  ...RANGE(R.ECHO_ON, R.EQ_OUT),
  ...RANGE(R.CHA0, R.CHA0 + 31),
  ...RANGE(R.CHB0, R.CHB0 + 31),
];

const FM_RATIOS = [0.5, 1.0, 1.5, 2.0, 2.5, 3.0, 3.5, 4.0];
const HARM_BASE = [51, 33, 24, 17];
const HARM_NAMES = ['基波', '二次', '三次', '四次'];
const NOTES = ['C4', 'D4', 'E4', 'F4', 'G4', 'A4', 'B4', 'C5'];
const WAVE_NAMES = ['方波', '锯齿', '三角', '正弦', '钢琴(加法)', 'FM'];

// “自定义”是网页端的伪音色：不改 FPGA 的 TIMBRE，只把当前参数存到这一档
const CUSTOM_ID = 10;

// 10 个硬件音色 + 1 个网页自定义档
const TIMBRES = [
  { id: 0, name: '方波',   kind: '持续音',   color: '#8fa3ad' },
  { id: 1, name: '锯齿',   kind: '持续音',   color: '#38e1c6' },
  { id: 2, name: '三角',   kind: '持续音',   color: '#7aa2ff' },
  { id: 3, name: '正弦',   kind: '持续音',   color: '#b78cff' },
  { id: 4, name: '钢琴',   kind: '一次包络', color: '#ffc857' },
  { id: 5, name: '古筝',   kind: 'FM · 拨弦', color: '#ff9f7a' },
  { id: 6, name: '木琴',   kind: 'FM · 敲击', color: '#7de08b' },
  { id: 7, name: '单簧管', kind: 'FM · 持续', color: '#6ec7ff' },
  { id: 8, name: '颠琴',   kind: 'FM · 电钢', color: '#ffd36e' },
  { id: 9, name: '钟琴',   kind: 'FM · 钟',   color: '#9ff0ff' },
  { id: CUSTOM_ID, name: '自定义', kind: '手动编辑', color: '#ff9f7a' },
];

/* ============================================================
   2. 出厂预设（必须和 param_regs.v 的 f_* 函数一致）
   ============================================================ */
function preset(o) {
  return Object.assign({
    wave: 1, fmRatio: 1, fmDepth: 2,
    h: [0, 0, 0, 0],
    velPress: 0, oneshot: 0,
    rate: 0, exp: 0,
    atk: 67, dec: 7, sus: 45874, rel: 4,
  }, o);
}

const FACTORY_PRESETS = {
  0: preset({ wave: 0 }),
  1: preset({ wave: 1 }),
  2: preset({ wave: 2 }),
  3: preset({ wave: 3 }),
  4: preset({ wave: 4, velPress: 1, oneshot: 1, rate: 3, exp: 9,
              atk: 4288, dec: 1, sus: 0, rel: 4096 }),
  5: preset({ wave: 5, fmRatio: 1, fmDepth: 2, velPress: 1, oneshot: 1, rate: 3, exp: 10,
              atk: 6144, dec: 7, sus: 0, rel: 4096 }),
  6: preset({ wave: 5, fmRatio: 6, fmDepth: 1, velPress: 1, oneshot: 1, rate: 2, exp: 8,
              atk: 16384, dec: 7, sus: 0, rel: 4096 }),
  7: preset({ wave: 5, fmRatio: 3, fmDepth: 3, velPress: 0, oneshot: 0, rate: 0, exp: 0,
              atk: 33, dec: 7, sus: 45874, rel: 4 }),
  8: preset({ wave: 5, fmRatio: 3, fmDepth: 2, velPress: 1, oneshot: 1, rate: 3, exp: 8,
              atk: 2048, dec: 1, sus: 0, rel: 4096 }),
  9: preset({ wave: 5, fmRatio: 6, fmDepth: 1, velPress: 1, oneshot: 1, rate: 2, exp: 9,
              atk: 1024, dec: 1, sus: 0, rel: 4096 }),
  // 10 = 自定义：默认从锯齿起步，之后由手动编辑覆盖
  10: preset({ wave: 1 }),
};

const FACTORY_MIX = {
  master: 255,
  mute: 0,
  mixShift: 2,
  keyVol: [128, 128, 128, 128, 128, 128, 128, 128],
};

// 演奏效果（全局，不随音色变）
const FACTORY_PERF = {
  mono: 0,          // 单音模式
  glide: 0,         // 滑音
  glideShift: 10,   // τ = 2^10/48828 ≈ 21ms
  vib: 0,           // 颤音
  vibRate: 55,      // 0.1Hz -> 5.5Hz
  vibDepth: 40,     // 0..127 -> ≈ ±33 音分
  transpose: 0,     // -12..+12 半音
  octave: 0,        // ★ -2..+2 八度（和板上 KBD_UP/DN 同步）
  sustain: 40,      // ★ 延音踏板 0=关，1..127=松开后慢慢衰减（切到琴类音色时默认归 0）
};

// 32 声道（1~8 实际使用，9~32 预留折叠）
const CH_COUNT = 32;
function factoryChannel() {
  return { vol: 128, dist: 0, echo: 0, reverb: 0, chorus: 0, phaser: 0 };
}
const FACTORY_CH = Array.from({ length: CH_COUNT }, factoryChannel);

// 全局效果器（发送式）
const FACTORY_FX = {
  echoOn: 0, echoTime: 110, echoFb: 6, echoMix: 64,
  revOn: 0, revSize: 64, revDamp: 64, revMix: 64,
  choOn: 0, choRate: 40, choDepth: 40, choMix: 64,
  phaOn: 0, phaRate: 40, phaDepth: 40, phaFb: 4, phaMix: 64,
  drvOn: 0, drvDrive: 0, drvTone: 64, drvMix: 64,
  limOn: 1, limTh: 224, limCeil: 255, limRel: 64,
  // 32 声部齐奏（8 键 × 4 层）
  uniOn: 1, uniLayers: 4, uniDetune: 64, uniMix: 100,
  // PWM 脉宽调制（只作用在方波）
  pwmWidth: 128, pwmRate: 30, pwmDepth: 96,
};

// 5 段均衡：寄存器里存的是 1/16 线性增益（16 = 0dB）
const FACTORY_EQ = {
  on: 1, low: 16, lmid: 16, mid: 16, hmid: 16, high: 16, out: 255,
};

// 寄存器 -> 状态字段（用于读回/连接时同步）
const FX_REG_MAP = [
  [R.ECHO_ON, 'echoOn', true], [R.ECHO_TIME, 'echoTime'], [R.ECHO_FB, 'echoFb'], [R.ECHO_MIX, 'echoMix'],
  [R.REV_ON, 'revOn', true], [R.REV_SIZE, 'revSize'], [R.REV_DAMP, 'revDamp'], [R.REV_MIX, 'revMix'],
  [R.CHO_ON, 'choOn', true], [R.CHO_RATE, 'choRate'], [R.CHO_DEPTH, 'choDepth'], [R.CHO_MIX, 'choMix'],
  [R.PHA_ON, 'phaOn', true], [R.PHA_RATE, 'phaRate'], [R.PHA_DEPTH, 'phaDepth'],
  [R.PHA_FB, 'phaFb'], [R.PHA_MIX, 'phaMix'],
  [R.DRV_ON, 'drvOn', true], [R.DRV_DRIVE, 'drvDrive'], [R.DRV_TONE, 'drvTone'], [R.DRV_MIX, 'drvMix'],
  [R.LIM_ON, 'limOn', true], [R.LIM_TH, 'limTh'], [R.LIM_CEIL, 'limCeil'], [R.LIM_REL, 'limRel'],
  [R.UNISON_ON, 'uniOn', true], [R.UNISON_LAYERS, 'uniLayers'],
  [R.UNISON_DETUNE, 'uniDetune'], [R.UNISON_MIX, 'uniMix'],
  [R.PWM_WIDTH, 'pwmWidth'], [R.PWM_RATE, 'pwmRate'], [R.PWM_DEPTH, 'pwmDepth'],
];
const EQ_REG_MAP = [
  [R.EQ_ON, 'on', true], [R.EQ_LOW, 'low'], [R.EQ_LMID, 'lmid'], [R.EQ_MID, 'mid'],
  [R.EQ_HMID, 'hmid'], [R.EQ_HIGH, 'high'], [R.EQ_OUT, 'out'],
];

/* ============================================================
   3. 协议工具
   ============================================================ */
function crc8(bytes, from, to) {
  let c = 0;
  const end = (to === undefined) ? bytes.length : to;
  for (let i = (from || 0); i < end; i++) {
    c ^= bytes[i] & 0xFF;
    for (let b = 0; b < 8; b++) {
      c = (c & 0x80) ? (((c << 1) ^ 0x07) & 0xFF) : ((c << 1) & 0xFF);
    }
  }
  return c;
}

function buildFrame(type, payload) {
  const p = payload || [];
  const f = [SOF0, SOF1, type & 0xFF, p.length & 0xFF];
  for (const b of p) f.push(b & 0xFF);
  f.push(crc8(f, 2, f.length));
  return Uint8Array.from(f);
}

function encodeSet(pairs) {
  const payload = [];
  for (const it of pairs) {
    payload.push(it.reg & 0xFF, it.val & 0xFF, (it.val >> 8) & 0xFF);
  }
  return buildFrame(T.SET, payload);
}

class FrameParser {
  constructor(onFrame) {
    this.buf = [];
    this.onFrame = onFrame;
    this.errors = 0;
    this.maxPayload = 48;
  }

  reset() { this.buf.length = 0; }

  feed(chunk) {
    for (let i = 0; i < chunk.length; i++) this.buf.push(chunk[i] & 0xFF);

    // 不让垃圾数据无限堆积
    if (this.buf.length > 4096) this.buf.splice(0, this.buf.length - 512);

    for (;;) {
      // 找帧头 A5 5A
      let start = -1;
      for (let i = 0; i + 1 < this.buf.length; i++) {
        if (this.buf[i] === SOF0 && this.buf[i + 1] === SOF1) { start = i; break; }
      }
      if (start < 0) {
        if (this.buf.length > 1) this.buf.splice(0, this.buf.length - 1);
        return;
      }
      if (start > 0) this.buf.splice(0, start);
      if (this.buf.length < 4) return;

      const type = this.buf[2];
      const len = this.buf[3];          // A5 5A TYPE LEN PAYLOAD... CRC
      if (len > this.maxPayload) { this.errors++; this.buf.shift(); continue; }
      if (this.buf.length < 5 + len) return;

      const crc = this.buf[4 + len];
      if (crc8(this.buf, 2, 4 + len) !== crc) {
        this.errors++;
        this.buf.shift();           // 丢掉这个 A5，继续找下一帧
        continue;
      }

      const payload = this.buf.slice(4, 4 + len);
      this.buf.splice(0, 5 + len);
      this.onFrame(type, payload);
    }
  }
}

/* ============================================================
   4. 纯函数：参数的数值 / 时间换算（Node 也能测）
   ============================================================ */
function envTimes(p) {
  const fs = SAMPLE_RATE / Math.pow(2, p.rate);
  const tA = 65536 / (Math.max(1, p.atk) * fs);

  let tD, tau = 0, target;
  if (p.exp > 0) {
    tau = Math.pow(2, p.exp) / fs;
    target = p.oneshot ? 0 : p.sus / 65535;
    // 指数衰减：听到"没了"约 -60dB；按住时衰减到延音电平
    tD = (target <= 0.001)
       ? tau * Math.log(65535 / 65)          // -60dB
       : tau * Math.log(65535 / Math.max(1, p.sus));
  } else {
    target = p.oneshot ? 0 : p.sus / 65535;
    tD = (p.dec > 0) ? (65535 * (1 - target)) / (p.dec * fs) : Infinity;
  }

  const tR = (p.oneshot || p.rel === 0) ? 0.0015 : 65535 / (p.rel * fs);
  return { fs, tA, tD, tau, target, tR };
}

function fmtTime(s) {
  if (!isFinite(s)) return '∞';
  if (s < 0.001) return '<1 ms';
  if (s < 0.9995) return Math.round(s * 1000) + ' ms';
  if (s < 10) return (Math.round(s * 100) / 100).toFixed(2) + ' s';
  return Math.round(s) + ' s';
}

function fmtPct(v, max) {
  return Math.round((v / max) * 100) + '%';
}

// 颤音深度 0..127 -> 峰值音分（和 osc_voice 里的 inc*delta>>>11 对应）
function perfCents(depth) {
  return Math.round(1200 * Math.log2(1 + (depth | 0) / 2048));
}

// 8 位按键掩码 -> 当前按下的键数
function popcount8(v) {
  let n = 0;
  let x = v & 0xFF;
  while (x) { n += x & 1; x >>= 1; }
  return n;
}

// 切音色时延音的默认值：
//   颠琴/钟琴 -> 默认开（0 时给 40，已有值则保留）
//   钢琴/古筝/木琴 -> 默认关
//   持续音（非 one-shot）-> 0（本来也不可用）
function defaultSustainOnTimbre(oneshot, isSwitch, current, defaultOn) {
  if (!oneshot) return 0;
  if (isSwitch) {
    if (!defaultOn) return 0;
    return current > 0 ? current : 40;
  }
  if (defaultOn && (current || 0) === 0) return 40;
  return current;
}

// 滑音时间常数：2^shift / 采样率（秒）
function glideTau(shift) {
  return Math.pow(2, Math.max(0, Math.min(15, shift | 0))) / SAMPLE_RATE;
}

// ★ 延音踏板：和 top.v 的 pedal_step = 32 - (sustain>>2) 对应；
//   relStep 用来表示"踏板只慢不快"（0 = 原释音立即切断，踏板仍可接管）
function pedalReleaseTime(sustain, envRate, relStep) {
  const s = Math.max(0, Math.min(127, sustain | 0));
  if (s === 0) return 0;
  const step = s >= 4 ? (32 - (s >> 2)) : 32;
  const rel = Math.max(0, relStep | 0);
  const eff = rel === 0 ? step : Math.min(step, rel);
  const fs = SAMPLE_RATE / Math.pow(2, Math.max(0, envRate | 0));
  // 踏板每 4 个 rate_tick 一步，且 one-shot 在 50% 电平保持；
  // 所以典型尾音 ≈ 2 × 65535 / (step × fs)
  return 2 * 65535 / (eff * fs);
}

// ★ 2026-10-26 第三轮：效果器 / EQ 的显示换算
// 回声延时：512 + time*60 个采样（和 fx_echo.v 一致）
function echoMs(v) {
  return (512 + Math.max(0, Math.min(255, v | 0)) * 60) / SAMPLE_RATE * 1000;
}
// 合唱 LFO：inc = 32 + rate*16，f = inc*fs/2^24
function chorusHz(v) {
  return (32 + Math.max(0, Math.min(127, v | 0)) * 16) * SAMPLE_RATE / 16777216;
}
// 相位 LFO：inc = 16 + rate*8
function phaserHz(v) {
  return (16 + Math.max(0, Math.min(127, v | 0)) * 8) * SAMPLE_RATE / 16777216;
}
// 限幅阈值/天花板（16 位码值 -> dBFS）
function limiterDb(v, isCeil) {
  const code = (isCeil ? 8192 : 4096) + Math.max(0, Math.min(255, v | 0)) * (isCeil ? 96 : 112);
  return 20 * Math.log10(Math.min(32767, code) / 32768);
}
function fmtDb(db) {
  if (!isFinite(db)) return '-∞ dB';
  if (Math.abs(db) < 0.05) return '0.0 dB';
  return (db > 0 ? '+' : '') + db.toFixed(1) + ' dB';
}
// 均衡：dB -> 寄存器线性码（16 = 1.0 = 0dB，范围 1..63）
function eqDbToCode(db) {
  const g = Math.pow(10, Math.max(-24, Math.min(12, db)) / 20) * 16;
  return Math.max(1, Math.min(63, Math.round(g)));
}
function eqCodeToDb(code) {
  return 20 * Math.log10(Math.max(1, Math.min(63, code | 0)) / 16);
}

// 32 声道寄存器打包 / 拆包（和 param_regs.v 的 0x80 / 0xA0 一一对应）
function packChA(vol, dist) {
  return ((dist & 0xFF) << 8) | (vol & 0xFF);
}
function packChB(echo, reverb, chorus, phaser) {
  return ((phaser & 15) << 12) | ((chorus & 15) << 8) |
         ((reverb & 15) << 4) | (echo & 15);
}
function unpackChA(v) {
  return { vol: v & 0xFF, dist: (v >> 8) & 0xFF };
}
function unpackChB(v) {
  return { echo: v & 15, reverb: (v >> 4) & 15, chorus: (v >> 8) & 15, phaser: (v >> 12) & 15 };
}

// 时间类步长 <-> 滑块位置（对数刻度，1..65535）
//  allowZero = true 时，滑块最左端表示步长 0（"不衰减 / 立刻切断"）
function stepFromPos(pos, allowZero) {
  if (allowZero && pos <= 0) return 0;
  const p0 = allowZero ? 1 : 0;
  const f = Math.min(1, Math.max(0, (pos - p0) / (1000 - p0)));
  return Math.max(1, Math.min(65535, Math.round(Math.exp(Math.log(1) + Math.log(65535) * f))));
}
function posFromStep(step, allowZero) {
  if (step <= 0) return 0;
  const f = Math.log(Math.min(65535, Math.max(1, step))) / Math.log(65535);
  const p0 = allowZero ? 1 : 0;
  return Math.round(p0 + (1000 - p0) * f);
}

function effectiveHarmonics(h) {
  return HARM_BASE.map((b, i) => Math.max(1, b >> (h[i] | 0)));
}

// 遥测 16 字节 -> 对象（字段顺序见 param_regs.v 文件头）
function decodeTelemetry(p) {
  return {
    timbre: p[0] & 0x0F,
    wave: p[1],
    vel: p[2],
    raw: p[3],
    poly: p[4],
    peak: p[5],
    oct: (p[6] << 24) >> 24,
    keys: p[7],
    flags: p[8],
    err: p[9],
    master: p[10],
    mixmute: p[11],
    sets: p[12],
    rxerr: p[13],
    frame: p[14] | (p[15] << 8),
  };
}

/* ============================================================
   5. 浏览器 UI
   ============================================================ */
function initUI() {
  const $ = (id) => document.getElementById(id);
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const clone = (o) => JSON.parse(JSON.stringify(o));

  const STORAGE_KEY = 'fpga8.console.v1';

  /* ---------------- 连接状态 / 数据模型 ---------------- */
  const S = {
    connected: false,
    port: null,
    reader: null,
    writer: null,
    writeChain: Promise.resolve(),
    parser: null,
    timbre: 1,
    hwTimbre: 1,      // FPGA 实际 TIMBRE（自定义时保持不变）
    hwKnown: false,
    live: clone(FACTORY_PRESETS[1]),
    presets: clone(FACTORY_PRESETS),
    mix: clone(FACTORY_MIX),
    perf: clone(FACTORY_PERF),
    ch: clone(FACTORY_CH),
    fx: clone(FACTORY_FX),
    eq: clone(FACTORY_EQ),
    dirty: new Map(),
    telemetry: null,
    lastTelemetryAt: 0,
    lastTimbreSentAt: 0,
    lastOctSentAt: 0,
    polyPeakEff: 0,
    lastKeys: 0,
    scopeAmp: 0,
    framesIn: 0,
    framesOut: 0,
    crcErrors: 0,
    gotRegs: new Set(),
    wantRegs: new Set(),
    logFrames: false,
    uiSyncing: false,
  };

  /* ---------------- 日志 ---------------- */
  const logEl = $('log');
  const logWrap = $('logWrap');
  function log(msg, cls) {
    const time = new Date().toLocaleTimeString('zh-CN', { hour12: false });
    const line = document.createElement('div');
    if (cls) line.className = cls;
    line.textContent = '[' + time + '] ' + msg;
    logEl.appendChild(line);
    while (logEl.childElementCount > 300) logEl.removeChild(logEl.firstChild);
    logEl.scrollTop = logEl.scrollHeight;
  }
  function hex(n, w) { return '0x' + n.toString(16).toUpperCase().padStart(w || 2, '0'); }

  /* ---------------- 滑块视觉填充 ---------------- */
  function setFill(el) {
    if (!el) return;
    const min = parseFloat(el.min) || 0;
    const max = parseFloat(el.max) || 100;
    const v = parseFloat(el.value) || 0;
    el.style.setProperty('--fill', (max > min ? (v - min) / (max - min) * 100 : 0) + '%');
  }

  /* ---------------- 串口发送 ---------------- */
  function sendBytes(bytes) {
    if (!S.connected || !S.writer) return Promise.resolve();
    const data = bytes;
    S.writeChain = S.writeChain.then(() => S.writer.write(data)).catch((e) => {
      log('串口写入失败：' + e.message, 'er');
    });
    return S.writeChain;
  }

  function sendFrame(type, payload) {
    S.framesOut++;
    if (S.logFrames) {
      log('TX ' + hex(type) + ' ' + Array.from(payload || []).map((b) => hex(b)).join(' '),
        type === T.SET ? 'tx' : 'tx');
    }
    return sendBytes(buildFrame(type, payload));
  }

  async function sendSetList(pairs) {
    // 一帧最多 16 项（48 字节）
    for (let i = 0; i < pairs.length; i += 16) {
      await sendFrame(T.SET, (function () {
        const p = [];
        for (const it of pairs.slice(i, i + 16)) {
          p.push(it.reg & 0xFF, it.val & 0xFF, (it.val >> 8) & 0xFF);
        }
        return p;
      })());
    }
  }

  function markDirty(reg, val) {
    S.dirty.set(reg, val);
    // 同时记进"当前音色的本地预设"，切走再切回来不会丢
    persistLive();
  }

  // 40Hz 合并发送（拖滑块时不会刷爆串口）
  setInterval(() => {
    if (!S.connected || S.dirty.size === 0) return;
    const items = [];
    for (const [reg, val] of S.dirty) {
      items.push({ reg, val });
      if (items.length >= 16) break;
    }
    for (const it of items) S.dirty.delete(it.reg);
    if (items.some((it) => it.reg === R.OCTAVE)) S.lastOctSentAt = performance.now();
    sendSetList(items);
  }, 25);

  /* ---------------- 参数 -> 寄存器 ---------------- */
  function paramPairs(p) {
    const pairs = [
      { reg: R.WAVE,     val: p.wave },
      { reg: R.FM_RATIO, val: p.fmRatio },
      { reg: R.FM_DEPTH, val: p.fmDepth },
      { reg: R.H1,       val: p.h[0] },
      { reg: R.H2,       val: p.h[1] },
      { reg: R.H3,       val: p.h[2] },
      { reg: R.H4,       val: p.h[3] },
      { reg: R.VEL_PRESS,val: p.velPress ? 1 : 0 },
      { reg: R.ONESHOT,  val: p.oneshot ? 1 : 0 },
      { reg: R.RATE,     val: p.rate },
      { reg: R.EXP,      val: p.exp },
      { reg: R.ATK,      val: p.atk },
      { reg: R.DEC,      val: p.dec },
      { reg: R.SUS,      val: p.sus },
      { reg: R.REL,      val: p.rel },
    ];
    return pairs;
  }

  function pushMix() {
    const pairs = [
      { reg: R.MIX_SHIFT, val: S.mix.mixShift },
      { reg: R.MASTER,    val: S.mix.master },
      { reg: R.MUTE,      val: S.mix.mute ? 1 : 0 },
    ];
    for (let i = 0; i < 8; i++) pairs.push({ reg: R.KV0 + i, val: S.mix.keyVol[i] });
    return pairs;
  }

  // 演奏效果寄存器（全局）
  function perfPairs() {
    return [
      { reg: R.MONO,        val: S.perf.mono ? 1 : 0 },
      { reg: R.GLIDE_EN,    val: S.perf.glide ? 1 : 0 },
      { reg: R.GLIDE_SHIFT, val: S.perf.glideShift },
      { reg: R.VIB_EN,      val: S.perf.vib ? 1 : 0 },
      { reg: R.VIB_RATE,    val: S.perf.vibRate },
      { reg: R.VIB_DEPTH,   val: S.perf.vibDepth },
      { reg: R.TRANSPOSE,   val: S.perf.transpose },
      { reg: R.OCTAVE,      val: S.perf.octave },
      { reg: R.SUSTAIN,     val: S.perf.sustain },
    ];
  }

  // 单个通道：A = {失真, 音量}，B = {相位, 合唱, 混响, 回声} 发送量
  function chPair(i) {
    const c = S.ch[i];
    return [
      { reg: R.CHA0 + i, val: packChA(c.vol, c.dist) },
      { reg: R.CHB0 + i, val: packChB(c.echo, c.reverb, c.chorus, c.phaser) },
    ];
  }
  function allChPairs() {
    const out = [];
    for (let i = 0; i < CH_COUNT; i++) out.push(...chPair(i));
    return out;
  }

  function fxPairs() {
    const f = S.fx;
    return [
      { reg: R.ECHO_ON,   val: f.echoOn ? 1 : 0 },
      { reg: R.ECHO_TIME, val: f.echoTime },
      { reg: R.ECHO_FB,   val: f.echoFb },
      { reg: R.ECHO_MIX,  val: f.echoMix },
      { reg: R.REV_ON,    val: f.revOn ? 1 : 0 },
      { reg: R.REV_SIZE,  val: f.revSize },
      { reg: R.REV_DAMP,  val: f.revDamp },
      { reg: R.REV_MIX,   val: f.revMix },
      { reg: R.CHO_ON,    val: f.choOn ? 1 : 0 },
      { reg: R.CHO_RATE,  val: f.choRate },
      { reg: R.CHO_DEPTH, val: f.choDepth },
      { reg: R.CHO_MIX,   val: f.choMix },
      { reg: R.PHA_ON,    val: f.phaOn ? 1 : 0 },
      { reg: R.PHA_RATE,  val: f.phaRate },
      { reg: R.PHA_DEPTH, val: f.phaDepth },
      { reg: R.PHA_FB,    val: f.phaFb },
      { reg: R.PHA_MIX,   val: f.phaMix },
      { reg: R.DRV_ON,    val: f.drvOn ? 1 : 0 },
      { reg: R.DRV_DRIVE, val: f.drvDrive },
      { reg: R.DRV_TONE,  val: f.drvTone },
      { reg: R.DRV_MIX,   val: f.drvMix },
      { reg: R.LIM_ON,    val: f.limOn ? 1 : 0 },
      { reg: R.LIM_TH,    val: f.limTh },
      { reg: R.LIM_CEIL,  val: f.limCeil },
      { reg: R.LIM_REL,   val: f.limRel },
      { reg: R.UNISON_ON, val: f.uniOn ? 1 : 0 },
      { reg: R.UNISON_LAYERS, val: f.uniLayers },
      { reg: R.UNISON_DETUNE, val: f.uniDetune },
      { reg: R.UNISON_MIX,    val: f.uniMix },
      { reg: R.PWM_WIDTH,     val: f.pwmWidth },
      { reg: R.PWM_RATE,      val: f.pwmRate },
      { reg: R.PWM_DEPTH,     val: f.pwmDepth },
    ];
  }

  function eqPairs() {
    return [
      { reg: R.EQ_ON,   val: S.eq.on ? 1 : 0 },
      { reg: R.EQ_LOW,  val: S.eq.low },
      { reg: R.EQ_LMID, val: S.eq.lmid },
      { reg: R.EQ_MID,  val: S.eq.mid },
      { reg: R.EQ_HMID, val: S.eq.hmid },
      { reg: R.EQ_HIGH, val: S.eq.high },
      { reg: R.EQ_OUT,  val: S.eq.out },
    ];
  }

  /* ---------------- 音色切换 ---------------- */
  function highlightPreset() {
    document.querySelectorAll('.preset-btn').forEach((b) => {
      b.classList.toggle('active', +b.dataset.timbre === S.timbre);
    });
    const t = TIMBRES[S.timbre];
    $('timbreHint').textContent = '当前：' + t.name + '（' + S.timbre + '）';
  }

  // 延音踏板只对 one-shot 音色（钢琴/古筝/木琴/颠琴/钟琴）有效；
  // ★ 切到这类“琴类”音色时默认把延音归 0；其他参数不动。
  //   手动再把延音拉起来仍然有效，直到下一次切换音色。
  function applySustainForTimbre(isSwitch) {
    const can = !!S.live.oneshot;
    const defaultOn = (S.timbre === 8 || S.timbre === 9);   // 颠琴/钟琴默认开
    const next = defaultSustainOnTimbre(can, !!isSwitch, S.perf.sustain, defaultOn);
    if (next !== S.perf.sustain) {
      S.perf.sustain = next;
      markDirty(R.SUSTAIN, next);
    }
    const el = $('sustain');
    if (el) el.disabled = !can;
    syncSustainUI();
  }

  function loadLocalPreset(id) {
    const changed = id !== S.timbre;
    S.timbre = id;
    S.live = clone(S.presets[id]);
    highlightPreset();
    applySustainForTimbre(changed);
    syncControls();
    scheduleDraw();
  }

  // 手动改音色参数（波形/FM/ADSR/泛音/开关）时，自动落到“自定义”档。
  // 注意：不发送 TIMBRE=10，FPGA 仍保留上一个真实音色号；只靠参数覆盖。
  function markCustom() {
    S.presets[CUSTOM_ID] = clone(S.live);
    if (S.timbre === CUSTOM_ID) return;
    S.timbre = CUSTOM_ID;
    highlightPreset();
    log('手动修改音色参数 -> 自定义音色', 'wr');
  }

  // 把当前实时参数存回"本音色的本地预设"，切换音色/保存时不会丢
  function persistLive() {
    S.presets[S.timbre] = clone(S.live);
  }

  // 把"当前音色 + 全部参数"一次发下去。
  // ★ TIMBRE 必须放在第一项：FPGA 收到它会先装载出厂预设，
  //   后面紧跟的参数再逐个覆盖，所以一帧就能完成"切音色 + 恢复我的参数"。
  async function pushTimbreState(id) {
    // 自定义档不写 TIMBRE（FPGA 只有 0..9），只覆盖音色参数
    if (id === CUSTOM_ID) {
      await sendSetList(paramPairs(S.live));
      return;
    }
    const list = [{ reg: R.TIMBRE, val: id }].concat(paramPairs(S.live));
    await sendSetList(list);
  }

  async function sendMix() {
    await sendSetList(pushMix());
  }

  async function sendPerf() {
    S.lastOctSentAt = performance.now();
    await sendSetList(perfPairs());
  }

  async function sendChannels() {
    await sendSetList(allChPairs());
  }

  // 从 32 个通道的发送量推断哪些全局效果器应该自动打开
  function autoEnableFxFromSends() {
    const need = { echoOn: 0, revOn: 0, choOn: 0, phaOn: 0 };
    for (const c of S.ch) {
      if (c.echo > 0)   need.echoOn = 1;
      if (c.reverb > 0) need.revOn = 1;
      if (c.chorus > 0) need.choOn = 1;
      if (c.phaser > 0) need.phaOn = 1;
    }
    for (const k of Object.keys(need)) {
      if (need[k] && !S.fx[k]) S.fx[k] = 1;
    }
  }

  async function sendFx() {
    await sendSetList(fxPairs());
  }

  async function sendEq() {
    await sendSetList(eqPairs());
  }

  async function selectTimbre(id) {
    if (id < 0 || id > CUSTOM_ID) return;
    loadLocalPreset(id);
    if (!S.connected) return;
    S.dirty.clear();
    S.lastTimbreSentAt = performance.now();
    if (id === CUSTOM_ID) {
      // 自定义档：不发 TIMBRE（FPGA 只认 0..9），只把全部音色参数推下去
      await sendSetList(paramPairs(S.live));
      await sendPerf();
      log('切换到自定义音色（TIMBRE 保持 ' + S.hwTimbre + '，参数已覆盖）', 'wr');
    } else {
      S.hwTimbre = id;
      S.hwKnown = true;
      await pushTimbreState(id);
      await sendPerf();     // 延音可能因音色切换被自动关/恢复
      log('切换音色 -> ' + TIMBRES[id].name + '（TIMBRE=' + id + ' + 网页参数）', 'wr');
    }
  }

  // 硬件（KEY0）换了音色：跟随并推回网页里这一档的参数
  async function remoteTimbre(id) {
    if (id === S.timbre || id === CUSTOM_ID) return;
    const name = (TIMBRES[id] || {}).name || ('#' + id);
    S.hwTimbre = id;
    S.hwKnown = true;
    loadLocalPreset(id);
    log('硬件切换音色 -> ' + name + '（网页已跟随）', 'rx');

    if (!S.connected) return;
    S.dirty.clear();
    S.lastTimbreSentAt = performance.now();
    await pushTimbreState(id);
    await sendPerf();
  }

  /* ---------------- 值更新 ---------------- */
  function applyValue(reg, val) {
    // VALUE 帧（GET 的回包）
    if (reg === R.TIMBRE) {
      S.hwTimbre = val;
      S.hwKnown = true;
      // 自定义档下不跟随 FPGA 的旧 TIMBRE，否则会把手动音色冲掉
      if (S.timbre !== CUSTOM_ID && val !== S.timbre) { loadLocalPreset(val); }
      return;
    }
    if (S.dirty.has(reg)) return;   // 正在被用户拖，不回灌

    // ---- 32 声道：A = {失真, 音量} ----
    if (reg >= R.CHA0 && reg <= R.CHA0 + 31) {
      const i = reg - R.CHA0;
      const v = unpackChA(val);
      S.ch[i].vol = v.vol;
      S.ch[i].dist = v.dist;
      syncChannelUI(i);
      return;
    }
    // ---- 32 声道：B = 4 路发送 ----
    if (reg >= R.CHB0 && reg <= R.CHB0 + 31) {
      const i = reg - R.CHB0;
      const v = unpackChB(val);
      S.ch[i].echo = v.echo;
      S.ch[i].reverb = v.reverb;
      S.ch[i].chorus = v.chorus;
      S.ch[i].phaser = v.phaser;
      syncChannelUI(i);
      return;
    }
    // ---- 全局效果 / EQ ----
    const fxEntry = FX_REG_MAP.find((e) => e[0] === reg);
    if (fxEntry) {
      S.fx[fxEntry[1]] = fxEntry[2] ? (val ? 1 : 0) : val;
      syncFxUI();
      return;
    }
    const eqEntry = EQ_REG_MAP.find((e) => e[0] === reg);
    if (eqEntry) {
      S.eq[eqEntry[1]] = eqEntry[2] ? (val ? 1 : 0) : val;
      syncEqUI();
      return;
    }

    const p = S.live;
    const m = S.mix;
    switch (reg) {
      case R.WAVE: p.wave = val; break;
      case R.FM_RATIO: p.fmRatio = val; break;
      case R.FM_DEPTH: p.fmDepth = val; break;
      case R.H1: p.h[0] = val; break;
      case R.H2: p.h[1] = val; break;
      case R.H3: p.h[2] = val; break;
      case R.H4: p.h[3] = val; break;
      case R.VEL_PRESS: p.velPress = val ? 1 : 0; break;
      case R.ONESHOT: p.oneshot = val ? 1 : 0; break;
      case R.RATE: p.rate = val; break;
      case R.EXP: p.exp = val; break;
      case R.ATK: p.atk = val; break;
      case R.DEC: p.dec = val; break;
      case R.SUS: p.sus = val; break;
      case R.REL: p.rel = val; break;
      case R.MONO: S.perf.mono = val ? 1 : 0; break;
      case R.GLIDE_EN: S.perf.glide = val ? 1 : 0; break;
      case R.GLIDE_SHIFT: S.perf.glideShift = val; break;
      case R.VIB_EN: S.perf.vib = val ? 1 : 0; break;
      case R.VIB_RATE: S.perf.vibRate = val; break;
      case R.VIB_DEPTH: S.perf.vibDepth = val; break;
      case R.TRANSPOSE: S.perf.transpose = (val > 32767) ? val - 65536 : val; break;
      case R.OCTAVE: S.perf.octave = (val > 32767) ? val - 65536 : val; break;
      case R.SUSTAIN: S.perf.sustain = val; break;
      case R.MIX_SHIFT: m.mixShift = val; break;
      case R.MASTER: m.master = val; break;
      case R.MUTE: m.mute = val ? 1 : 0; break;
      default:
        if (reg >= R.KV0 && reg <= R.KV0 + 7) m.keyVol[reg - R.KV0] = val;
        else return;
    }
    syncControls();
    scheduleDraw();
  }

  /* ---------------- 遥测 ---------------- */
  function onTelemetry(p) {
    if (p.length < 16) return;
    const t = decodeTelemetry(p);
    S.telemetry = t;
    const prevAt = S.lastTelemetryAt;
    S.lastTelemetryAt = performance.now();
    S.framesIn++;

    $('velNum').textContent = t.vel;
    $('velBar').style.width = Math.min(100, t.vel / 127 * 100) + '%';
    $('rawNum').textContent = t.raw;
    // ★ 遥测 POLY 是"按键/主声部数"；齐奏的附加层没有独立 gate。
    //   网页按齐奏层数换算成实际声部数：8 键 × 4 层 = 32。
    S.lastKeys = t.keys;
    const keyCount = popcount8(t.keys);
    const uniMul = (S.fx.uniOn && S.fx.uniMix > 0 && S.fx.uniLayers > 1) ? S.fx.uniLayers : 1;
    const voiceCount = Math.min(32, keyCount * uniMul);
    t.keyCount = keyCount;
    t.polyEff = voiceCount;
    S.polyPeakEff = Math.max(S.polyPeakEff || 0, voiceCount);
    $('polyNum').textContent = voiceCount;
    $('peakNum').textContent = S.polyPeakEff;
    $('octNum').textContent = t.oct > 0 ? '+' + t.oct : (t.oct < 0 ? '' + t.oct : '0');
    // 板上 KBD_UP/DN 改了八度 -> 网页滑块跟随（用户刚拖过时 300ms 内不抢）
    if (t.oct !== S.perf.octave && !S.dirty.has(R.OCTAVE) &&
        performance.now() - S.lastOctSentAt > 300) {
      S.perf.octave = t.oct;
      syncOctaveUI();
    }

    const i2c = $('i2cChip');
    if (t.flags & 0x01) { i2c.textContent = '正常'; i2c.className = 'stat-v chip-ok'; }
    else { i2c.textContent = '无通信'; i2c.className = 'stat-v chip-bad'; }

    const page = $('pageChip');
    page.textContent = (t.flags & 0x02) ? '压力调试页' : '主界面';
    page.className = 'chip' + ((t.flags & 0x02) ? ' warn' : '');

    const err = $('errChip');
    err.textContent = 'I²C 错误 ' + t.err;
    err.className = 'chip' + (t.err > 0 ? ' bad' : '');

    $('setChip').textContent = '参数写入 ' + t.sets;
    const rxc = $('rxChip');
    rxc.textContent = '串口错误 ' + t.rxerr;
    rxc.className = 'chip' + (t.rxerr > 0 ? ' bad' : '');

    $('mixSum').textContent = voiceCount + ' 个声部在响';

    // 按键灯
    document.querySelectorAll('.keydot').forEach((el) => {
      el.classList.toggle('on', ((t.keys >> +el.dataset.dot) & 1) === 1);
    });

    // 声部条活动指示（1~8 号声部对应 8 个琴键）
    document.querySelectorAll('.voice-strip[data-voice]').forEach((el) => {
      const i = +el.dataset.voice;
      el.classList.toggle('on', i < 8 && ((t.keys >> i) & 1) === 1);
    });

    $('frameInfo').textContent = '遥测帧 #' + t.frame + ' · 约 24 Hz · ' +
      (prevAt ? '间隔 ' + Math.round(performance.now() - prevAt) + ' ms' : '刚连接');
    // 硬件改音色（KEY0）
    if (!S.hwKnown) {
      S.hwTimbre = t.timbre;
      S.hwKnown = true;
    }
    const timbreGuard = performance.now() - S.lastTimbreSentAt > 200;
    if (S.timbre === CUSTOM_ID) {
      // 自定义档：FPGA 的 TIMBRE 还是上一个真实音色；只有它真的变了才退出自定义
      if (t.timbre !== S.hwTimbre && timbreGuard) remoteTimbre(t.timbre);
    } else if (t.timbre !== S.timbre && timbreGuard) {
      remoteTimbre(t.timbre);
    }
  }

  /* ---------------- 接收分发 ---------------- */
  function onFrame(type, payload) {
    S.framesIn++;
    if (S.logFrames && type !== T.TELEM) {
      log('RX ' + hex(type) + ' ' + payload.map((b) => hex(b)).join(' '), 'rx');
    }
    switch (type) {
      case T.VAL: {
        for (let i = 0; i + 2 < payload.length; i += 3) {
          const reg = payload[i];
          const val = payload[i + 1] | (payload[i + 2] << 8);
          S.gotRegs.add(reg);
          applyValue(reg, val);
        }
        break;
      }
      case T.TELEM:
        onTelemetry(payload);
        break;
      case T.PONG:
        log('PONG：固件 v' + payload[0] + '.' + payload[1] + '（串口正常）', 'rx');
        break;
      default:
        break;
    }
  }

  /* ---------------- 连接 / 断开 ---------------- */
  function setConnUI(mode, text) {
    const dot = $('connDot');
    dot.className = 'dot ' + mode;
    $('connText').textContent = text;
    $('btnConnect').disabled = (mode === 'on');
    $('btnDisconnect').disabled = (mode !== 'on');
    $('btnPing').disabled = (mode !== 'on');
  }

  async function connect() {
    if (!('serial' in navigator)) {
      $('unsupported').classList.remove('hidden');
      return;
    }
    try {
      log('请求串口权限…');
      const port = await navigator.serial.requestPort();
      await port.open({
        baudRate: BAUD,
        dataBits: 8,
        stopBits: 1,
        parity: 'none',
        flowControl: 'none',
        bufferSize: 8192,
      });

      S.port = port;
      S.writer = port.writable.getWriter();
      S.reader = port.readable.getReader();
      S.connected = true;
      S.framesIn = 0;
      S.framesOut = 0;
      S.crcErrors = 0;
      S.parser = new FrameParser(onFrame);
      S.dirty.clear();
      S.gotRegs.clear();

      setConnUI('on', '已连接');
      const info = port.getInfo ? port.getInfo() : {};
      const vid = info.usbVendorId;
      let label = '115200 8N1';
      if (vid === 0x1A86) label += ' · CH340/CH341';
      else if (vid === 0x0403) label += ' · FTDI';
      else if (vid === 0x2E8A) label += ' · BL616?';
      else if (vid) label += ' · VID ' + hex(vid, 4) + ' PID ' + hex(info.usbProductId || 0, 4);
      else label += ' · USB 串口';
      $('portInfo').textContent = label;

      log('串口已打开：' + label, 'rx');
      readLoop();
      await sleep(60);
      await sendFrame(T.PING, []);
      await sleep(40);
      // 网页是"编辑端"：连上就把当前状态推给 FPGA，
      // 这样听到的永远和页面显示一致（不依赖 FPGA 里的易失参数）。
      await pushTimbreState(S.timbre);
      await sendMix();
      await sendPerf();
      await sendChannels();
      autoEnableFxFromSends();
      syncFxUI();
      await sendFx();
      await sendEq();
      S.polyPeakEff = 0;
      startWatchdog();
    } catch (e) {
      log('连接失败：' + (e && e.message ? e.message : e), 'er');
      setConnUI('err', '连接失败');
      await cleanupPort();
    }
  }

  async function readLoop() {
    try {
      for (;;) {
        const { value, done } = await S.reader.read();
        if (done) break;
        if (value && value.length) S.parser.feed(value);
      }
    } catch (e) {
      if (S.connected) log('读取中断：' + (e && e.message ? e.message : e), 'er');
    }
    if (S.connected) {
      S.connected = false;
      setConnUI('off', '已断开');
      log('串口已断开', 'er');
      await cleanupPort();
    }
  }

  async function cleanupPort() {
    S.connected = false;
    try { if (S.reader) { await S.reader.cancel(); S.reader.releaseLock(); } } catch (e) {}
    try { if (S.writer) S.writer.releaseLock(); } catch (e) {}
    S.reader = null;
    S.writer = null;
    try { if (S.port) await S.port.close(); } catch (e) {}
    S.port = null;
    $('btnConnect').disabled = false;
    $('btnDisconnect').disabled = true;
    $('btnPing').disabled = true;
    if (S.connected !== true) setConnUI('off', '未连接');
  }

  async function disconnect() {
    log('正在断开…');
    S.connected = false;
    try { if (S.reader) await S.reader.cancel(); } catch (e) {}
    await cleanupPort();
    setConnUI('off', '未连接');
  }

  /* ---------------- 读回所有参数 ---------------- */
  async function readAll(announce) {
    if (!S.connected) return;
    S.gotRegs.clear();
    S.wantRegs = new Set(WRITABLE_REGS);
    const regs = WRITABLE_REGS;
    for (let i = 0; i < regs.length; i += 16) {
      await sendFrame(T.GET, regs.slice(i, i + 16));
      await sleep(18);
    }
    if (announce) log('已请求读回全部参数（' + regs.length + ' 个寄存器）');

    // 400ms 后补读没回来的
    setTimeout(async () => {
      if (!S.connected) return;
      const missing = regs.filter((r) => !S.gotRegs.has(r));
      if (missing.length) {
        log('补读 ' + missing.length + ' 个寄存器…', 'wr');
        for (let i = 0; i < missing.length; i += 16) {
          await sendFrame(T.GET, missing.slice(i, i + 16));
          await sleep(18);
        }
      }
    }, 420);
  }

  /* ---------------- 遥测看门狗 ---------------- */
  let watchdog = null;
  function startWatchdog() {
    if (watchdog) clearInterval(watchdog);
    watchdog = setInterval(() => {
      if (!S.connected) return;
      const age = performance.now() - S.lastTelemetryAt;
      if (age > 1800) {
        $('monHint').textContent = '收不到遥测…';
        $('monHint').className = 'hint chip-warn';
      } else {
        $('monHint').textContent = '24 Hz 遥测';
        $('monHint').className = 'hint';
      }
    }, 700);
  }

  /* ---------------- 控件同步 ---------------- */
  function syncControls() {
    const p = S.live;
    S.uiSyncing = true;

    // 预设 / 波形
    highlightPreset();
    document.querySelectorAll('#waveSeg button').forEach((b) => {
      b.classList.toggle('active', +b.dataset.wave === p.wave);
    });
    const fmOn = p.wave === 5;
    $('fmRatio').disabled = !fmOn;
    $('fmDepth').disabled = !fmOn;

    $('fmRatio').value = String(p.fmRatio);
    $('fmRatioHint').textContent = FM_RATIOS[p.fmRatio].toFixed(1) + '×';
    $('fmDepth').value = String(p.fmDepth);
    $('fmDepthVal').textContent = '>>>' + p.fmDepth + '（±' + (127 >> p.fmDepth) + '）';
    setFill($('fmDepth'));

    // 泛音
    const eff = effectiveHarmonics(p.h);
    for (let i = 0; i < 4; i++) {
      const el = document.querySelector('.h-range[data-h="' + i + '"]');
      if (el) { el.value = String(p.h[i]); setFill(el); }
      const v = document.querySelector('[data-hval="' + i + '"]');
      if (v) v.textContent = String(eff[i]);
      const a = document.querySelector('[data-hatt="' + i + '"]');
      if (a) a.textContent = p.h[i] === 0 ? '×1' : '×1/' + (1 << p.h[i]);
    }
    $('harmLabel').textContent = eff.join(' : ');

    // 开关
    $('velPress').checked = !!p.velPress;
    $('oneshot').checked = !!p.oneshot;

    // ADSR
    setStepControl('atk', p.atk, false);
    setStepControl('dec', p.dec, true);
    setStepControl('rel', p.rel, true);
    $('sus').value = String(p.sus);
    $('susNum').value = String(p.sus);
    setFill($('sus'));
    $('susPct').textContent = fmtPct(p.sus, 65535);

    $('rate').value = String(p.rate);
    setFill($('rate'));
    $('rateVal').textContent = Math.pow(2, p.rate) + '× · ' +
      (SAMPLE_RATE / Math.pow(2, p.rate)).toFixed(1) + ' kHz';

    $('exp').value = String(p.exp);
    setFill($('exp'));
    $('expVal').textContent = p.exp === 0 ? '0 · 线性（每拍减 D 步长）' :
      p.exp + ' · 每拍减 1/' + (1 << p.exp) + '（τ ≈ ' + fmtTime(Math.pow(2, p.exp) / (SAMPLE_RATE / Math.pow(2, p.rate))) + '）';

    // 混音
    $('master').value = String(S.mix.master);
    setFill($('master'));
    $('masterVal').textContent = fmtPct(S.mix.master, 255);
    $('muteBtn').classList.toggle('muted', !!S.mix.mute);
    $('muteBtn').textContent = S.mix.mute ? '✕' : '♪';
    $('mixShift').value = String(S.mix.mixShift);
    setFill($('mixShift'));
    $('mixShiftVal').textContent = S.mix.mixShift === 0 ? '×1' : '÷' + (1 << S.mix.mixShift);

    // 演奏效果
    $('vibSw').checked   = !!S.perf.vib;
    $('glideSw').checked = !!S.perf.glide;
    $('monoSw').checked  = !!S.perf.mono;

    $('vibRate').value = String(S.perf.vibRate);
    setFill($('vibRate'));
    $('vibRateVal').textContent = (S.perf.vibRate / 10).toFixed(1) + ' Hz';

    $('vibDepth').value = String(S.perf.vibDepth);
    setFill($('vibDepth'));
    $('vibDepthVal').textContent = '±' + perfCents(S.perf.vibDepth) + ' 音分';

    $('glideTime').value = String(S.perf.glideShift);
    setFill($('glideTime'));
    $('glideTimeVal').textContent = 'τ ' + fmtTime(glideTau(S.perf.glideShift));

    $('transpose').value = String(S.perf.transpose);
    setFill($('transpose'));
    $('transposeVal').textContent = (S.perf.transpose > 0 ? '+' : '') + S.perf.transpose + ' 半音';

    syncOctaveUI();
    syncSustainUI();
    $('octNum').textContent = S.perf.octave > 0 ? '+' + S.perf.octave :
      (S.perf.octave < 0 ? '' + S.perf.octave : '0');

    const hb = [];
    if (S.perf.vib) hb.push('颤音');
    if (S.perf.glide) hb.push('滑音');
    if (S.perf.mono) hb.push('单音');
    if (S.perf.transpose) hb.push('变调 ' + (S.perf.transpose > 0 ? '+' : '') + S.perf.transpose);
    if (S.perf.octave) hb.push('八度 ' + (S.perf.octave > 0 ? '+' : '') + S.perf.octave);
    if (S.perf.sustain) hb.push('延音 ' + Math.round(S.perf.sustain / 127 * 100) + '%');
    $('perfHint').textContent = hb.length ? hb.join(' · ') : '全部关闭';

    syncFxUI();
    syncEqUI();
    syncChannels();

    // 时间显示
    updateTimes();
    S.uiSyncing = false;
  }

  // 八度滑块 / 提示
  function syncOctaveUI() {
    $('octave').value = String(S.perf.octave);
    setFill($('octave'));
    const o = S.perf.octave;
    $('octaveVal').textContent = o === 0 ? '0（原调）' :
      (o > 0 ? '+' + o + ' 八度' : o + ' 八度');
  }

  // 延音踏板滑块 / 提示
  function syncSustainUI() {
    const v = S.perf.sustain;
    const can = !!(S.live && S.live.oneshot);
    $('sustain').value = String(v);
    $('sustain').disabled = !can;
    setFill($('sustain'));
    if ($('sustainReset')) $('sustainReset').disabled = !can;
    if (!can) {
      $('sustainVal').textContent = '不适用（持续音）';
    } else if (v === 0) {
      $('sustainVal').textContent = '关（原释音）';
    } else {
      $('sustainVal').textContent = '尾音 ≈ ' + fmtTime(pedalReleaseTime(v, S.live.rate, S.live.rel));
    }
  }

  // 通道条标签 / 滑块
  function channelLabel(i, key, v) {
    if (key === 'vol') return fmtPct(v, 128);
    if (key === 'dist') return fmtPct(v, 127);
    return Math.round(v / 15 * 100) + '%';
  }
  function syncChannelUI(i) {
    const c = S.ch[i];
    for (const key of ['vol', 'dist', 'echo', 'reverb', 'chorus', 'phaser']) {
      const el = document.querySelector('.ch-range[data-ch="' + i + '"][data-param="' + key + '"]');
      if (el) { el.value = String(c[key]); setFill(el); }
      const v = document.querySelector('[data-chval="' + i + '-' + key + '"]');
      if (v) v.textContent = channelLabel(i, key, c[key]);
    }
  }
  function syncChannels() {
    for (let i = 0; i < CH_COUNT; i++) syncChannelUI(i);
  }

  // 全局效果器 UI
  function syncFxUI() {
    const f = S.fx;
    $('echoOn').checked = !!f.echoOn;
    $('echoTime').value = String(f.echoTime); setFill($('echoTime'));
    $('echoTimeVal').textContent = Math.round(echoMs(f.echoTime)) + ' ms';
    $('echoFb').value = String(f.echoFb); setFill($('echoFb'));
    $('echoFbVal').textContent = fmtPct(f.echoFb, 15);
    $('echoMix').value = String(f.echoMix); setFill($('echoMix'));
    $('echoMixVal').textContent = fmtPct(f.echoMix, 127);

    $('revOn').checked = !!f.revOn;
    $('revSize').value = String(f.revSize); setFill($('revSize'));
    $('revSizeVal').textContent = fmtPct(f.revSize, 127);
    $('revDamp').value = String(f.revDamp); setFill($('revDamp'));
    $('revDampVal').textContent = fmtPct(f.revDamp, 127);
    $('revMix').value = String(f.revMix); setFill($('revMix'));
    $('revMixVal').textContent = fmtPct(f.revMix, 127);

    $('choOn').checked = !!f.choOn;
    $('choRate').value = String(f.choRate); setFill($('choRate'));
    $('choRateVal').textContent = chorusHz(f.choRate).toFixed(2) + ' Hz';
    $('choDepth').value = String(f.choDepth); setFill($('choDepth'));
    $('choDepthVal').textContent = fmtPct(f.choDepth, 127);
    $('choMix').value = String(f.choMix); setFill($('choMix'));
    $('choMixVal').textContent = fmtPct(f.choMix, 127);

    $('phaOn').checked = !!f.phaOn;
    $('phaRate').value = String(f.phaRate); setFill($('phaRate'));
    $('phaRateVal').textContent = phaserHz(f.phaRate).toFixed(2) + ' Hz';
    $('phaDepth').value = String(f.phaDepth); setFill($('phaDepth'));
    $('phaDepthVal').textContent = fmtPct(f.phaDepth, 127);
    $('phaFb').value = String(f.phaFb); setFill($('phaFb'));
    $('phaFbVal').textContent = fmtPct(f.phaFb, 15);
    $('phaMix').value = String(f.phaMix); setFill($('phaMix'));
    $('phaMixVal').textContent = fmtPct(f.phaMix, 127);

    $('drvOn').checked = !!f.drvOn;
    $('drvDrive').value = String(f.drvDrive); setFill($('drvDrive'));
    $('drvDriveVal').textContent = fmtPct(f.drvDrive, 127);
    $('drvTone').value = String(f.drvTone); setFill($('drvTone'));
    $('drvToneVal').textContent = fmtPct(f.drvTone, 127);
    $('drvMix').value = String(f.drvMix); setFill($('drvMix'));
    $('drvMixVal').textContent = fmtPct(f.drvMix, 127);

    $('limOn').checked = !!f.limOn;
    $('limTh').value = String(f.limTh); setFill($('limTh'));
    $('limThVal').textContent = fmtDb(limiterDb(f.limTh, false));
    $('limCeil').value = String(f.limCeil); setFill($('limCeil'));
    $('limCeilVal').textContent = fmtDb(limiterDb(f.limCeil, true));
    $('limRel').value = String(f.limRel); setFill($('limRel'));
    $('limRelVal').textContent = String(1 + (f.limRel >> 5));

    // 32 声部齐奏
    $('uniOn').checked = !!f.uniOn;
    $('uniLayers').value = String(f.uniLayers); setFill($('uniLayers'));
    $('uniLayersVal').textContent = f.uniLayers + ' 层 · ' + (f.uniLayers * 8) + ' 声部';
    $('uniDetune').value = String(f.uniDetune); setFill($('uniDetune'));
    const uniShift = Math.max(3, 10 - (f.uniDetune >> 4));
    $('uniDetuneVal').textContent = (100 / Math.pow(2, uniShift)).toFixed(2) + '%';
    $('uniMix').value = String(f.uniMix); setFill($('uniMix'));
    $('uniMixVal').textContent = fmtPct(f.uniMix, 127);

    // PWM 脉宽调制
    $('pwmWidth').value = String(f.pwmWidth); setFill($('pwmWidth'));
    $('pwmWidthVal').textContent = (f.pwmWidth / 255 * 100).toFixed(1) + '%';
    $('pwmRate').value = String(f.pwmRate); setFill($('pwmRate'));
    $('pwmRateVal').textContent = (f.pwmRate / 10).toFixed(1) + ' Hz';
    $('pwmDepth').value = String(f.pwmDepth); setFill($('pwmDepth'));
    $('pwmDepthVal').textContent = fmtPct(f.pwmDepth, 127);
  }

  // 5 段均衡 UI
  function syncEqUI() {
    $('eqOn').checked = !!S.eq.on;
    for (const key of ['low', 'lmid', 'mid', 'hmid', 'high']) {
      const code = S.eq[key];
      const db = eqCodeToDb(code);
      const el = $('eq' + key[0].toUpperCase() + key.slice(1));
      el.value = String(Math.round(db));
      setFill(el);
      const label = $('eq' + key[0].toUpperCase() + key.slice(1) + 'Val');
      label.textContent = fmtDb(db);
      label.classList.toggle('cut', db < -0.05);
    }
    $('eqOut').value = String(S.eq.out);
    setFill($('eqOut'));
    $('eqOutVal').textContent = fmtPct(S.eq.out, 255);
  }

  function setStepControl(name, step, allowZero) {
    const el = $(name);
    const num = $(name + 'Num');
    el.value = String(posFromStep(step, allowZero));
    setFill(el);
    num.value = String(step);
    const t = envTimes(S.live);
    $(name + 'Time').textContent = fmtTime(
      name === 'atk' ? t.tA : name === 'dec' ? t.tD : t.tR
    );
  }

  function updateTimes() {
    const t = envTimes(S.live);
    $('atkTime').textContent = fmtTime(t.tA);
    $('decTime').textContent = fmtTime(t.tD);
    $('relTime').textContent = fmtTime(t.tR);
    $('susPct').textContent = fmtPct(S.live.sus, 65535);
    $('envTimes').textContent = 'A ' + fmtTime(t.tA) + ' · D ' + fmtTime(t.tD) +
      ' · R ' + fmtTime(t.tR) + ' · ' + t.fs.toFixed(0) + ' Hz';
    $('waveLabel').textContent = WAVE_NAMES[S.live.wave] || '?';
  }

  /* ---------------- 画布 ---------------- */
  const waveCanvas = $('waveCanvas');
  const envCanvas = $('envCanvas');
  let drawPending = false;
  function scheduleDraw() {
    if (drawPending) return;
    drawPending = true;
    requestAnimationFrame(() => {
      drawPending = false;
      drawWave();
      drawEnv();
    });
  }

  function prepCanvas(c) {
    const dpr = window.devicePixelRatio || 1;
    const w = c.clientWidth || c.width;
    const h = c.clientHeight || c.height;
    if (c.width !== Math.round(w * dpr) || c.height !== Math.round(h * dpr)) {
      c.width = Math.round(w * dpr);
      c.height = Math.round(h * dpr);
    }
    const ctx = c.getContext('2d');
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    return { ctx, w, h };
  }

  function drawWave() {
    const { ctx, w, h } = prepCanvas(waveCanvas);
    ctx.clearRect(0, 0, w, h);
    const mid = h / 2;

    // 栅格
    ctx.strokeStyle = 'rgba(255,255,255,.045)';
    ctx.lineWidth = 1;
    for (let i = 1; i < 4; i++) {
      const y = (h / 4) * i;
      ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(w, y); ctx.stroke();
    }
    ctx.strokeStyle = 'rgba(255,255,255,.09)';
    ctx.beginPath(); ctx.moveTo(0, mid); ctx.lineTo(w, mid); ctx.stroke();

    const p = S.live;
    const N = 480;
    const amp = h * 0.36;
    const eff = effectiveHarmonics(p.h);
    const harmSum = eff.reduce((a, b) => a + b, 0) || 1;
    const depthRad = (127 >> p.fmDepth) / 256 * Math.PI * 2;
    const ratio = FM_RATIOS[p.fmRatio] || 1;

    ctx.beginPath();
    for (let i = 0; i <= N; i++) {
      const th = (i / N) * Math.PI * 2;
      let v = 0;
      switch (p.wave) {
        case 0: v = Math.sin(th) >= 0 ? 1 : -1; break;
        case 1: v = 2 * (i / N) - 1; break;
        case 2: v = 1 - 4 * Math.abs(((i / N) + 0.25) % 1 - 0.5); break;
        case 3: v = Math.sin(th); break;
        case 4:
          v = (eff[0] * Math.sin(th) + eff[1] * Math.sin(2 * th) +
               eff[2] * Math.sin(3 * th) + eff[3] * Math.sin(4 * th)) / harmSum;
          break;
        case 5:
          v = Math.sin(th + depthRad * Math.sin(ratio * th));
          break;
        default: v = 0;
      }
      const x = (i / N) * w;
      const y = mid - v * amp;
      if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
    }
    ctx.strokeStyle = '#38e1c6';
    ctx.lineWidth = 2;
    ctx.shadowColor = 'rgba(56,225,198,.55)';
    ctx.shadowBlur = 10;
    ctx.stroke();
    ctx.shadowBlur = 0;

    // 基线两端的小刻度
    ctx.fillStyle = 'rgba(143,163,173,.55)';
    ctx.font = '10px "Cascadia Mono",Consolas,monospace';
    ctx.fillText('0', 2, h - 3);
    ctx.fillText('2π', w - 18, h - 3);
  }

  function drawEnv() {
    const { ctx, w, h } = prepCanvas(envCanvas);
    ctx.clearRect(0, 0, w, h);

    const p = S.live;
    const t = envTimes(p);
    const padL = 12, padR = 12, padT = 16, padB = 24;
    const x0 = padL, x1 = w - padR;
    const y0 = h - padB;          // env = 0
    const y1 = padT;              // env = 1
    const H = y0 - y1;

    const sus = p.sus / 65535;
    const tA = Math.max(t.tA, 0.0004);
    const tD = isFinite(t.tD) ? Math.max(t.tD, 0.0004) : 6;
    const tR = Math.max(t.tR, 0.0004);
    const tS = p.oneshot ? 0 : Math.max(0.12, (tA + tD + tR) * 0.18);

    let total = tA + tD + tS + tR;
    let scaleNote = '';
    if (!isFinite(t.tD)) { total = tA + 6 + tS + tR; scaleNote = 'D=∞'; }
    if (total > 14) { total = 14; scaleNote = '时间轴截断'; }

    const X = (sec) => x0 + Math.min(1, Math.max(0, sec / total)) * (x1 - x0);
    const Y = (e) => y0 - e * H;

    // 网格
    ctx.strokeStyle = 'rgba(255,255,255,.05)';
    ctx.lineWidth = 1;
    for (let i = 1; i < 4; i++) {
      const y = y1 + (H / 4) * i;
      ctx.beginPath(); ctx.moveTo(x0, y); ctx.lineTo(x1, y); ctx.stroke();
    }

    // 曲线
    const pts = [];
    let tt = 0;
    pts.push([X(0), Y(0)]);
    // 起音
    pts.push([X(tA), Y(1)]);
    tt = tA;
    // 衰减
    const decEnd = p.oneshot ? 0 : sus;
    if (p.exp > 0 && t.tau > 0) {
      const steps = 140;
      const dur = Math.min(tD, total - tt - tS - tR);
      for (let i = 1; i <= steps; i++) {
        const f = i / steps;
        const sec = f * dur;
        // 指数衰减（到 -60dB）
        const e = 1 * Math.exp(-sec / t.tau);
        pts.push([X(tt + sec), Y(Math.max(decEnd, e))]);
      }
    } else {
      pts.push([X(tt + tD), Y(decEnd)]);
    }
    tt += Math.min(tD, total);
    // 延音
    if (tS > 0) {
      pts.push([X(tt), Y(sus)]);
      pts.push([X(tt + tS), Y(sus)]);
      tt += tS;
    }
    // 释音
    pts.push([X(tt + tR), Y(0)]);

    // 填充
    ctx.beginPath();
    ctx.moveTo(X(0), y0);
    for (const [x, y] of pts) ctx.lineTo(x, y);
    ctx.lineTo(X(Math.min(total, tt + tR)), y0);
    ctx.closePath();
    const grad = ctx.createLinearGradient(0, y1, 0, y0);
    grad.addColorStop(0, 'rgba(56,225,198,.28)');
    grad.addColorStop(1, 'rgba(56,225,198,.02)');
    ctx.fillStyle = grad;
    ctx.fill();

    // 线
    ctx.beginPath();
    for (let i = 0; i < pts.length; i++) {
      const [x, y] = pts[i];
      if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
    }
    ctx.strokeStyle = '#4aebd2';
    ctx.lineWidth = 2;
    ctx.shadowColor = 'rgba(56,225,198,.5)';
    ctx.shadowBlur = 9;
    ctx.stroke();
    ctx.shadowBlur = 0;

    // 阶段标注
    ctx.font = '10.5px "Cascadia Mono",Consolas,monospace';
    const marks = [
      { t: 0, label: 'A', sec: t.tA, color: '#ffc857' },
      { t: tA, label: 'D', sec: t.tD, color: '#7aa2ff' },
      { t: tA + tD, label: tS > 0 ? 'S' : '', sec: tS, color: '#b78cff' },
      { t: tA + tD + tS, label: 'R', sec: t.tR, color: '#ff9f7a' },
    ];
    for (const m of marks) {
      const x = X(Math.min(m.t, total));
      ctx.strokeStyle = 'rgba(255,255,255,.13)';
      ctx.setLineDash([3, 4]);
      ctx.beginPath(); ctx.moveTo(x, y1); ctx.lineTo(x, y0); ctx.stroke();
      ctx.setLineDash([]);
      if (m.label) {
        ctx.fillStyle = m.color;
        ctx.fillText(m.label, Math.min(x + 4, x1 - 10), y1 + 11);
      }
    }

    // 文本
    ctx.fillStyle = 'rgba(143,163,173,.85)';
    ctx.fillText('0', x0, h - 7);
    ctx.fillText(fmtTime(total) + (scaleNote ? ' · ' + scaleNote : ''), x1 - 82, h - 7);
    ctx.fillStyle = 'rgba(56,225,198,.9)';
    ctx.fillText('100%', x0, y1 - 4);
    if (!p.oneshot && sus > 0.02) {
      ctx.fillStyle = 'rgba(183,140,255,.9)';
      ctx.fillText('S ' + Math.round(sus * 100) + '%', x0, Y(sus) - 4);
    }
    if (p.oneshot) {
      ctx.fillStyle = 'rgba(255,200,87,.9)';
      ctx.fillText('一次包络（按住也衰减）', x0 + 6, y1 + 24);
    }
  }

  /* ---------------- 事件绑定 ---------------- */
  function bindRange(id, onInput) {
    const el = $(id);
    el.addEventListener('input', () => {
      setFill(el);
      if (!S.uiSyncing) onInput(+el.value);
    });
  }

  function bindNumber(id, onCommit) {
    const el = $(id);
    el.addEventListener('change', () => {
      if (S.uiSyncing) return;
      onCommit(el.value);
    });
  }

  // 波形
  document.querySelectorAll('#waveSeg button').forEach((b) => {
    b.addEventListener('click', () => {
      S.live.wave = +b.dataset.wave;
      syncControls();
      scheduleDraw();
      markDirty(R.WAVE, S.live.wave);
      markCustom();
    });
  });

  // FM
  $('fmRatio').addEventListener('change', () => {
    S.live.fmRatio = +$('fmRatio').value;
    $('fmRatioHint').textContent = FM_RATIOS[S.live.fmRatio].toFixed(1) + '×';
    markDirty(R.FM_RATIO, S.live.fmRatio);
    markCustom();
    scheduleDraw();
  });
  bindRange('fmDepth', (v) => {
    S.live.fmDepth = v;
    $('fmDepthVal').textContent = '>>>' + v + '（±' + (127 >> v) + '）';
    markDirty(R.FM_DEPTH, v);
    markCustom();
    scheduleDraw();
  });

  // 开关
  $('velPress').addEventListener('change', () => {
    S.live.velPress = $('velPress').checked ? 1 : 0;
    markDirty(R.VEL_PRESS, S.live.velPress);
    markCustom();
  });
  $('oneshot').addEventListener('change', () => {
    S.live.oneshot = $('oneshot').checked ? 1 : 0;
    markDirty(R.ONESHOT, S.live.oneshot);
    applySustainForTimbre();   // 切到持续音/单次包络时自动处理延音
    markCustom();
    syncControls();
    scheduleDraw();
  });

  // ADSR 滑块
  bindRange('atk', (pos) => {
    S.live.atk = stepFromPos(pos, false);
    $('atkNum').value = String(S.live.atk);
    markDirty(R.ATK, S.live.atk);
    markCustom();
    updateTimes();
    scheduleDraw();
  });
  bindRange('dec', (pos) => {
    S.live.dec = stepFromPos(pos, true);
    $('decNum').value = String(S.live.dec);
    markDirty(R.DEC, S.live.dec);
    markCustom();
    updateTimes();
    scheduleDraw();
  });
  bindRange('rel', (pos) => {
    S.live.rel = stepFromPos(pos, true);
    $('relNum').value = String(S.live.rel);
    markDirty(R.REL, S.live.rel);
    markCustom();
    updateTimes();
    scheduleDraw();
  });
  bindRange('sus', (v) => {
    S.live.sus = v;
    $('susNum').value = String(v);
    markDirty(R.SUS, v);
    markCustom();
    updateTimes();
    scheduleDraw();
  });

  // ADSR 数字框
  bindNumber('atkNum', (v) => {
    const n = Math.max(1, Math.min(65535, parseInt(v, 10) || 1));
    S.live.atk = n;
    markDirty(R.ATK, n);
    markCustom();
    syncControls();
    scheduleDraw();
  });
  bindNumber('decNum', (v) => {
    const n = Math.max(0, Math.min(65535, parseInt(v, 10) || 0));
    S.live.dec = n;
    markDirty(R.DEC, n);
    markCustom();
    syncControls();
    scheduleDraw();
  });
  bindNumber('susNum', (v) => {
    const n = Math.max(0, Math.min(65535, parseInt(v, 10) || 0));
    S.live.sus = n;
    markDirty(R.SUS, n);
    markCustom();
    syncControls();
    scheduleDraw();
  });
  bindNumber('relNum', (v) => {
    const n = Math.max(0, Math.min(65535, parseInt(v, 10) || 0));
    S.live.rel = n;
    markDirty(R.REL, n);
    markCustom();
    syncControls();
    scheduleDraw();
  });

  // 速率 / 指数
  bindRange('rate', (v) => {
    S.live.rate = v;
    markDirty(R.RATE, v);
    markCustom();
    syncControls();
    scheduleDraw();
  });
  bindRange('exp', (v) => {
    S.live.exp = v;
    markDirty(R.EXP, v);
    markCustom();
    syncControls();
    scheduleDraw();
  });

  // 混音
  $('master').addEventListener('input', () => {
    S.mix.master = +$('master').value;
    setFill($('master'));
    $('masterVal').textContent = fmtPct(S.mix.master, 255);
    if (S.mix.mute) { S.mix.mute = 0; markDirty(R.MUTE, 0); syncControls(); }
    markDirty(R.MASTER, S.mix.master);
  });
  $('muteBtn').addEventListener('click', () => {
    S.mix.mute = S.mix.mute ? 0 : 1;
    markDirty(R.MUTE, S.mix.mute);
    syncControls();
    log(S.mix.mute ? '静音' : '取消静音', 'wr');
  });
  bindRange('mixShift', (v) => {
    S.mix.mixShift = v;
    $('mixShiftVal').textContent = v === 0 ? '×1' : '÷' + (1 << v);
    markDirty(R.MIX_SHIFT, v);
  });

  // ---- 演奏效果 ----
  $('vibSw').addEventListener('change', () => {
    S.perf.vib = $('vibSw').checked ? 1 : 0;
    markDirty(R.VIB_EN, S.perf.vib);
    syncControls();
  });
  $('glideSw').addEventListener('change', () => {
    S.perf.glide = $('glideSw').checked ? 1 : 0;
    markDirty(R.GLIDE_EN, S.perf.glide);
    syncControls();
  });
  $('monoSw').addEventListener('change', () => {
    S.perf.mono = $('monoSw').checked ? 1 : 0;
    markDirty(R.MONO, S.perf.mono);
    syncControls();
  });
  bindRange('vibRate', (v) => {
    S.perf.vibRate = v;
    $('vibRateVal').textContent = (v / 10).toFixed(1) + ' Hz';
    markDirty(R.VIB_RATE, v);
  });
  bindRange('vibDepth', (v) => {
    S.perf.vibDepth = v;
    $('vibDepthVal').textContent = '±' + perfCents(v) + ' 音分';
    markDirty(R.VIB_DEPTH, v);
  });
  bindRange('glideTime', (v) => {
    S.perf.glideShift = v;
    $('glideTimeVal').textContent = 'τ ' + fmtTime(glideTau(v));
    markDirty(R.GLIDE_SHIFT, v);
  });
  bindRange('transpose', (v) => {
    S.perf.transpose = v;
    $('transposeVal').textContent = (v > 0 ? '+' : '') + v + ' 半音';
    markDirty(R.TRANSPOSE, v);
    syncControls();
  });
  $('transposeReset').addEventListener('click', () => {
    S.perf.transpose = 0;
    markDirty(R.TRANSPOSE, 0);
    syncControls();
  });

  // ---- 八度 ----
  bindRange('octave', (v) => {
    S.perf.octave = v;
    S.lastOctSentAt = performance.now();
    syncOctaveUI();
    $('octNum').textContent = v > 0 ? '+' + v : (v < 0 ? '' + v : '0');
    markDirty(R.OCTAVE, v);
  });
  $('octaveReset').addEventListener('click', () => {
    S.perf.octave = 0;
    S.lastOctSentAt = performance.now();
    syncOctaveUI();
    markDirty(R.OCTAVE, 0);
    syncControls();
  });

  // ---- 延音踏板 ----
  bindRange('sustain', (v) => {
    S.perf.sustain = v;
    syncSustainUI();
    markDirty(R.SUSTAIN, v);
  });
  $('sustainReset').addEventListener('click', () => {
    S.perf.sustain = 0;
    syncSustainUI();
    markDirty(R.SUSTAIN, 0);
    syncControls();
  });

  // ---- 全局效果器 ----
  function bindFxSwitch(id, key, reg) {
    $(id).addEventListener('change', () => {
      S.fx[key] = $(id).checked ? 1 : 0;
      markDirty(reg, S.fx[key]);
      syncFxUI();
    });
  }
  function bindFxRange(id, key, reg, after) {
    $(id).addEventListener('input', () => {
      S.fx[key] = +$(id).value;
      setFill($(id));
      markDirty(reg, S.fx[key]);
      syncFxUI();
      if (after) after();
    });
  }
  bindFxSwitch('echoOn', 'echoOn', R.ECHO_ON);
  bindFxRange('echoTime', 'echoTime', R.ECHO_TIME);
  bindFxRange('echoFb', 'echoFb', R.ECHO_FB);
  bindFxRange('echoMix', 'echoMix', R.ECHO_MIX);

  bindFxSwitch('revOn', 'revOn', R.REV_ON);
  bindFxRange('revSize', 'revSize', R.REV_SIZE);
  bindFxRange('revDamp', 'revDamp', R.REV_DAMP);
  bindFxRange('revMix', 'revMix', R.REV_MIX);

  bindFxSwitch('choOn', 'choOn', R.CHO_ON);
  bindFxRange('choRate', 'choRate', R.CHO_RATE);
  bindFxRange('choDepth', 'choDepth', R.CHO_DEPTH);
  bindFxRange('choMix', 'choMix', R.CHO_MIX);

  bindFxSwitch('phaOn', 'phaOn', R.PHA_ON);
  bindFxRange('phaRate', 'phaRate', R.PHA_RATE);
  bindFxRange('phaDepth', 'phaDepth', R.PHA_DEPTH);
  bindFxRange('phaFb', 'phaFb', R.PHA_FB);
  bindFxRange('phaMix', 'phaMix', R.PHA_MIX);

  bindFxSwitch('drvOn', 'drvOn', R.DRV_ON);
  bindFxRange('drvDrive', 'drvDrive', R.DRV_DRIVE);
  bindFxRange('drvTone', 'drvTone', R.DRV_TONE);
  bindFxRange('drvMix', 'drvMix', R.DRV_MIX);

  bindFxSwitch('limOn', 'limOn', R.LIM_ON);
  bindFxRange('limTh', 'limTh', R.LIM_TH);
  bindFxRange('limCeil', 'limCeil', R.LIM_CEIL);
  bindFxRange('limRel', 'limRel', R.LIM_REL);

  // ---- 32 声部齐奏 ----
  bindFxSwitch('uniOn', 'uniOn', R.UNISON_ON);
  bindFxRange('uniLayers', 'uniLayers', R.UNISON_LAYERS);
  bindFxRange('uniDetune', 'uniDetune', R.UNISON_DETUNE);
  bindFxRange('uniMix', 'uniMix', R.UNISON_MIX);

  // ---- PWM 脉宽调制 ----
  // PWM 只作用在方波：动 PWM 时如果当前不是方波，自动切到方波（同时进入自定义档）
  function ensurePwmSquare() {
    if (S.live.wave === 0) return;
    S.live.wave = 0;
    markDirty(R.WAVE, 0);
    markCustom();
    syncControls();
    scheduleDraw();
    log('PWM 只作用在方波 -> 已自动切到方波', 'wr');
  }
  bindFxRange('pwmWidth', 'pwmWidth', R.PWM_WIDTH, ensurePwmSquare);
  bindFxRange('pwmRate', 'pwmRate', R.PWM_RATE, ensurePwmSquare);
  bindFxRange('pwmDepth', 'pwmDepth', R.PWM_DEPTH, ensurePwmSquare);

  // ---- 均衡器 ----
  function bindEq(id, key, reg) {
    $(id).addEventListener('input', () => {
      const db = +$(id).value;
      S.eq[key] = eqDbToCode(db);
      markDirty(reg, S.eq[key]);
      // 只更新本段标签，避免拖动时把滑块值回写成取整后的 dB
      const lab = $(id + 'Val');
      lab.textContent = fmtDb(eqCodeToDb(S.eq[key]));
      lab.classList.toggle('cut', db < 0);
      setFill($(id));
    });
  }
  $('eqOn').addEventListener('change', () => {
    S.eq.on = $('eqOn').checked ? 1 : 0;
    markDirty(R.EQ_ON, S.eq.on);
    syncEqUI();
  });
  bindEq('eqLow', 'low', R.EQ_LOW);
  bindEq('eqLmid', 'lmid', R.EQ_LMID);
  bindEq('eqMid', 'mid', R.EQ_MID);
  bindEq('eqHmid', 'hmid', R.EQ_HMID);
  bindEq('eqHigh', 'high', R.EQ_HIGH);
  $('eqOut').addEventListener('input', () => {
    S.eq.out = +$('eqOut').value;
    setFill($('eqOut'));
    $('eqOutVal').textContent = fmtPct(S.eq.out, 255);
    markDirty(R.EQ_OUT, S.eq.out);
  });

  // ---- 32 声道滑块（事件委托）----
  $('voiceSections').addEventListener('input', (e) => {
    const el = e.target.closest('.ch-range');
    if (!el) return;
    const i = +el.dataset.ch;
    const key = el.dataset.param;
    const v = +el.value;
    S.ch[i][key] = v;
    setFill(el);
    const lab = document.querySelector('[data-chval="' + i + '-' + key + '"]');
    if (lab) lab.textContent = channelLabel(i, key, v);
    // ★ 调整某路发送量时自动打开对应的全局效果器
    const sendFx = {
      echo:   ['echoOn', R.ECHO_ON, '回声'],
      reverb: ['revOn',  R.REV_ON,  '混响'],
      chorus: ['choOn',  R.CHO_ON,  '合唱'],
      phaser: ['phaOn',  R.PHA_ON,  '相位'],
    }[key];
    if (sendFx && v > 0 && !S.fx[sendFx[0]]) {
      S.fx[sendFx[0]] = 1;
      markDirty(sendFx[1], 1);
      syncFxUI();
      log('已自动打开' + sendFx[2] + '效果器（声部 ' + (i + 1) + ' 发送量 ' + v + '/15）', 'wr');
    }
    if (key === 'vol' || key === 'dist') {
      markDirty(R.CHA0 + i, packChA(S.ch[i].vol, S.ch[i].dist));
    } else {
      markDirty(R.CHB0 + i, packChB(S.ch[i].echo, S.ch[i].reverb, S.ch[i].chorus, S.ch[i].phaser));
    }
  });

  // 连接
  $('btnConnect').addEventListener('click', connect);
  $('btnDisconnect').addEventListener('click', disconnect);
  $('btnPing').addEventListener('click', () => {
    sendFrame(T.PING, []);
    log('TX PING', 'tx');
  });

  // 帮助
  $('btnHelp').addEventListener('click', () => $('helpModal').classList.remove('hidden'));
  $('btnCloseHelp').addEventListener('click', () => $('helpModal').classList.add('hidden'));
  $('helpModal').addEventListener('click', (e) => {
    if (e.target.id === 'helpModal') $('helpModal').classList.add('hidden');
  });

  // 日志
  $('btnToggleLog').addEventListener('click', () => {
    logWrap.classList.toggle('hidden');
  });
  $('btnClearLog').addEventListener('click', () => { logEl.innerHTML = ''; });
  $('logFrames').addEventListener('change', () => {
    S.logFrames = $('logFrames').checked;
    log(S.logFrames ? '开始显示收发帧（只显示非遥测帧，避免刷屏）' : '停止显示收发帧');
  });

  // 读回 FPGA 里的真实参数（调试用；会覆盖页面上的当前值，
  // 但不会动"本地预设"，点一下预设就能恢复你自己的设置）
  $('btnRead').addEventListener('click', () => {
    if (!S.connected) { log('先连接串口再读回', 'er'); return; }
    readAll(true);
  });

  /* ---------------- 本地存储 / 导入导出 ---------------- */
  // 兼容旧版本/手改的 JSON：补齐缺失字段，避免 UI 出现 undefined
  function normalizeState() {
    for (let id = 0; id <= CUSTOM_ID; id++) {
      if (!S.presets[id]) S.presets[id] = clone(FACTORY_PRESETS[id]);
      const p = S.presets[id];
      if (!Array.isArray(p.h)) p.h = [0, 0, 0, 0];
      p.h = p.h.slice(0, 4);
      while (p.h.length < 4) p.h.push(0);
      for (const k of ['wave', 'fmRatio', 'fmDepth', 'rate', 'exp',
                       'atk', 'dec', 'sus', 'rel', 'velPress', 'oneshot']) {
        if (typeof p[k] !== 'number' || !isFinite(p[k])) p[k] = FACTORY_PRESETS[id][k];
      }
    }
    if (!S.mix || typeof S.mix !== 'object') S.mix = clone(FACTORY_MIX);
    if (!Array.isArray(S.mix.keyVol)) S.mix.keyVol = [];
    S.mix.keyVol = S.mix.keyVol.slice(0, 8);
    while (S.mix.keyVol.length < 8) S.mix.keyVol.push(128);
    // 2026-10-26 第三轮起，每键音量由通道条的"音量"负责；
    // KEY_VOL 固定 128，避免旧存档里的 0 把某个键悄悄静音。
    for (let i = 0; i < 8; i++) S.mix.keyVol[i] = 128;
    for (const k of ['master', 'mute', 'mixShift']) {
      if (typeof S.mix[k] !== 'number') S.mix[k] = FACTORY_MIX[k];
    }

    // 演奏效果
    if (!S.perf || typeof S.perf !== 'object') S.perf = clone(FACTORY_PERF);
    for (const k of Object.keys(FACTORY_PERF)) {
      if (typeof S.perf[k] !== 'number' || !isFinite(S.perf[k])) S.perf[k] = FACTORY_PERF[k];
    }
    S.perf.transpose  = Math.max(-12, Math.min(12, Math.round(S.perf.transpose)));
    S.perf.octave     = Math.max(-2, Math.min(2, Math.round(S.perf.octave || 0)));
    S.perf.sustain    = Math.max(0, Math.min(127, Math.round(S.perf.sustain || 0)));
    S.perf.glideShift = Math.max(0, Math.min(15, Math.round(S.perf.glideShift)));
    S.perf.vibRate    = Math.max(5, Math.min(120, Math.round(S.perf.vibRate)));
    S.perf.vibDepth   = Math.max(0, Math.min(127, Math.round(S.perf.vibDepth)));
    S.perf.mono = S.perf.mono ? 1 : 0;
    S.perf.glide = S.perf.glide ? 1 : 0;
    S.perf.vib = S.perf.vib ? 1 : 0;

    // 32 声道
    if (!Array.isArray(S.ch)) S.ch = [];
    S.ch = S.ch.slice(0, CH_COUNT);
    for (let i = 0; i < CH_COUNT; i++) {
      S.ch[i] = Object.assign(factoryChannel(), S.ch[i] || {});
      const c = S.ch[i];
      c.vol = Math.max(0, Math.min(128, Math.round(c.vol)));
      c.dist = Math.max(0, Math.min(127, Math.round(c.dist)));
      for (const k of ['echo', 'reverb', 'chorus', 'phaser']) {
        c[k] = Math.max(0, Math.min(15, Math.round(c[k])));
      }
    }

    // 全局效果器
    if (!S.fx || typeof S.fx !== 'object') S.fx = clone(FACTORY_FX);
    for (const k of Object.keys(FACTORY_FX)) {
      if (typeof S.fx[k] !== 'number' || !isFinite(S.fx[k])) S.fx[k] = FACTORY_FX[k];
      const max = k.endsWith('On') ? 1 : (k === 'echoTime' || k === 'limTh' || k === 'limCeil') ? 255 :
        (k.endsWith('Fb') ? 15 : 127);
      S.fx[k] = Math.max(0, Math.min(max, Math.round(S.fx[k])));
    }
    S.fx.uniLayers = Math.max(1, Math.min(4, Math.round(S.fx.uniLayers || 4)));
    S.fx.pwmWidth = Math.max(0, Math.min(255, Math.round(S.fx.pwmWidth ?? 128)));
    // 旧默认值太保守，听起来像没效果；一次性迁移到更明显的默认
    if (S.fx.uniMix === 48 && S.fx.uniDetune === 48 && S.fx.uniOn) {
      S.fx.uniMix = 100;
      S.fx.uniDetune = 64;
    }
    if (S.fx.pwmWidth === 128 && S.fx.pwmRate === 30 && S.fx.pwmDepth === 64) {
      S.fx.pwmDepth = 96;
    }

    // 5 段均衡
    if (!S.eq || typeof S.eq !== 'object') S.eq = clone(FACTORY_EQ);
    S.eq.on = S.eq.on ? 1 : 0;
    for (const k of ['low', 'lmid', 'mid', 'hmid', 'high']) {
      S.eq[k] = Math.max(1, Math.min(63, Math.round(S.eq[k] || 16)));
    }
    S.eq.out = Math.max(0, Math.min(255, Math.round(S.eq.out)));
  }

  function saveLocal() {
    try {
      persistLive();
      localStorage.setItem(STORAGE_KEY, JSON.stringify({
        version: 4,
        presets: S.presets,
        mix: S.mix,
        perf: S.perf,
        ch: S.ch,
        fx: S.fx,
        eq: S.eq,
      }));
      log('已保存到浏览器（localStorage）', 'wr');
    } catch (e) {
      log('保存失败：' + e.message, 'er');
    }
  }

  function loadLocal() {
    try {
      const raw = localStorage.getItem(STORAGE_KEY);
      if (!raw) return;
      const d = JSON.parse(raw);
      if (d.presets) {
        for (const k of Object.keys(FACTORY_PRESETS)) {
          if (d.presets[k]) S.presets[k] = Object.assign(clone(FACTORY_PRESETS[k]), d.presets[k]);
        }
      }
      if (d.mix) S.mix = Object.assign(clone(FACTORY_MIX), d.mix);
      if (d.perf) S.perf = Object.assign(clone(FACTORY_PERF), d.perf);
      if (d.ch) S.ch = clone(d.ch);
      if (d.fx) S.fx = Object.assign(clone(FACTORY_FX), d.fx);
      if (d.eq) S.eq = Object.assign(clone(FACTORY_EQ), d.eq);
      normalizeState();
      S.live = clone(S.presets[S.timbre]);
      log('已恢复浏览器里保存的设置（含 32 声道 / 效果器 / EQ）', 'wr');
    } catch (e) {
      log('恢复本地设置失败：' + e.message, 'er');
    }
  }

  function exportJson() {
    persistLive();
    const d = {
      version: 4,
      exportedAt: new Date().toISOString(),
      presets: S.presets,
      mix: S.mix,
      perf: S.perf,
      ch: S.ch,
      fx: S.fx,
      eq: S.eq,
    };
    const blob = new Blob([JSON.stringify(d, null, 2)], { type: 'application/json' });
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = 'fpga-synth-presets.json';
    a.click();
    setTimeout(() => URL.revokeObjectURL(a.href), 1500);
    log('已导出 JSON（预设 + 混音台 + 效果器 + EQ）', 'wr');
  }

  async function importJson(file) {
    try {
      const txt = await file.text();
      const d = JSON.parse(txt);
      if (!d || typeof d !== 'object') throw new Error('不是有效的 JSON');
      if (d.presets) {
        for (const k of Object.keys(FACTORY_PRESETS)) {
          if (d.presets[k]) S.presets[k] = Object.assign(clone(FACTORY_PRESETS[k]), d.presets[k]);
        }
      }
      if (d.mix) S.mix = Object.assign(clone(FACTORY_MIX), d.mix);
      if (d.perf) S.perf = Object.assign(clone(FACTORY_PERF), d.perf);
      if (d.ch) S.ch = clone(d.ch);
      if (d.fx) S.fx = Object.assign(clone(FACTORY_FX), d.fx);
      if (d.eq) S.eq = Object.assign(clone(FACTORY_EQ), d.eq);
      normalizeState();
      S.live = clone(S.presets[S.timbre]);
      applySustainForTimbre();
      syncControls();
      scheduleDraw();
      saveLocal();
      if (S.connected) {
        await selectTimbre(S.timbre);
        await sendMix();
        await sendPerf();
        await sendChannels();
        autoEnableFxFromSends();
        syncFxUI();
        await sendFx();
        await sendEq();
      }
      log('已导入 JSON（预设 + 混音 + 演奏 + 32 声道 + 效果器 + EQ）', 'wr');
    } catch (e) {
      log('导入失败：' + e.message, 'er');
    }
  }

  $('btnSave').addEventListener('click', saveLocal);
  $('btnExport').addEventListener('click', exportJson);
  $('btnImport').addEventListener('click', () => $('fileImport').click());
  $('fileImport').addEventListener('change', (e) => {
    if (e.target.files && e.target.files[0]) importJson(e.target.files[0]);
    e.target.value = '';
  });
  $('btnFactory').addEventListener('click', async () => {
    if (!confirm('恢复出厂预设？这会覆盖你在网页里改过的音色、32 声道、效果器和 EQ。')) return;
    S.presets = clone(FACTORY_PRESETS);
    S.mix = clone(FACTORY_MIX);
    S.perf = clone(FACTORY_PERF);
    S.ch = clone(FACTORY_CH);
    S.fx = clone(FACTORY_FX);
    S.eq = clone(FACTORY_EQ);
    loadLocalPreset(S.timbre);
    saveLocal();
    if (S.connected) {
      await selectTimbre(S.timbre);
      await sendMix();
      await sendPerf();
      await sendChannels();
      autoEnableFxFromSends();
      syncFxUI();
      await sendFx();
      await sendEq();
    }
    S.polyPeakEff = 0;
    log('已恢复出厂预设（含 32 声道 / 效果器 / EQ）', 'wr');
  });

  /* ---------------- 生成动态控件 ---------------- */
  function buildVoiceStrips() {
    const vrow = (i, key, label, min, max, val) =>
      '<div class="vrow">' +
        '<span class="vrow-k">' + label + '</span>' +
        '<input type="range" class="ch-range" data-ch="' + i + '" data-param="' + key + '"' +
          ' min="' + min + '" max="' + max + '" step="1" value="' + val + '">' +
        '<span class="vrow-v" data-chval="' + i + '-' + key + '">' + channelLabel(i, key, val) + '</span>' +
      '</div>';

    const strip = (i) => {
      const c = S.ch[i];
      const name = i < 8 ? NOTES[i] : '预留';
      return '<div class="voice-strip' + (i < 8 ? ' active' : ' idle') + '" data-voice="' + i + '">' +
        '<div class="voice-head">' +
          '<span class="voice-num">声部 ' + (i + 1) + '</span>' +
          '<span class="voice-name">' + name + '</span>' +
          '<i class="voice-led" title="发声指示"></i>' +
        '</div>' +
        '<div class="vrows">' +
          vrow(i, 'vol', '音量', 0, 128, c.vol) +
          vrow(i, 'dist', '失真', 0, 127, c.dist) +
          '<div class="voice-sends-label">发送量 → 全局效果器</div>' +
          vrow(i, 'echo', '回声', 0, 15, c.echo) +
          vrow(i, 'reverb', '混响', 0, 15, c.reverb) +
          vrow(i, 'chorus', '合唱', 0, 15, c.chorus) +
          vrow(i, 'phaser', '相位', 0, 15, c.phaser) +
        '</div>' +
      '</div>';
    };

    let html = '<section class="voice-section">' +
      '<div class="voice-group-head"><span>使用中的声部</span><span>1–8 · 8 键</span></div>' +
      '<div class="voice-grid">';
    for (let i = 0; i < 8; i++) html += strip(i);
    html += '</div></section>';

    for (let g = 8; g < CH_COUNT; g += 8) {
      html += '<details class="voice-fold">' +
        '<summary>声部 ' + (g + 1) + '–' + (g + 8) + '（预留 · 默认折叠）</summary>' +
        '<div class="voice-grid">';
      for (let i = g; i < g + 8; i++) html += strip(i);
      html += '</div></details>';
    }
    $('voiceSections').innerHTML = html;
  }

  function buildStaticUI() {
    // 预设按钮
    $('presetGrid').innerHTML = TIMBRES.map((t) =>
      '<button class="preset-btn" data-timbre="' + t.id + '" style="--pcolor:' + t.color + '">' +
      '<span class="p-name">' + t.name + '</span>' +
      '<span class="p-kind">' + t.kind + '</span></button>'
    ).join('');

    // 泛音滑块
    $('harmGrid').innerHTML = HARM_BASE.map((base, i) =>
      '<div class="harm-row">' +
        '<span class="h-name">' + HARM_NAMES[i] + '</span>' +
        '<input type="range" class="h-range" data-h="' + i + '" min="0" max="3" step="1" value="0">' +
        '<span class="h-val mono" data-hval="' + i + '">' + base + '</span>' +
        '<span class="h-att mono" data-hatt="' + i + '">×1</span>' +
      '</div>'
    ).join('');

    // 32 声部混音台（1–8 展开，9–32 折叠）
    buildVoiceStrips();

    // 按键指示
    $('keyDots').innerHTML = NOTES.map((n, i) =>
      '<div class="keydot" data-dot="' + i + '"><b>' + n + '</b><i></i></div>'
    ).join('');
  }

  /* ---------------- 启动 ---------------- */
  buildStaticUI();

  // 动态控件建好后再绑定事件
  document.querySelectorAll('.preset-btn').forEach((b) => {
    b.addEventListener('click', () => selectTimbre(+b.dataset.timbre));
  });
  document.querySelectorAll('.h-range').forEach((el) => {
    el.addEventListener('input', () => {
      const i = +el.dataset.h;
      const v = +el.value;
      S.live.h[i] = v;
      setFill(el);
      const eff = effectiveHarmonics(S.live.h);
      document.querySelector('[data-hval="' + i + '"]').textContent = String(eff[i]);
      document.querySelector('[data-hatt="' + i + '"]').textContent = v === 0 ? '×1' : '×1/' + (1 << v);
      $('harmLabel').textContent = eff.join(' : ');
      markDirty(R.H1 + i, v);
      markCustom();
      scheduleDraw();
    });
  });

  // 声部折叠 / 展开
  $('expandAllVoices').addEventListener('click', () => {
    document.querySelectorAll('.voice-fold').forEach((d) => { d.open = true; });
    log('已展开全部 32 个声部');
  });
  $('collapseAllVoices').addEventListener('click', () => {
    document.querySelectorAll('.voice-fold').forEach((d) => { d.open = false; });
    log('已折叠未使用的声部（9–32）');
  });

  // ---- 监视器波形/频谱预览（按当前音色/按键/PWM 估算，HDMI 上是实测频谱） ----
  const monWaveCanvas = $('monWaveCanvas');
  const specCanvas = $('monSpecCanvas');
  let scopeLast = 0;
  function drawScopePreview(now) {
    requestAnimationFrame(drawScopePreview);
    if (!monWaveCanvas || !specCanvas || now - scopeLast < 40) return;
    scopeLast = now;
    const p = S.live || FACTORY_PRESETS[S.timbre] || FACTORY_PRESETS[1];
    const fx = S.fx;
    const N = 128;
    const buf = new Float32Array(N);
    const pwmW = Math.max(0.02, Math.min(0.98, (fx.pwmWidth ?? 128) / 255));
    const pwmD = (fx.pwmDepth ?? 0) / 127;
    const lfo = Math.sin(now / 1000 * Math.PI * 2 * ((fx.pwmRate ?? 0) / 10));
    const duty = Math.max(0.03, Math.min(0.97, pwmW + 0.45 * pwmD * lfo));
    const ratio = [0.5, 1, 1.5, 2, 2.5, 3, 3.5, 4][p.fmRatio | 0] ?? 1;
    const fmDep = (4 - (p.fmDepth | 0)) / 4;
    for (let i = 0; i < N; i++) {
      const f = (i / N) * 2;                 // 显示两个周期
      const ph = 2 * Math.PI * f;
      const frac = f % 1;
      let v = 0;
      switch (p.wave) {
        case 0: v = frac < duty ? 1 : -1; break;
        case 1: v = 2 * frac - 1; break;
        case 2: v = 1 - 4 * Math.abs(frac - 0.5); break;
        case 3: v = Math.sin(ph); break;
        case 4: v = Math.sin(ph) + 0.5 * Math.sin(2 * ph) + 0.33 * Math.sin(3 * ph) + 0.2 * Math.sin(4 * ph); break;
        default: v = Math.sin(ph + fmDep * 2.2 * Math.sin(ph * ratio)); break;
      }
      buf[i] = v;
    }
    const keys = popcount8(S.lastKeys || 0);
    const target = keys > 0 ? 1 : 0;
    S.scopeAmp += (target - S.scopeAmp) * 0.18;
    const amp = 0.12 + 0.88 * S.scopeAmp;

    const w = monWaveCanvas.width, h = monWaveCanvas.height;
    const g = monWaveCanvas.getContext('2d');
    g.clearRect(0, 0, w, h);
    g.strokeStyle = 'rgba(32,120,110,.25)'; g.lineWidth = 1;
    g.beginPath(); g.moveTo(0, h / 2); g.lineTo(w, h / 2); g.stroke();
    g.strokeStyle = '#38e1c6'; g.lineWidth = 1.5; g.beginPath();
    for (let i = 0; i < N; i++) {
      const x = (i / (N - 1)) * w;
      const y = h / 2 - buf[i] * (h * 0.38) * amp;
      if (i === 0) g.moveTo(x, y); else g.lineTo(x, y);
    }
    g.stroke();

    const s = specCanvas.getContext('2d');
    const sw = specCanvas.width, sh = specCanvas.height;
    s.clearRect(0, 0, sw, sh);
    const bins = 16, bw = sw / bins;
    for (let k = 0; k < bins; k++) {
      let re = 0, im = 0;
      for (let n = 0; n < N; n++) {
        const a = 2 * Math.PI * k * n / N;
        re += buf[n] * Math.cos(a);
        im -= buf[n] * Math.sin(a);
      }
      const mag = Math.sqrt(re * re + im * im) / N;
      const lv = Math.min(1, Math.pow(mag * 5.5 * amp, 0.55));
      const bh = Math.max(1, lv * (sh - 4));
      const hue = 170 - k * 6;
      s.fillStyle = 'hsl(' + hue + ',80%,' + (38 + lv * 25) + '%)';
      s.fillRect(k * bw + 1, sh - bh - 2, bw - 2, bh);
    }
    if ($('scopeHint')) $('scopeHint').textContent = (TIMBRES[S.timbre] || {}).name + ' · ' + keys + ' 键';
  }
  requestAnimationFrame(drawScopePreview);

  loadLocal();
  normalizeState();
  S.live = clone(S.presets[S.timbre]);
  applySustainForTimbre();
  syncControls();
  scheduleDraw();

  if (!('serial' in navigator)) {
    $('unsupported').classList.remove('hidden');
    setConnUI('err', '浏览器不支持');
    log('当前浏览器没有 Web Serial。请用 Chrome / Edge 89+ 打开，或运行 web\\启动控制台.cmd。', 'er');
  } else {
    log('控制台就绪。点击「连接串口」选择 DEBUG-USB2 对应的 COM 口。');
  }

  // 窗口尺寸变化重画
  let resizeTimer = null;
  window.addEventListener('resize', () => {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(scheduleDraw, 120);
  });

  // 浏览器串口热插拔
  if ('serial' in navigator) {
    navigator.serial.addEventListener('disconnect', (e) => {
      if (S.port && e.target === S.port) {
        log('USB 串口被拔出', 'er');
        disconnect();
      }
    });
  }
}

/* ============================================================
   6. 浏览器启动 / Node 导出
   ============================================================ */
if (typeof document !== 'undefined') {
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', initUI);
  } else {
    initUI();
  }
}

if (typeof module !== 'undefined' && module.exports) {
  module.exports = {
    BAUD, R, T, TIMBRES, FACTORY_PRESETS, FACTORY_MIX, FACTORY_PERF,
    FACTORY_CH, FACTORY_FX, FACTORY_EQ, CH_COUNT, FX_REG_MAP, EQ_REG_MAP,
    WRITABLE_REGS,
    crc8, buildFrame, encodeSet, FrameParser,
    envTimes, fmtTime, stepFromPos, posFromStep, effectiveHarmonics, decodeTelemetry,
    perfCents, glideTau, echoMs, chorusHz, phaserHz, limiterDb, eqDbToCode, eqCodeToDb,
    pedalReleaseTime, popcount8, defaultSustainOnTimbre,
    packChA, packChB, unpackChA, unpackChB,
    SAMPLE_RATE, FM_RATIOS, HARM_BASE,
  };
}
