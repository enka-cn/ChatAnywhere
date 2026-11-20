/**
 * 密钥保管实现：所有 API Key / MCP Token 只进 HarmonyOS Asset Store Kit 加密托管。
 *
 * 事实来源：`@ohos.security.asset.d.ts`（见 docs/API_REFERENCE.md §7）：
 * - `AssetMap = Map<Tag, Value>`（Map！不是对象字面量）；
 * - `SECRET` / `ALIAS` 必须 `Uint8Array`；
 * - `asset.query` 查不到会抛 24000002，不是返回空数组；
 * - 明文绝不写 Preferences / RDB / 日志。
 */
import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SecretApi } from '../interfaces/SecretApi';
import { SecretAliases } from '../interfaces/SettingsKeys';

const DOMAIN: number = 0x1A2B;
const TAG: string = 'AssetSecretStore';

/** 单次列出的别名上限（设置页展示用，远小于系统上限）。 */
const ALIAS_QUERY_LIMIT: number = 200;

/** 字符串 → UTF-8 字节（Asset 的 ALIAS/SECRET 只接受 Uint8Array）。 */
function encodeText(value: string): Uint8Array {
  return util.TextEncoder.create('utf-8').encodeInto(value);
}

/** UTF-8 字节 → 字符串。 */
function decodeText(bytes: Uint8Array): string {
  return util.TextDecoder.create('utf-8').decodeToString(bytes);
}

/** 业务错误码 → 直白中文提示。 */
function describeAssetError(code: number): string {
  if (code === asset.ErrorCode.PERMISSION_DENIED) {
    return '系统拒绝了密钥访问权限';
  }
  if (code === asset.ErrorCode.NOT_FOUND) {
    return '没有找到这个密钥';
  }
  if (code === asset.ErrorCode.DUPLICATED) {
    return '这个密钥已经存在';
  }
  if (code === asset.ErrorCode.ACCESS_DENIED) {
    return '系统拒绝访问密钥，请先解锁屏幕后重试';
  }
  if (code === asset.ErrorCode.STATUS_MISMATCH) {
    return '设备锁屏状态不匹配，请解锁屏幕后重试';
  }
  if (code === asset.ErrorCode.SERVICE_UNAVAILABLE) {
    return '系统密钥服务当前不可用，请稍后重试';
  }
  if (code === asset.ErrorCode.OUT_OF_MEMORY) {
    return '系统内存不足，密钥操作失败';
  }
  if (code === asset.ErrorCode.DATA_CORRUPTED) {
    return '密钥数据已损坏，请重新保存';
  }
  if (code === asset.ErrorCode.PARAM_VERIFICATION_FAILED || code === asset.ErrorCode.INVALID_ARGUMENT) {
    return '密钥格式不合法';
  }
  return `密钥服务返回错误码 ${code}`;
}

/** 从业务错误里取 code（非 BusinessError 返回 -1）。 */
function errorCodeOf(e: Error): number {
  const err = e as BusinessError;
  if (err !== null && err !== undefined && typeof err.code === 'number') {
    return err.code as number;
  }
  return -1;
}

