/* ============================================================
   tools/protocol_test.js
   ------------------------------------------------------------
   用 Node 跑 web/app.js 里的纯协议 / 换算逻辑，不需要浏览器。
   目的：在烧板子之前先确认网页发出去的帧、CRC、寄存器地址和
         预设数值都是对的（和 src/param_regs.v 对齐）。

   运行：  node tools/protocol_test.js
   ============================================================ */
'use strict';

const assert = require('assert');
const path = require('path');
const app = require(path.join(__dirname, '..', 'web', 'app.js'));

let passed = 0;
function test(name, fn) {
  try {
    fn();
    passed++;
    console.log('  ok   ' + name);
  } catch (e) {
    console.error('  FAIL ' + name);
    console.error(e && e.stack ? e.stack : e);
    process.exitCode = 1;
  }
}

console.log('== 协议 / CRC ==');

test('CRC8/ATM 标准向量 "123456789" = 0xF4', () => {
  const b = Buffer.from('123456789', 'ascii');
  assert.strictEqual(app.crc8(b, 0, b.length), 0xF4);
});

test('帧结构：A5 5A TYPE LEN PAYLOAD CRC', () => {
  const f = app.buildFrame(app.T.SET, [0x10, 0x04, 0x00]);
  assert.deepStrictEqual(Array.from(f.slice(0, 4)), [0xA5, 0x5A, 0x01, 0x03]);
  assert.deepStrictEqual(Array.from(f.slice(4, 7)), [0x10, 0x04, 0x00]);
  assert.strictEqual(f[7], app.crc8(f, 2, 7));
});

test('解析器：整帧 / 逐字节 / 前面带垃圾数据 都能解析', () => {
  const frame = app.buildFrame(app.T.VAL, [0x10, 0x04, 0x00, 0x11, 0x05, 0x00]);
  for (const mode of ['whole', 'bytes', 'noise']) {
    const got = [];
    const p = new app.FrameParser((t, pl) => got.push({ t, pl }));
    if (mode === 'whole') p.feed(frame);
    else if (mode === 'bytes') for (const b of frame) p.feed([b]);
    else {
      p.feed([0x00, 0xFF, 0xA5, 0x11, 0x22]);
      p.feed(frame);
    }
    assert.strictEqual(got.length, 1, mode);
    assert.strictEqual(got[0].t, app.T.VAL);
    assert.deepStrictEqual(got[0].pl, [0x10, 0x04, 0x00, 0x11, 0x05, 0x00]);
  }
});

test('解析器：CRC 错帧被丢弃，后面的好帧还能收到', () => {
  const bad = app.buildFrame(app.T.SET, [0x10, 0x04, 0x00]);
  bad[bad.length - 1] ^= 0xFF;
  const good = app.buildFrame(app.T.PING, []);
  const got = [];
  const p = new app.FrameParser((t, pl) => got.push({ t, pl }));
  p.feed(bad);
  p.feed(good);
  assert.strictEqual(got.length, 1);
  assert.strictEqual(got[0].t, app.T.PING);
  assert.ok(p.errors >= 1);
});

test('PING 帧（LEN=0）能解析', () => {
  const got = [];
  const p = new app.FrameParser((t, pl) => got.push({ t, pl }));
  p.feed(app.buildFrame(app.T.PING, []));
  assert.strictEqual(got.length, 1);
  assert.strictEqual(got[0].pl.length, 0);
});

test('encodeSet 多寄存器小端', () => {
  const f = app.encodeSet([
    { reg: app.R.TIMBRE, val: 4 },
    { reg: app.R.ATK, val: 0x1234 },
  ]);
  assert.deepStrictEqual(Array.from(f.slice(3, 10)),
    [0x06, 0x10, 0x04, 0x00, 0x22, 0x34, 0x12]);
});

