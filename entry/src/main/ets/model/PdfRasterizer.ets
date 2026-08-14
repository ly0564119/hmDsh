/**
 * PDF 页面渲染：使用 HarmonyOS 6.0（API 14+）的 PDF Kit（@kit.PDFKit → pdfService）
 * 把 PDF 各页转成图片，再交给打印管线。
 *
 * 注意：此模块依赖 PDF Kit，需兼容 SDK 版本 >= 6.0.0(14)。
 * 具体方法名（loadDocument / savePageAsImage / getPageCount）请在 DevEco
 * 的 API 参考里按自动补全核对一次。
 */

import { pdfService } from '@kit.PDFKit';
import { RgbImage } from './RasterImage';
import { DocumentRasterizer } from './DocumentRasterizer';

export class PdfRasterizer {

  static async renderPdf(uri: string, cacheDir: string, maxW: number, maxH: number): Promise<RgbImage[]> {
    const doc = new pdfService.PdfDocument();
    const loadResult = doc.loadDocument(uri);
    if (loadResult !== pdfService.ParseResult.PARSE_SUCCESS) {
      throw new Error('无法打开 PDF 文件');
    }
    const pageCount = doc.getPageCount();
    const pages: RgbImage[] = [];
    for (let i = 0; i < pageCount; i++) {
      const outPath = cacheDir + '/pdf_page_' + i + '.png';
      doc.savePageAsImage(i, outPath, {
        format: 'png',
        width: maxW,
        height: maxH
      });
      const img = await DocumentRasterizer.loadImageToRgb(outPath, maxW, maxH);
      pages.push(img);
    }
    return pages;
  }
}
