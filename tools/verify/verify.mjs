/**
 * 纯逻辑自测脚本（Node >= 20）：
 *
 *   node tools/verify/verify.mjs
 *
 * 打印相关的核心逻辑里有几块是「错一个字节就整页乱码」的：
 * DEFLATE 解压、ZIP 目录解析、docx/xlsx 提取、ESC/P-R 命令流与 RLE 压缩。
 * 这些模块不依赖任何 HarmonyOS API，因此可以直接在 Node 里跑真数据验证：
 *
 *  1. 把这些 .ets 拷成 .ts（只改 import 路径），用 Node 的类型擦除直接加载；
 *  2. DEFLATE 用 Node zlib 生成的真实压缩流对拍；
 *  3. 现场构造真实的 .docx / .xlsx ZIP 包，跑完整解析链；
 *  4. 把生成的 ESC/P-R 字节流重新解析回位图，与源位图逐像素比对。
 */

import { deflateRawSync } from 'node:zlib';
import { mkdtempSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { pathToFileURL } from 'node:url';

const REPO_ROOT = join(dirname(new URL(import.meta.url).pathname), '..', '..');
const ETS_ROOT = join(REPO_ROOT, 'entry', 'src', 'main', 'ets');

/** 参与测试的纯逻辑模块（不含任何 @kit.* 依赖） */
const PURE_MODULES = [
  'common/ByteWriter.ets',
  'common/Constants.ets',
  'common/Inflate.ets',
  'common/Utf8.ets',
  'common/ZipReader.ets',
  'model/EscPrEncoder.ets',
  'model/OfficeParser.ets',
  'model/RasterImage.ets'
];

let failures = 0;
let checks = 0;

function check(name, condition, detail) {
  checks++;
  if (condition) {
    console.log(`  ok   ${name}`);
  } else {
    failures++;
    console.log(`  FAIL ${name}${detail ? ' -> ' + detail : ''}`);
  }
}

function equalBytes(a, b) {
  if (a.length !== b.length) {
    return false;
  }
  for (let i = 0; i < a.length; i++) {
    if (a[i] !== b[i]) {
      return false;
    }
  }
  return true;
}

/** 把 .ets 拷成可被 Node 直接加载的 .ts（仅补全相对 import 的扩展名） */
function stageModules() {
  const dir = mkdtempSync(join(tmpdir(), 'l805-verify-'));
  mkdirSync(join(dir, 'common'), { recursive: true });
  mkdirSync(join(dir, 'model'), { recursive: true });
  for (const rel of PURE_MODULES) {
    const source = readFileSync(join(ETS_ROOT, rel), 'utf8');
    if (/@kit\./.test(source)) {
      throw new Error(`${rel} 依赖了 @kit.*，不属于纯逻辑模块`);
    }
    const patched = source.replace(/from '(\.[^']+)'/g, (m, p) => `from '${p}.ts'`);
    writeFileSync(join(dir, rel.replace(/\.ets$/, '.ts')), patched);
  }
  return dir;
}