test('一帧 16 项 / 48 字节（切音色用的最长帧）能解析', () => {
  const pairs = [];
  for (let i = 0; i < 16; i++) pairs.push({ reg: 0x10 + i, val: 100 + i });
  const f = app.encodeSet(pairs);
  assert.strictEqual(f[3], 48);
  const got = [];
  const p = new app.FrameParser((t, pl) => got.push({ t, pl }));
  p.feed(f);
  assert.strictEqual(got.length, 1);
  assert.strictEqual(got[0].t, app.T.SET);
  assert.strictEqual(got[0].pl.length, 48);
  // 第 0 项必须是 TIMBRE，值对
  assert.strictEqual(got[0].pl[0], app.R.TIMBRE);
  assert.strictEqual(got[0].pl[1] | (got[0].pl[2] << 8), 100);
});

console.log('== 寄存器表 / 预设 ==');

test('寄存器地址唯一，且和 param_regs.v 对齐', () => {
  const expected = {
    VERSION: 0x01, TIMBRE: 0x10, WAVE: 0x11, FM_RATIO: 0x12, FM_DEPTH: 0x13,
    H1: 0x14, H2: 0x15, H3: 0x16, H4: 0x17, VEL_PRESS: 0x18, ONESHOT: 0x19,
    MONO: 0x1A, GLIDE_EN: 0x1B, GLIDE_SHIFT: 0x1C,
    VIB_EN: 0x1D, VIB_RATE: 0x1E, VIB_DEPTH: 0x1F, TRANSPOSE: 0x26,
    RATE: 0x20, EXP: 0x21, ATK: 0x22, DEC: 0x23, SUS: 0x24, REL: 0x25,
    MIX_SHIFT: 0x30, MASTER: 0x31, MUTE: 0x32, KV0: 0x38,
    ADS_VEL: 0x40, ADS_RAW: 0x41, POLY: 0x42, PEAK: 0x43,
    OCT: 0x44, KEYS: 0x45, FLAGS: 0x46, ADS_ERR: 0x47,
  };
  for (const k of Object.keys(expected)) {
    assert.strictEqual(app.R[k], expected[k], k);
  }
  const vals = Object.values(app.R);
  assert.strictEqual(new Set(vals).size, vals.length, '地址有重复');
});

test('10 个音色预设：波形 / FM / 包络范围正确', () => {
  for (let id = 0; id <= 9; id++) {
    const p = app.FACTORY_PRESETS[id];
    assert.ok(p, '缺少预设 ' + id);
    assert.ok(p.wave >= 0 && p.wave <= 5, 'wave 越界');
    assert.ok(p.fmRatio >= 0 && p.fmRatio <= 7, 'fmRatio 越界');
    assert.ok(p.fmDepth >= 0 && p.fmDepth <= 4, 'fmDepth 越界');
    assert.ok(p.h.length === 4);
    assert.ok(p.rate >= 0 && p.rate <= 4);
    assert.ok(p.exp >= 0 && p.exp <= 15);
    assert.ok(p.atk >= 1 && p.atk <= 65535);
    assert.ok(p.sus >= 0 && p.sus <= 65535);
    assert.ok(p.rel >= 0 && p.rel <= 65535);
  }
  // 和 param_regs.v 的 f_* 函数一致
  assert.strictEqual(app.FACTORY_PRESETS[4].wave, 4);
  assert.strictEqual(app.FACTORY_PRESETS[5].wave, 5);
  assert.strictEqual(app.FACTORY_PRESETS[5].fmRatio, 1);
  assert.strictEqual(app.FACTORY_PRESETS[6].fmRatio, 6);
  assert.strictEqual(app.FACTORY_PRESETS[6].fmDepth, 1);
  assert.strictEqual(app.FACTORY_PRESETS[7].fmRatio, 3);
  assert.strictEqual(app.FACTORY_PRESETS[7].fmDepth, 3);
  assert.strictEqual(app.FACTORY_PRESETS[4].velPress, 1);
  assert.strictEqual(app.FACTORY_PRESETS[7].velPress, 0);
  assert.strictEqual(app.FACTORY_PRESETS[8].wave, 5);
  assert.strictEqual(app.FACTORY_PRESETS[8].fmRatio, 3);
  assert.strictEqual(app.FACTORY_PRESETS[8].fmDepth, 2);
  assert.strictEqual(app.FACTORY_PRESETS[9].wave, 5);
  assert.strictEqual(app.FACTORY_PRESETS[9].fmRatio, 6);
  assert.strictEqual(app.FACTORY_PRESETS[9].fmDepth, 1);
});