export class AssetSecretStore implements SecretApi {
  /**
   * 保存密钥（幂等）：先按别名删除已有记录，再新增。
   * 失败抛带中文原因的 Error。
   */
  async put(alias: string, secret: string): Promise<void> {
    if (alias === undefined || alias === null || alias.trim().length === 0) {
      throw new Error('保存密钥失败：密钥名称不能为空');
    }
    if (secret === undefined || secret === null || secret.length === 0) {
      throw new Error('保存密钥失败：密钥内容不能为空');
    }
    await this.removeQuietly(alias);
    const attributes: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    attributes.set(asset.Tag.SECRET, encodeText(secret));
    attributes.set(asset.Tag.ALIAS, encodeText(alias));
    attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    attributes.set(asset.Tag.AUTH_TYPE, asset.AuthType.NONE);
    attributes.set(asset.Tag.SYNC_TYPE, asset.SyncType.NEVER);
    attributes.set(asset.Tag.DATA_LABEL_NORMAL_1, encodeText('chatanywhere.apiKey'));
    attributes.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE);
    try {
      await asset.add(attributes);
    } catch (e) {
      const code = errorCodeOf(e as Error);
      hilog.error(DOMAIN, TAG, 'asset.add failed code=%{public}d', code);
      throw new Error(`保存密钥失败：${describeAssetError(code)}`);
    }
  }

  /** 读取密钥；不存在或读取失败返回 null（禁止抛错污染调用方）。 */
  async get(alias: string): Promise<string | null> {
    if (alias === undefined || alias === null || alias.trim().length === 0) {
      return null;
    }
    const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    query.set(asset.Tag.ALIAS, encodeText(alias));
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    try {
      const results: Array<asset.AssetMap> = await asset.query(query);
      if (results === undefined || results === null || results.length === 0) {
        return null;
      }
      const value = results[0].get(asset.Tag.SECRET);
      if (value === undefined || value === null) {
        return null;
      }
      if (typeof value === 'boolean' || typeof value === 'number') {
        return null;
      }
      return decodeText(value as Uint8Array);
    } catch (e) {
      const code = errorCodeOf(e as Error);
      if (code !== asset.ErrorCode.NOT_FOUND) {
        hilog.warn(DOMAIN, TAG, 'asset.query failed code=%{public}d', code);
      }
      return null;
    }
  }

  /** 删除密钥（不存在视为成功，保证幂等）。 */
  async remove(alias: string): Promise<void> {
    if (alias === undefined || alias === null || alias.trim().length === 0) {
      return;
    }
    const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    query.set(asset.Tag.ALIAS, encodeText(alias));
    try {
      await asset.remove(query);
    } catch (e) {
      const code = errorCodeOf(e as Error);
      if (code === asset.ErrorCode.NOT_FOUND) {
        return;
      }
      hilog.error(DOMAIN, TAG, 'asset.remove failed code=%{public}d', code);
      throw new Error(`删除密钥失败：${describeAssetError(code)}`);
    }
  }

  async has(alias: string): Promise<boolean> {
    const value = await this.get(alias);
    return value !== null;
  }

  /**
   * 列出已保存的别名（只返回别名，绝不返回明文）。
   * 优先全量属性查询；系统版本不支持时退化为「已知别名探测」，保证永不抛错。
   */
  async listAliases(): Promise<string[]> {
    const byAttribute = await this.queryAliasesByAttributes();
    if (byAttribute.length > 0) {
      return byAttribute;
    }
    return this.probeKnownAliases();
  }

  private async queryAliasesByAttributes(): Promise<string[]> {
    const query: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ATTRIBUTES);
    query.set(asset.Tag.RETURN_LIMIT, ALIAS_QUERY_LIMIT);
    query.set(asset.Tag.RETURN_OFFSET, 0);
    try {
      const results: Array<asset.AssetMap> = await asset.query(query);
      if (results === undefined || results === null) {
        return [];
      }
      const aliases: string[] = [];
      for (const item of results) {
        const aliasValue = item.get(asset.Tag.ALIAS);
        if (aliasValue === undefined || aliasValue === null) {
          continue;
        }
        if (typeof aliasValue === 'boolean' || typeof aliasValue === 'number') {
          continue;
        }
        const text = decodeText(aliasValue as Uint8Array);
        if (text.length > 0 && aliases.indexOf(text) < 0) {
          aliases.push(text);
        }
      }
      aliases.sort();
      return aliases;
    } catch (e) {
      const code = errorCodeOf(e as Error);
      if (code !== asset.ErrorCode.NOT_FOUND) {
        hilog.warn(DOMAIN, TAG, 'asset.listAliases failed code=%{public}d', code);
      }
      return [];
    }
  }

  /** 兼容兜底：只探测应用已知的别名常量。 */
  private async probeKnownAliases(): Promise<string[]> {
    const known: string[] = [
      SecretAliases.DEEPSEEK,
      SecretAliases.ANTHROPIC,
      SecretAliases.OPENAI_COMPAT,
      SecretAliases.MCP_DEFAULT_TOKEN
    ];
    const out: string[] = [];
    for (const alias of known) {
      const value = await this.get(alias);
      if (value !== null) {
        out.push(alias);
      }
    }
    out.sort();
    return out;
  }

  private async removeQuietly(alias: string): Promise<void> {
    try {
      await this.remove(alias);
    } catch (e) {
      // 删除旧值失败时仍尝试覆盖写入；写入失败的报错更准确。
      hilog.warn(DOMAIN, TAG, 'remove before put failed');
    }
  }
}