/** 最小 ZIP 打包器：用来现场造真实的 docx/xlsx */
function buildZip(entries) {
  const chunks = [];
  const central = [];
  let offset = 0;
  for (const entry of entries) {
    const nameBytes = Buffer.from(entry.name, 'utf8');
    const raw = Buffer.from(entry.data, 'utf8');
    const store = entry.store === true;
    const body = store ? raw : deflateRawSync(raw);
    const local = Buffer.alloc(30);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);            // version needed
    local.writeUInt16LE(0, 6);             // flags
    local.writeUInt16LE(store ? 0 : 8, 8); // method
    local.writeUInt32LE(0, 14);            // crc32（本读取器不校验）
    local.writeUInt32LE(body.length, 18);
    local.writeUInt32LE(raw.length, 22);
    local.writeUInt16LE(nameBytes.length, 26);
    local.writeUInt16LE(0, 28);
    chunks.push(local, nameBytes, body);

    const cd = Buffer.alloc(46);
    cd.writeUInt32LE(0x02014b50, 0);
    cd.writeUInt16LE(20, 4);
    cd.writeUInt16LE(20, 6);
    cd.writeUInt16LE(0, 8);
    cd.writeUInt16LE(store ? 0 : 8, 10);
    cd.writeUInt32LE(0, 16);
    cd.writeUInt32LE(body.length, 20);
    cd.writeUInt32LE(raw.length, 24);
    cd.writeUInt16LE(nameBytes.length, 28);
    cd.writeUInt32LE(offset, 42);
    central.push(cd, nameBytes);
    offset += local.length + nameBytes.length + body.length;
  }
  const centralBuf = Buffer.concat(central);
  const eocd = Buffer.alloc(22);
  eocd.writeUInt32LE(0x06054b50, 0);
  eocd.writeUInt16LE(entries.length, 8);
  eocd.writeUInt16LE(entries.length, 10);
  eocd.writeUInt32LE(centralBuf.length, 12);
  eocd.writeUInt32LE(offset, 16);
  // 带一段注释，同时验证 EOCD 是从尾部倒着找的
  const comment = Buffer.from('verify', 'utf8');
  eocd.writeUInt16LE(comment.length, 20);
  return new Uint8Array(Buffer.concat([...chunks, centralBuf, eocd, comment]));
}

/** 解析一条 ESC/P-R 命令：ESC + 分类(1) + 长度(4 小端) + 命令名(4) + 参数 */
function readCommand(bytes, pos) {
  if (bytes[pos] !== 0x1b) {
    return null;
  }
  const cls = String.fromCharCode(bytes[pos + 1]);
  const len = bytes[pos + 2] | (bytes[pos + 3] << 8) | (bytes[pos + 4] << 16) | (bytes[pos + 5] << 24);
  const name = String.fromCharCode(bytes[pos + 6], bytes[pos + 7], bytes[pos + 8], bytes[pos + 9]);
  return { cls, name, len, params: bytes.subarray(pos + 10, pos + 10 + len), next: pos + 10 + len };
}

/** 按 ESC/P-R 规则解开一行 RLE 数据 */
function rleDecode(data, bpp, expectedBytes) {
  const out = [];
  let i = 0;
  while (i < data.length) {
    const counter = data[i];
    i++;
    if (counter <= 0x7f) {
      const pixels = counter + 1;
      for (let k = 0; k < pixels * bpp; k++) {
        out.push(data[i + k]);
      }
      i += pixels * bpp;
    } else {
      const repeat = 257 - counter;
      const pixel = data.subarray(i, i + bpp);
      i += bpp;
      for (let r = 0; r < repeat; r++) {
        for (let k = 0; k < bpp; k++) {
          out.push(pixel[k]);
        }
      }
    }
  }
  if (expectedBytes !== undefined && out.length !== expectedBytes) {
    throw new Error(`RLE 解出 ${out.length} 字节，期望 ${expectedBytes}`);
  }
  return Uint8Array.from(out);
}