test('包络时间换算：钢琴 ≈ 5ms 起音 / 0.3~0.8s 尾音', () => {
  const t = app.envTimes(app.FACTORY_PRESETS[4]);
  assert.ok(t.tA > 0.002 && t.tA < 0.01, '起音 ' + t.tA);
  assert.ok(t.tD > 0.2 && t.tD < 1.0, '衰减 ' + t.tD);
  assert.ok(t.tR < 0.01, '一次包络的释音应该是瞬间');
  // 持续音：20ms 起音、70% 延音
  const s = app.envTimes(app.FACTORY_PRESETS[1]);
  assert.ok(s.tA > 0.015 && s.tA < 0.03, '持续音起音 ' + s.tA);
  assert.ok(Math.abs(s.target - 45874 / 65535) < 1e-6);
});

test('滑块 <-> 步长：单调、端点正确、允许 0', () => {
  assert.strictEqual(app.stepFromPos(0, false), 1);
  assert.strictEqual(app.stepFromPos(1000, false), 65535);
  assert.strictEqual(app.stepFromPos(0, true), 0);
  assert.strictEqual(app.stepFromPos(1000, true), 65535);
  let prev = -1;
  for (let i = 0; i <= 1000; i += 17) {
    const v = app.stepFromPos(i, false);
    assert.ok(v >= prev, '不单调');
    prev = v;
  }
  for (const st of [1, 2, 67, 500, 4096, 30000, 65535]) {
    const pos = app.posFromStep(st, false);
    const back = app.stepFromPos(pos, false);
    assert.ok(Math.abs(back - st) / st < 0.05, st + ' -> ' + pos + ' -> ' + back);
  }
  assert.strictEqual(app.posFromStep(0, true), 0);
});

test('泛音衰减换算', () => {
  assert.deepStrictEqual(app.effectiveHarmonics([0, 0, 0, 0]), [51, 33, 24, 17]);
  assert.deepStrictEqual(app.effectiveHarmonics([1, 1, 1, 1]), [25, 16, 12, 8]);
  assert.deepStrictEqual(app.effectiveHarmonics([3, 3, 3, 3]), [6, 4, 3, 2]);
});

test('演奏效果：开关 / 速率 / 深度 / 变调补码', () => {
  const pairs = [
    { reg: app.R.MONO, val: 1 },
    { reg: app.R.GLIDE_EN, val: 1 },
    { reg: app.R.GLIDE_SHIFT, val: 12 },
    { reg: app.R.VIB_EN, val: 1 },
    { reg: app.R.VIB_RATE, val: 55 },
    { reg: app.R.VIB_DEPTH, val: 40 },
    { reg: app.R.TRANSPOSE, val: -3 },
  ];
  const regs = new Map();
  const p = new app.FrameParser((t, pl) => {
    if (t !== app.T.SET) return;
    for (let i = 0; i + 2 < pl.length; i += 3) {
      regs.set(pl[i], pl[i + 1] | (pl[i + 2] << 8));
    }
  });
  p.feed(app.encodeSet(pairs));
  assert.strictEqual(regs.get(app.R.MONO), 1);
  assert.strictEqual(regs.get(app.R.GLIDE_EN), 1);
  assert.strictEqual(regs.get(app.R.GLIDE_SHIFT), 12);
  assert.strictEqual(regs.get(app.R.VIB_EN), 1);
  assert.strictEqual(regs.get(app.R.VIB_RATE), 55);
  assert.strictEqual(regs.get(app.R.VIB_DEPTH), 40);
  // 负数按 16 位补码发下去，FPGA 里按有符号解释
  const raw = regs.get(app.R.TRANSPOSE);
  assert.strictEqual(raw, 65533);
  assert.strictEqual(raw > 32767 ? raw - 65536 : raw, -3);
});

