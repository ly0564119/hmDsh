/**
 * ZIP 解包（用于 .docx / .xlsx），基于系统 zlib 的 decompressFile。
 * 注意：本 SDK 的 @ohos.zlib 没有内存解压接口，需先把 zip 拷到沙箱再解压到目录。
 */

import { zlib } from '@kit.BasicServicesKit';
import { fileIo as fs } from '@kit.CoreFileKit';

export class ZipReader {
  /** 把 picker 返回的 uri 拷贝为沙箱内文件 */
  static copyUriToFile(uri: string, destPath: string): void {
    fs.copyFileSync(uri, destPath);
  }

  /** 把 zip 解压到目录（目录不存在会自动创建） */
  static async extractToDir(zipPath: string, outDir: string): Promise<void> {
    fs.mkdirSync(outDir, true);
    await zlib.decompressFile(zipPath, outDir);
  }

  /** 读取解压后目录里的某个文件文本 */
  static readTextFile(path: string): string {
    return fs.readTextSync(path);
  }

  /** 删除临时 zip 文件（尽力而为） */
  static cleanupFile(path: string): void {
    try {
      fs.unlinkSync(path);
    } catch (e) {
      // ignore
    }
  }
}