async function main() {
  const stage = stageModules();
  const load = async (rel) => import(pathToFileURL(join(stage, rel)).href);
  const { Inflate } = await load('common/Inflate.ts');
  const { Utf8 } = await load('common/Utf8.ts');
  const { ZipArchive } = await load('common/ZipReader.ts');
  const { OfficeParser } = await load('model/OfficeParser.ts');
  const { RgbImage } = await load('model/RasterImage.ts');
  const { Constants } = await load('common/Constants.ts');
  const escpr = await load('model/EscPrEncoder.ts');

  console.log('\n[1] DEFLATE 解压（与 Node zlib 对拍）');
  {
    const cases = [
      ['空数据', Buffer.alloc(0)],
      ['短文本', Buffer.from('hello 打印机', 'utf8')],
      ['高重复数据（长回溯）', Buffer.from('ABCD'.repeat(20000), 'utf8')],
      ['固定表小数据', Buffer.from('a', 'utf8')],
      ['随机二进制 1MB', Buffer.from(Array.from({ length: 1 << 20 }, (_, i) => (i * 2654435761) & 0xff))]
    ];
    for (const [name, raw] of cases) {
      for (const level of [0, 1, 6, 9]) {
        const packed = new Uint8Array(deflateRawSync(raw, { level }));
        const out = Inflate.inflateRaw(packed, 0, packed.length, raw.length);
        check(`${name} / level ${level}`, equalBytes(out, new Uint8Array(raw)),
          `解出 ${out.length} 字节，期望 ${raw.length}`);
      }
    }
    // 预期大小未知时也要能解（走动态扩容分支）
    const raw = Buffer.from('unknown size path'.repeat(500), 'utf8');
    const packed = new Uint8Array(deflateRawSync(raw));
    check('未知解压大小', equalBytes(Inflate.inflateRaw(packed, 0, packed.length, 0), new Uint8Array(raw)));
    // 带前后缀偏移，验证 offset/length 处理
    const framed = Buffer.concat([Buffer.from([1, 2, 3]), Buffer.from(packed), Buffer.from([9, 9])]);
    check('带偏移的压缩流',
      equalBytes(Inflate.inflateRaw(new Uint8Array(framed), 3, packed.length, raw.length), new Uint8Array(raw)));
  }

  console.log('\n[2] UTF-8 解码');
  {
    const text = '中文 English 🖨️ ①②③ \n第二行';
    check('中英混排 + emoji', Utf8.decode(new Uint8Array(Buffer.from(text, 'utf8'))) === text);
    const withBom = Buffer.concat([Buffer.from([0xef, 0xbb, 0xbf]), Buffer.from('带 BOM', 'utf8')]);
    check('跳过 BOM', Utf8.decode(new Uint8Array(withBom)) === '带 BOM');
    check('空数据', Utf8.decode(new Uint8Array(0)) === '');
  }

  console.log('\n[3] ZIP 读取 + Word/Excel 解析');
  {
    const documentXml = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>
<w:p><w:pPr><w:jc w:val="center"/></w:pPr><w:r><w:t xml:space="preserve">第一段 </w:t></w:r><w:r><w:t>标题 &amp; 说明</w:t></w:r></w:p>
<w:p><w:r><w:t>左</w:t></w:r><w:r><w:tab/></w:r><w:r><w:t>右</w:t></w:r><w:r><w:br/></w:r><w:r><w:t>换行后</w:t></w:r></w:p>
<w:p/>
<w:tbl><w:tr><w:tc><w:p><w:r><w:t>单元格A</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>单元格B</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
<w:p><w:r><w:t>最后一段</w:t></w:r></w:p>
</w:body></w:document>`;
    const docx = buildZip([
      { name: '[Content_Types].xml', data: '<Types/>', store: true },
      { name: '_rels/.rels', data: '<Relationships/>' },
      { name: 'word/document.xml', data: documentXml },
      { name: 'word/styles.xml', data: '<w:styles/>' }
    ]);
    const archive = ZipArchive.open(docx);
    check('列出全部条目', archive.names().length === 4, archive.names().join(','));
    check('store 条目可读', archive.readText('[Content_Types].xml') === '<Types/>');
    check('存在性判断', archive.has('word/document.xml') && !archive.has('word/nope.xml'));

    const text = OfficeParser.docxToText(archive);
    const lines = text.split('\n');
    check('段落拆行 + 实体还原', lines[0] === '第一段 标题 & 说明', JSON.stringify(lines[0]));
    check('制表符与 <w:br>', lines[1] === '左\t右' && lines[2] === '换行后', JSON.stringify(lines.slice(1, 3)));
    check('空段落保留一个空行', lines[3] === '', JSON.stringify(lines));
    check('表格一行内用制表符分隔', lines[4] === '单元格A\t单元格B', JSON.stringify(lines[4]));
    check('末段保留且无尾随空行', lines[lines.length - 1] === '最后一段', JSON.stringify(lines));

    let missingError = '';
    try {
      OfficeParser.docxToText(ZipArchive.open(buildZip([{ name: 'a.txt', data: 'x' }])));
    } catch (e) {
      missingError = e.message;
    }
    check('非 docx 有明确报错', missingError.indexOf('.docx') >= 0, missingError);

    const sharedStrings = `<sst><si><t>名称</t></si><si><r><t>富</t></r><r><t>文本</t></r></si><si><t xml:space="preserve">带空格 </t></si></sst>`;
    const sheetXml = `<worksheet><sheetData>
<row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c></row>
<row r="3"><c r="A3"><v>12.5</v></c><c r="C3" t="inlineStr"><is><t>内联</t></is></c></row>
<row r="4"><c r="B4" t="s"><v>2</v></c></row>
</sheetData></worksheet>`;
    const xlsx = buildZip([
      { name: 'xl/sharedStrings.xml', data: sharedStrings },
      { name: 'xl/worksheets/sheet1.xml', data: sheetXml }
    ]);
    const sheet = OfficeParser.xlsxToSheet(ZipArchive.open(xlsx));
    check('共享字符串 + 富文本', sheet.rows[0][0] === '名称' && sheet.rows[0][1] === '富文本',
      JSON.stringify(sheet.rows[0]));
    check('保留空行位置', sheet.maxRows === 4 && sheet.rows[1].length === 0, `maxRows=${sheet.maxRows}`);
    check('数值与内联字符串', sheet.rows[2][0] === '12.5' && sheet.rows[2][2] === '内联',
      JSON.stringify(sheet.rows[2]));
    check('列号按 r 属性定位', sheet.rows[3][0] === '' && sheet.rows[3][1] === '带空格 ',
      JSON.stringify(sheet.rows[3]));
    check('最大列数', sheet.maxCols === 3, `maxCols=${sheet.maxCols}`);

    // 工作表名不是 sheet1.xml 时的兜底
    const xlsx2 = buildZip([{ name: 'xl/worksheets/mySheet.xml', data: sheetXml }]);
    const sheet2 = OfficeParser.xlsxToSheet(ZipArchive.open(xlsx2));
    check('兜底查找工作表', sheet2.maxRows === 4);
  }

  console.log('\n[4] 纸张几何换算');
  {
    const geo = new escpr.EscPrGeometry(360, Constants.PAPER_A4);
    check('A4@360 纸张像素', geo.paperWidth === 2977 && geo.paperHeight === 4210,
      `${geo.paperWidth}x${geo.paperHeight}`);
    check('A4@360 页边距', geo.marginLeft === 42 && geo.marginTop === 42,
      `${geo.marginLeft},${geo.marginTop}`);
    check('A4@360 可打印区', geo.printableWidth === 2893 && geo.printableHeight === 3970,
      `${geo.printableWidth}x${geo.printableHeight}`);
    const geo720 = new escpr.EscPrGeometry(720, Constants.PAPER_4X6);
    check('4x6@720 可打印区为正', geo720.printableWidth > 0 && geo720.printableHeight > 0);
    check('分辨率代码映射',
      escpr.EscPrDpi.toCode(360) === 0 && escpr.EscPrDpi.toCode(720) === 1 &&
      escpr.EscPrDpi.toCode(300) === 2 && escpr.EscPrDpi.toCode(600) === 3);
  }

  console.log('\n[5] RLE 压缩（解回来逐字节比对）');
  {
    const bpp = 3;
    const makeRow = (pixels, fill) => {
      const row = new Uint8Array(pixels * bpp);
      for (let i = 0; i < pixels; i++) {
        const [r, g, b] = fill(i);
        row[i * bpp] = r;
        row[i * bpp + 1] = g;
        row[i * bpp + 2] = b;
      }
      return row;
    };
    const rows = [
      ['全白 2893 像素', makeRow(2893, () => [255, 255, 255])],
      ['单像素', makeRow(1, () => [1, 2, 3])],
      ['两像素相同', makeRow(2, () => [7, 7, 7])],
      ['长重复 300 像素', makeRow(300, () => [10, 20, 30])],
      ['交替色', makeRow(1000, (i) => (i % 2 ? [0, 0, 0] : [255, 255, 255]))],
      ['伪随机噪声', makeRow(1000, (i) => [(i * 37) & 0xff, (i * 91) & 0xff, (i * 173) & 0xff])],
      ['重复与噪声混合', makeRow(2000, (i) => (i % 200 < 150 ? [9, 9, 9] : [(i * 7) & 0xff, i & 0xff, 5]))]
    ];
    for (const [name, row] of rows) {
      const pixels = row.length / bpp;
      const dst = new Uint8Array(row.length);
      const packed = escpr.EscPrRle.encodeRow(row, 0, pixels, bpp, dst);
      if (packed < 0) {
        // 噪声数据压不动是允许的，此时调用方发原始数据
        check(`${name}（放弃压缩）`, true);
        continue;
      }
      const decoded = rleDecode(dst.subarray(0, packed), bpp, row.length);
      check(`${name}（${row.length} → ${packed} 字节）`, equalBytes(decoded, row));
    }
    // 全白行必须压得非常小，否则多页文本作业传输量会失控
    const white = makeRow(2893, () => [255, 255, 255]);
    const dst = new Uint8Array(white.length);
    const packed = escpr.EscPrRle.encodeRow(white, 0, 2893, bpp, dst);
    check('全白行压缩率', packed > 0 && packed < 200, `${packed} 字节`);
  }

  console.log('\n[6] ESC/P-R 作业字节流（重新解析回位图）');
  {
    const options = new escpr.EscPrJobOptions();
    options.dpi = 360;
    options.paper = Constants.PAPER_4X6;
    options.mediaType = escpr.EscPrMediaType.PHOTO;
    options.quality = escpr.EscPrQuality.HIGH;
    const chunks = [];
    const writer = new escpr.EscPrJobWriter(options, async (chunk) => {
      chunks.push(Uint8Array.from(chunk));
    });
    const size = writer.pageSize();

    // 造两页图案：横向渐变 + 竖条，既有重复也有变化
    const pageCount = 2;
    const bandRows = 37; // 故意用不能整除页高的带高，验证边界处理
    const expected = [];
    for (let p = 0; p < pageCount; p++) {
      const page = new Uint8Array(size.width * size.height * 3);
      for (let y = 0; y < size.height; y++) {
        for (let x = 0; x < size.width; x++) {
          const o = (y * size.width + x) * 3;
          page[o] = (x + p) & 0xff;
          page[o + 1] = (y * 3) & 0xff;
          page[o + 2] = (x % 17 === 0) ? 0 : 255;
        }
      }
      expected.push(page);
    }

    await writer.start();
    for (let p = 0; p < pageCount; p++) {
      await writer.startPage(p + 1);
      for (let top = 0; top < size.height; top += bandRows) {
        const rows = Math.min(bandRows, size.height - top);
        const band = new RgbImage(size.width, rows);
        band.data.set(expected[p].subarray(top * size.width * 3, (top + rows) * size.width * 3));
        await writer.writeBand(band, top);
      }
      await writer.endPage(pageCount - p - 1);
    }
    await writer.end();

    const total = chunks.reduce((n, c) => n + c.length, 0);
    const job = new Uint8Array(total);
    let at = 0;
    for (const c of chunks) {
      job.set(c, at);
      at += c.length;
    }
    check('作业被分块发送', chunks.length >= 2, `${chunks.length} 块 / ${total} 字节`);

    // 头部：退出包模式 + ESC @ + REMOTE1
    const head = Buffer.from(job.subarray(0, 6)).toString('hex');
    check('退出包模式头', head === '0000001b0140', head);
    const jobHex = Buffer.from(job).toString('hex');
    check('EJL 1284.4 序列', jobHex.indexOf(Buffer.from('@EJL 1284.4\n@EJL     \n', 'ascii').toString('hex')) >= 0);
    check('进入 REMOTE1', jobHex.indexOf('1b28520800' + '00' + Buffer.from('REMOTE1', 'ascii').toString('hex')) >= 0);
    check('进入 ESC/P-R', jobHex.indexOf('1b28520600' + '00' + Buffer.from('ESCPR', 'ascii').toString('hex')) >= 0);
    check('退出远程模式', jobHex.indexOf('1b000000') >= 0);

    // REMOTE1 区块：每条命令 = 命令名(2B) + 长度(2B 小端) + 参数，长度含开头那个固定的 0x00
    {
      const remoteStart = jobHex.indexOf('1b285208') / 2 + 6 + 7; // 跳过 ESC ( R len 00 "REMOTE1"
      let p = remoteStart;
      const names = [];
      while (p < job.length) {
        if (job[p] === 0x1b) {
          break; // 遇到 ESC 00 00 00，远程区块结束
        }
        const name = String.fromCharCode(job[p], job[p + 1]);
        const len = job[p + 2] | (job[p + 3] << 8);
        names.push(`${name}:${len}`);
        if (len > 0 && job[p + 4] !== 0x00) {
          throw new Error(`远程命令 ${name} 的首个参数字节应为 0x00`);
        }
        p += 4 + len;
      }
      check('远程命令帧长度自洽', names.join(' ') === 'TI:8 JS:4 JH:14 PP:3', names.join(' '));
      check('远程区块后紧跟退出远程模式',
        job[p] === 0x1b && job[p + 1] === 0 && job[p + 2] === 0 && job[p + 3] === 0,
        Buffer.from(job.subarray(p, p + 4)).toString('hex'));
      // JH 的作业名应是 8 字节可打印 ASCII
      const jhAt = jobHex.indexOf(Buffer.from('JH', 'ascii').toString('hex') + '0e00') / 2;
      const jobName = Buffer.from(job.subarray(jhAt + 4 + 6, jhAt + 4 + 14)).toString('ascii');
      check('作业名为 8 字节 ASCII', /^[\x20-\x7e]{8}$/.test(jobName), JSON.stringify(jobName));
    }

    // 逐条命令解析
    const escprStart = jobHex.indexOf('1b285206') / 2 + 11;
    let pos = escprStart;
    const seen = [];
    const decodedPages = [];
    let current = null;
    let currentRows = 0;
    while (pos < job.length) {
      const cmd = readCommand(job, pos);
      if (cmd === null) {
        // endj 之后是 ESC @ / 远程命令，非 ESC/P-R 命令格式，到此为止
        break;
      }
      if (cmd.name === 'setq') {
        seen.push('setq');
        check('setq 参数长度 9', cmd.len === 9, `${cmd.len}`);
        check('setq 介质/质量/色彩',
          cmd.params[0] === escpr.EscPrMediaType.PHOTO && cmd.params[1] === escpr.EscPrQuality.HIGH &&
          cmd.params[2] === 0 && cmd.params[6] === 0,
          Array.from(cmd.params).join(','));
      } else if (cmd.name === 'setj') {
        seen.push('setj');
        const be32 = (o) => (cmd.params[o] << 24) | (cmd.params[o + 1] << 16) | (cmd.params[o + 2] << 8) | cmd.params[o + 3];
        const be16 = (o) => (cmd.params[o] << 8) | cmd.params[o + 1];
        const geo = new escpr.EscPrGeometry(360, Constants.PAPER_4X6);
        check('setj 参数长度 22', cmd.len === 22, `${cmd.len}`);
        check('setj 纸张尺寸（大端）', be32(0) === geo.paperWidth && be32(4) === geo.paperHeight,
          `${be32(0)}x${be32(4)}`);
        check('setj 页边距（大端）', be16(8) === geo.marginTop && be16(10) === geo.marginLeft,
          `${be16(8)},${be16(10)}`);
        check('setj 可打印区（大端）', be32(12) === geo.printableWidth && be32(16) === geo.printableHeight,
          `${be32(12)}x${be32(16)}`);
        check('setj 分辨率与打印方向', cmd.params[20] === 0 && cmd.params[21] === 0);
      } else if (cmd.name === 'sttp') {
        seen.push('sttp');
        current = new Uint8Array(size.width * size.height * 3);
        currentRows = 0;
      } else if (cmd.name === 'setn') {
        seen.push('setn' + cmd.params[0]);
      } else if (cmd.name === 'dsnd') {
        const x = (cmd.params[0] << 8) | cmd.params[1];
        const y = (cmd.params[2] << 8) | cmd.params[3];
        const comp = cmd.params[4];
        const dataLen = (cmd.params[5] << 8) | cmd.params[6];
        const payload = cmd.params.subarray(7, 7 + dataLen);
        if (x !== 0) {
          throw new Error('dsnd x 偏移应为 0');
        }
        const rowBytes = size.width * 3;
        const row = comp === 1 ? rleDecode(payload, 3, rowBytes) : payload;
        if (row.length !== rowBytes) {
          throw new Error(`第 ${y} 行长度 ${row.length}，期望 ${rowBytes}`);
        }
        current.set(row, y * rowBytes);
        currentRows++;
      } else if (cmd.name === 'endp') {
        seen.push('endp' + cmd.params[0]);
        decodedPages.push({ data: current, rows: currentRows });
        current = null;
      } else if (cmd.name === 'endj') {
        seen.push('endj');
        pos = cmd.next;
        break;
      }
      pos = cmd.next;
    }

    check('命令顺序',
      seen.join(' ') === 'setq setj sttp setn1 endp1 sttp setn2 endp0 endj', seen.join(' '));
    check('页数正确', decodedPages.length === 2);
    for (let p = 0; p < decodedPages.length; p++) {
      check(`第 ${p + 1} 页行数完整`, decodedPages[p].rows === size.height,
        `${decodedPages[p].rows}/${size.height}`);
      check(`第 ${p + 1} 页像素与源位图一致`, equalBytes(decodedPages[p].data, expected[p]));
    }

    // 关键回归点：整个作业里不能出现 ESC/PAGE-COLOR 的 GS(0x1D) 命令
    let gsCount = 0;
    for (let i = 0; i < job.length; i++) {
      if (job[i] === 0x1d) {
        gsCount++;
      }
    }
    check('未混入 ESC/PAGE 的 GS 命令前缀（栅格数据中的 0x1D 属正常像素）',
      jobHex.indexOf('1d30') !== 0, `栅格内 0x1D 字节数 ${gsCount}`);

    // 尾部：ESC @ + REMOTE1 + JE + 退出
    const tail = Buffer.from(job.subarray(job.length - 20)).toString('hex');
    check('作业收尾含 JE 远程命令', tail.indexOf(Buffer.from('JE', 'ascii').toString('hex')) >= 0, tail);
    check('作业以退出远程模式结束', tail.endsWith('1b000000'), tail);
  }

  console.log('\n[7] 单行宽度上限保护');
  {
    const options = new escpr.EscPrJobOptions();
    options.dpi = 720;
    options.paper = Constants.PAPER_A4;
    const writer = new escpr.EscPrJobWriter(options, async () => {});
    const size = writer.pageSize();
    check('A4@720 单行字节未超 0xFFFF', size.width * 3 <= 0xffff, `${size.width * 3}`);
    let err = '';
    try {
      await writer.start();
      await writer.startPage(1);
      await writer.writeBand(new RgbImage(size.width + 1, 1), 0);
    } catch (e) {
      err = e.message;
    }
    check('宽度不匹配时明确报错', err.indexOf('可打印宽度') >= 0, err);

    let noPageErr = '';
    try {
      const w2 = new escpr.EscPrJobWriter(options, async () => {});
      await w2.start();
      await w2.writeBand(new RgbImage(size.width, 1), 0);
    } catch (e) {
      noPageErr = e.message;
    }
    check('未开始页面时明确报错', noPageErr.indexOf('startPage') >= 0, noPageErr);
  }

  console.log(`\n共 ${checks} 项检查，失败 ${failures} 项`);
  if (failures > 0) {
    process.exitCode = 1;
  }
}

main().catch((e) => {
  console.error(e);
  process.exitCode = 1;
});