test('颤音音分 / 滑音时间换算', () => {
  assert.strictEqual(app.perfCents(0), 0);
  const c40 = app.perfCents(40);
  assert.ok(c40 >= 30 && c40 <= 36, 'depth40 cents=' + c40);
  const c127 = app.perfCents(127);
  assert.ok(c127 >= 100 && c127 <= 106, 'depth127 cents=' + c127);
  assert.ok(Math.abs(app.glideTau(10) - 1024 / app.SAMPLE_RATE) < 1e-12);
  assert.ok(app.glideTau(15) > app.glideTau(10));
});

test('FACTORY_PERF 默认值与范围', () => {
  const p = app.FACTORY_PERF;
  assert.strictEqual(p.mono, 0);
  assert.strictEqual(p.glide, 0);
  assert.strictEqual(p.glideShift, 10);
  assert.strictEqual(p.vib, 0);
  assert.strictEqual(p.vibRate, 55);
  assert.strictEqual(p.vibDepth, 40);
  assert.strictEqual(p.transpose, 0);
  for (const r of [app.R.MONO, app.R.GLIDE_SHIFT, app.R.VIB_RATE, app.R.VIB_DEPTH, app.R.TRANSPOSE]) {
    assert.ok(app.WRITABLE_REGS.includes(r), 'WRIABLE_REGS 缺少 ' + r);
  }
});

console.log('== 模拟 FPGA：应用网页发来的参数 ==');

test('网页的预设帧 -> 模拟寄存器全部正确', () => {
  // 模拟 param_regs 的 SET 处理（只做地址/值，不做 clamp）
  const regs = new Map();
  const parser = new app.FrameParser((type, pl) => {
    if (type !== app.T.SET) return;
    for (let i = 0; i + 2 < pl.length; i += 3) {
      regs.set(pl[i], pl[i + 1] | (pl[i + 2] << 8));
    }
  });

  const p = app.FACTORY_PRESETS[6]; // 木琴
  const pairs = [
    { reg: app.R.TIMBRE, val: 6 },
    { reg: app.R.WAVE, val: p.wave },
    { reg: app.R.FM_RATIO, val: p.fmRatio },
    { reg: app.R.FM_DEPTH, val: p.fmDepth },
    { reg: app.R.H1, val: p.h[0] },
    { reg: app.R.H2, val: p.h[1] },
    { reg: app.R.H3, val: p.h[2] },
    { reg: app.R.H4, val: p.h[3] },
    { reg: app.R.VEL_PRESS, val: p.velPress },
    { reg: app.R.ONESHOT, val: p.oneshot },
    { reg: app.R.RATE, val: p.rate },
    { reg: app.R.EXP, val: p.exp },
    { reg: app.R.ATK, val: p.atk },
    { reg: app.R.DEC, val: p.dec },
    { reg: app.R.SUS, val: p.sus },
    { reg: app.R.REL, val: p.rel },
  ];
  // 按 16 项一帧拆分
  for (let i = 0; i < pairs.length; i += 16) {
    parser.feed(app.encodeSet(pairs.slice(i, i + 16)));
  }
  assert.strictEqual(regs.get(app.R.TIMBRE), 6);
  assert.strictEqual(regs.get(app.R.WAVE), 5);
  assert.strictEqual(regs.get(app.R.FM_RATIO), 6);
  assert.strictEqual(regs.get(app.R.FM_DEPTH), 1);
  assert.strictEqual(regs.get(app.R.RATE), 2);
  assert.strictEqual(regs.get(app.R.EXP), 8);
  assert.strictEqual(regs.get(app.R.ATK), 16384);
  assert.strictEqual(regs.get(app.R.SUS), 0);
  assert.strictEqual(regs.get(app.R.REL), 4096);
});

console.log('== 遥测拆包 ==');

test('遥测 16 字节字段映射', () => {
  const pl = [
    7,        // timbre
    5,        // wave
    120,      // vel
    201,      // raw
    3,        // poly
    5,        // peak
    0xFE,     // oct = -2 (two's complement)
    0b1010_0101, // keys
    0x07,     // flags = ok|dbg|seen
    2,        // err
    200,      // master
    0b0000_1010, // mix_shift=5, mute=0
    9,        // sets
    1,        // rxerr
    0x34,     // frame lo
    0x12,     // frame hi
  ];
  const t = app.decodeTelemetry(pl);
  assert.strictEqual(t.timbre, 7);
  assert.strictEqual(t.wave, 5);
  assert.strictEqual(t.vel, 120);
  assert.strictEqual(t.raw, 201);
  assert.strictEqual(t.poly, 3);
  assert.strictEqual(t.peak, 5);
  assert.strictEqual(t.oct, -2);
  assert.strictEqual(t.keys, 0b1010_0101);
  assert.strictEqual(t.err, 2);
  assert.strictEqual(t.master, 200);
  assert.strictEqual(t.mixmute & 1, 0);
  assert.strictEqual((t.mixmute >> 1) & 7, 5);
  assert.strictEqual(t.sets, 9);
  assert.strictEqual(t.rxerr, 1);
  assert.strictEqual(t.frame, 0x1234);
});

console.log('== 32 声道混音台 / 效果器 / EQ ==');

test('新增寄存器地址和 WRITABLE_REGS 对齐', () => {
  const expected = {
    OCTAVE: 0x27,
    SUSTAIN: 0x28,
    UNISON_ON: 0x29, UNISON_LAYERS: 0x2A, UNISON_DETUNE: 0x2B, UNISON_MIX: 0x2C,
    PWM_WIDTH: 0x2D, PWM_RATE: 0x2E, PWM_DEPTH: 0x2F,
    ECHO_ON: 0x50, ECHO_TIME: 0x51, ECHO_FB: 0x52, ECHO_MIX: 0x53,
    REV_ON: 0x54, REV_SIZE: 0x55, REV_DAMP: 0x56, REV_MIX: 0x57,
    CHO_ON: 0x58, CHO_RATE: 0x59, CHO_DEPTH: 0x5A, CHO_MIX: 0x5B,
    PHA_ON: 0x5C, PHA_RATE: 0x5D, PHA_DEPTH: 0x5E, PHA_FB: 0x5F, PHA_MIX: 0x60,
    DRV_ON: 0x61, DRV_DRIVE: 0x62, DRV_TONE: 0x63, DRV_MIX: 0x64,
    LIM_ON: 0x65, LIM_TH: 0x66, LIM_CEIL: 0x67, LIM_REL: 0x68,
    EQ_ON: 0x69, EQ_LOW: 0x6A, EQ_LMID: 0x6B, EQ_MID: 0x6C,
    EQ_HMID: 0x6D, EQ_HIGH: 0x6E, EQ_OUT: 0x6F,
    CHA0: 0x80, CHB0: 0xA0,
  };
  for (const k of Object.keys(expected)) assert.strictEqual(app.R[k], expected[k], k);
  for (const r of [app.R.OCTAVE, app.R.SUSTAIN, app.R.UNISON_ON, app.R.UNISON_MIX,
                   app.R.PWM_WIDTH, app.R.PWM_DEPTH,
                   app.R.ECHO_ON, app.R.EQ_OUT, app.R.CHA0, app.R.CHA0 + 31, app.R.CHB0 + 31]) {
    assert.ok(app.WRITABLE_REGS.includes(r), 'WRITABLE_REGS 缺少 ' + r);
  }
  assert.strictEqual(new Set(app.WRITABLE_REGS).size, app.WRITABLE_REGS.length);
  assert.ok(app.WRITABLE_REGS.length > 120, '寄存器数量 ' + app.WRITABLE_REGS.length);
});

test('32 声道 A/B 寄存器打包 / 拆包', () => {
  const a = app.packChA(128, 0);
  assert.strictEqual(a, 0x0080);
  assert.deepStrictEqual(app.unpackChA(a), { vol: 128, dist: 0 });
  const b = app.packChB(15, 14, 13, 12);   // echo / reverb / chorus / phaser
  assert.strictEqual(b, 0xCDEF);
  assert.deepStrictEqual(app.unpackChB(b), { echo: 15, reverb: 14, chorus: 13, phaser: 12 });
  assert.strictEqual(app.packChA(0, 127), 0x7F00);
  assert.strictEqual(app.packChB(0, 0, 0, 0), 0);
});

test('效果参数显示换算：回声 / 合唱 / 相位 / 限幅 / EQ', () => {
  assert.ok(Math.abs(app.echoMs(0) - (512 / app.SAMPLE_RATE * 1000)) < 1e-9);
  assert.ok(Math.abs(app.echoMs(255) - (15812 / app.SAMPLE_RATE * 1000)) < 1e-9);
  assert.ok(app.chorusHz(0) > 0.09 && app.chorusHz(0) < 0.10);
  assert.ok(app.chorusHz(127) > 5.9 && app.chorusHz(127) < 6.1);
  assert.ok(app.phaserHz(0) > 0.04 && app.phaserHz(0) < 0.05);
  assert.ok(app.phaserHz(127) > 2.9 && app.phaserHz(127) < 3.1);
  assert.ok(app.limiterDb(255, false) < 0 && app.limiterDb(255, false) > -0.2);
  assert.ok(app.limiterDb(0, false) < -17 && app.limiterDb(0, false) > -19);
  assert.strictEqual(app.eqDbToCode(0), 16);
  assert.ok(Math.abs(app.eqCodeToDb(16)) < 1e-9);
  assert.strictEqual(app.eqDbToCode(12), 63);   // +12dB 上限
  assert.strictEqual(app.eqDbToCode(-100), 1);  // 下限
});

test('32 声部齐奏：默认 4 层 / 32 个振荡器', () => {
  assert.strictEqual(app.FACTORY_FX.uniOn, 1);
  assert.strictEqual(app.FACTORY_FX.uniLayers, 4);
  assert.strictEqual(app.FACTORY_FX.uniLayers * 8, 32);
  assert.ok(app.FACTORY_FX.uniDetune >= 0 && app.FACTORY_FX.uniDetune <= 127);
  assert.ok(app.FACTORY_FX.uniMix >= 0 && app.FACTORY_FX.uniMix <= 127);
  for (const r of [app.R.UNISON_ON, app.R.UNISON_LAYERS, app.R.UNISON_DETUNE, app.R.UNISON_MIX]) {
    assert.ok(app.WRITABLE_REGS.includes(r));
  }
});

test('声部数换算：按键数 × 齐奏层数（封顶 32）', () => {
  assert.strictEqual(app.popcount8(0x00), 0);
  assert.strictEqual(app.popcount8(0xFF), 8);
  assert.strictEqual(app.popcount8(0b1010_0101), 4);
  const voices = (keys, layers) => Math.min(32, keys * layers);
  assert.strictEqual(voices(8, 4), 32);
  assert.strictEqual(voices(1, 4), 4);
  assert.strictEqual(voices(8, 1), 8);
});

test('遥测 TIMBRE 是 4 位：8/9 不能被截成 0/1', () => {
  const p = new Array(16).fill(0);
  p[0] = 8;
  assert.strictEqual(app.decodeTelemetry(p).timbre, 8);
  p[0] = 9;
  assert.strictEqual(app.decodeTelemetry(p).timbre, 9);
  p[0] = 15;
  assert.strictEqual(app.decodeTelemetry(p).timbre, 15);
});

test('自定义音色档存在（网页端伪音色，不写 TIMBRE）', () => {
  assert.strictEqual(app.TIMBRES.length, 11);
  const c = app.TIMBRES.find((t) => t.id === 10);
  assert.ok(c && c.name === '自定义');
  assert.ok(app.FACTORY_PRESETS[10]);
});

test('PWM 默认值/寄存器：方波专用', () => {
  assert.strictEqual(app.FACTORY_FX.pwmWidth, 128);
  assert.strictEqual(app.FACTORY_FX.pwmRate, 30);
  assert.strictEqual(app.FACTORY_FX.pwmDepth, 96);
  for (const r of [app.R.PWM_WIDTH, app.R.PWM_RATE, app.R.PWM_DEPTH]) {
    assert.ok(app.WRITABLE_REGS.includes(r));
  }
});

test('琴类延音默认：钢琴/古筝/木琴关，颠琴/钟琴开', () => {
  // 钢琴/古筝/木琴：切过去 -> 0
  assert.strictEqual(app.defaultSustainOnTimbre(1, true, 80, false), 0);
  // 同一个音色内手动拉起 -> 保持
  assert.strictEqual(app.defaultSustainOnTimbre(1, false, 80, false), 80);
  // 颠琴/钟琴：切过去时 0 -> 默认 40；已有值保留
  assert.strictEqual(app.defaultSustainOnTimbre(1, true, 0, true), 40);
  assert.strictEqual(app.defaultSustainOnTimbre(1, true, 80, true), 80);
  assert.strictEqual(app.defaultSustainOnTimbre(1, false, 0, true), 40);
  // 持续音 -> 0
  assert.strictEqual(app.defaultSustainOnTimbre(0, false, 40, false), 0);
  assert.strictEqual(app.defaultSustainOnTimbre(0, true, 40, true), 0);
});

test('延音踏板：默认值 / 时间换算 / 只慢不快', () => {
  assert.strictEqual(app.FACTORY_PERF.sustain, 40);
  assert.ok(app.WRITABLE_REGS.includes(app.R.SUSTAIN));
  // 0 = 关闭
  assert.strictEqual(app.pedalReleaseTime(0, 3, 4096), 0);
  // 钢琴（rate=3, rel=4096）：step = 32-10=22 -> 4 倍慢速 + 50% 保持，约 0.98s
  const piano = app.pedalReleaseTime(40, 3, 4096);
  assert.ok(piano > 0.9 && piano < 1.1, 'piano pedal=' + piano);
  // 释音慢化后必须比原释音长（原钢琴是瞬断）
  const saw = app.pedalReleaseTime(40, 0, 4);
  assert.ok(saw > 0.5, 'saw=' + saw);
  // 拉满时钢琴尾音约 21s
  assert.ok(app.pedalReleaseTime(127, 3, 4096) > 20);
});

test('八度 / 声道帧能走 16 项一帧的协议', () => {
  const pairs = [
    { reg: app.R.OCTAVE, val: -2 },            // 16 位补码 0xFFFE
    { reg: app.R.ECHO_ON, val: 1 },
    { reg: app.R.ECHO_TIME, val: 200 },
    { reg: app.R.CHA0, val: app.packChA(100, 20) },
    { reg: app.R.CHB0, val: app.packChB(1, 2, 3, 4) },
    { reg: app.R.CHB0 + 31, val: app.packChB(15, 15, 15, 15) },
  ];
  const regs = new Map();
  const p = new app.FrameParser((t, pl) => {
    if (t !== app.T.SET) return;
    for (let i = 0; i + 2 < pl.length; i += 3) {
      regs.set(pl[i], pl[i + 1] | (pl[i + 2] << 8));
    }
  });
  p.feed(app.encodeSet(pairs));
  assert.strictEqual(regs.get(app.R.OCTAVE), 0xFFFE);
  assert.strictEqual(regs.get(app.R.ECHO_ON), 1);
  assert.strictEqual(regs.get(app.R.ECHO_TIME), 200);
  assert.strictEqual(regs.get(app.R.CHA0), 0x1464);
  assert.strictEqual(regs.get(app.R.CHB0), 0x4321);
  assert.strictEqual(regs.get(app.R.CHB0 + 31), 0xFFFF);
});

console.log('\n通过 ' + passed + ' 项' + (process.exitCode ? '，有失败！' : '，全部通过 ✅'));
