/**
 * 插件微内核实现（Cordis 式可逆副作用 + 双轨分级执行）。
 *
 * 关键红线（Blueprint §1 第 4/5 条、docs/DEV_GUIDE.md §5）：
 * - 任何注册（工具 / UI 快捷入口 / Hook）都必须返回 Disposable，卸载时**逆序回收**，零残留；
 * - 生成/修改技能必须走「Schema 校验 → 沙箱试跑 → 中文 Diff → 用户确认 → 落盘 + 旧版快照」；
 *   落盘一律走 `SkillRepositoryApi`，禁止只存内存；
 * - 已启用技能的工具定义与提示词片段按 `skillId` 字典序输出，保障 KV 缓存前缀字节级稳定。
 */
import { SecretApi, SettingsApi, SkillRecord, SkillRepositoryApi, SkillSnapshot } from '@app/core_model';
import {
  Disposable, DryRunReport, SkillManifest, SkillPromptSnippet, SkillSummary, ToolDefinition,
  ToolExecutionResult, UiShortcut, UpgradeResult
} from './interfaces/SkillManifest';
import { PluginEventsApi, PluginHookEvent, PluginHookName, PluginKernelApi } from './interfaces/PluginKernel';
import { builtinSkillJsonList } from './BuiltinSkills';
import { diffManifestJson } from './SkillDiff';
import {
  buildDefaultConfigJson, collectSecurityWarnings, normalizeConfigJson, normalizeManifestJson,
  validateManifestJson
} from './SkillSchema';
import { L1DeclarativeRunner } from './runners/L1DeclarativeRunner';
import { L2McpClient } from './runners/L2McpClient';
import { L3SandboxRunner } from './runners/L3SandboxRunner';
import { ToolRunner } from './runners/ToolRunner';
import { getObject, getString, parseRecord, truncateText } from './util/JsonLite';
import { McpCallOutcome, McpToolInfo } from './util/McpProtocol';

/** 内核依赖（数据层能力由入口 HAP 注入）。 */
export interface PluginKernelDeps {
  skills: SkillRepositoryApi;
  secrets: SecretApi;
  settings: SettingsApi;
}

/** 已注册工具（含来源技能，便于按 skillId 排序与卸载清理）。 */
interface RegisteredTool {
  definition: ToolDefinition;
  runner: ToolRunner;
}

/** 已挂载技能（Disposable 栈 + 分级执行器引用）。 */
interface MountedSkill {
  manifest: SkillManifest;
  configJson: string;
  disposables: Disposable[];
  toolNames: string[];
  l1Runner: L1DeclarativeRunner | null;
  l2Client: L2McpClient | null;
  l3Runner: L3SandboxRunner | null;
}

/** Hook 注册项。 */
interface HookEntry {
  id: string;
  handler: (event: PluginHookEvent) => void;
}

/** 变更监听项。 */
interface ChangeEntry {
  id: string;
  handler: () => void;
}

/** 试跑内部结果（额外标记失败是否"安全阻断"）。 */
interface DryRunOutcome {
  report: DryRunReport;
  fatal: boolean;
}

/** 普通函数式 Disposable（幂等，可重复 dispose）。 */
class FunctionDisposable implements Disposable {
  private readonly action: () => void;
  private disposed: boolean = false;

  constructor(action: () => void) {
    this.action = action;
  }

  dispose(): void {
    if (this.disposed) {
      return;
    }
    this.disposed = true;
    this.action();
  }
}

/** L2 远程工具的本地适配器（工具名带技能前缀，避免多技能重名）。 */
class McpToolRunner implements ToolRunner {
  private readonly client: L2McpClient;
  private readonly remoteName: string;

  constructor(client: L2McpClient, remoteName: string) {
    this.client = client;
    this.remoteName = remoteName;
  }

  async execute(argumentsJson: string): Promise<ToolExecutionResult> {
    const startedAt: number = Date.now();
    const outcome: McpCallOutcome = await this.client.callTool(this.remoteName, argumentsJson);
    return {
      ok: outcome.ok,
      content: truncateText(outcome.text, 8000),
      elapsedMs: Date.now() - startedAt,
      error: outcome.ok ? '' : outcome.error
    };
  }
}

/** 插件微内核。 */
export class PluginKernelImpl implements PluginKernelApi, PluginEventsApi {
  private readonly deps: PluginKernelDeps;
  /** 全部已加载清单（含未启用）。 */
  private readonly manifests: Map<string, SkillManifest> = new Map<string, SkillManifest>();
  /** 已挂载技能。 */
  private readonly mounted: Map<string, MountedSkill> = new Map<string, MountedSkill>();
  /** 工具注册表（name → 工具）。 */
  private readonly tools: Map<string, RegisteredTool> = new Map<string, RegisteredTool>();
  /** UI 快捷入口。 */
  private readonly shortcuts: Map<string, UiShortcut> = new Map<string, UiShortcut>();
  /** Hook 表。 */
  private readonly hooks: Map<string, HookEntry[]> = new Map<string, HookEntry[]>();
  /** 变更监听表。 */
  private readonly changeHandlers: Map<string, ChangeEntry> = new Map<string, ChangeEntry>();
  /** 每个技能的最近一次挂载错误（中文）。 */
  private readonly mountErrors: Map<string, string> = new Map<string, string>();
  private seq: number = 0;
  private initialized: boolean = false;

  constructor(deps: PluginKernelDeps) {
    this.deps = deps;
  }

  // ---------------------------------------------------------------------------
  // 初始化 / 列表
  // ---------------------------------------------------------------------------

  /** 从数据层加载全部技能并挂载启用项（幂等：重复调用先全部卸载再重载）。 */
  async init(): Promise<void> {
    const mountedIds: string[] = [];
    this.mounted.forEach((_skill: MountedSkill, skillId: string) => {
      mountedIds.push(skillId);
    });
    for (const skillId of mountedIds) {
      await this.unmount(skillId);
    }
    this.manifests.clear();
    this.mountErrors.clear();
    const records: SkillRecord[] = await this.deps.skills.loadSkills();
    for (const record of records) {
      const normalized = normalizeManifestJson(record.manifestJson);
      if (!normalized.ok) {
        this.mountErrors.set(record.skillId, `技能清单损坏：${normalized.error}`);
        continue;
      }
      const manifest = JSON.parse(normalized.manifestJson) as SkillManifest;
      manifest.enabled = record.enabled;
      this.manifests.set(manifest.id, manifest);
      if (record.enabled) {
        try {
          await this.mount(manifest);
        } catch (e) {
          const err = e as Error;
          this.mountErrors.set(manifest.id, err.message);
        }
      }
    }
    this.initialized = true;
    this.notifyChanged();
  }

  /** 全部技能摘要（技能管理页），按 skillId 字典序。 */
  list(): SkillSummary[] {
    const ids: string[] = [];
    this.manifests.forEach((_value: SkillManifest, key: string) => {
      ids.push(key);
    });
    ids.sort();
    const out: SkillSummary[] = [];
    for (const id of ids) {
      const manifest: SkillManifest | undefined = this.manifests.get(id);
      if (manifest === undefined) {
        continue;
      }
      out.push(this.toSummary(manifest));
    }
    return out;
  }

  /** 取技能清单（返回副本，外部无法改内存态）。 */
  get(skillId: string): SkillManifest | null {
    const manifest: SkillManifest | undefined = this.manifests.get(skillId);
    if (manifest === undefined) {
      return null;
    }
    return JSON.parse(JSON.stringify(manifest)) as SkillManifest;
  }

  /** 最近一次挂载失败原因（空串表示没有错误）。 */
  mountError(skillId: string): string {
    const message: string | undefined = this.mountErrors.get(skillId);
    return message === undefined ? '' : message;
  }

  /** 是否已完成 init。 */
  get ready(): boolean {
    return this.initialized;
  }

  /** 构造管理页摘要。 */
  private toSummary(manifest: SkillManifest): SkillSummary {
    return {
      id: manifest.id,
      version: manifest.version,
      name: manifest.name,
      description: manifest.description,
      tier: manifest.tier,
      enabled: manifest.enabled,
      mounted: this.mounted.has(manifest.id),
      configSchema: manifest.configSchema,
      savedConfigJson: manifest.savedConfigJson === undefined ? '' : manifest.savedConfigJson,
      promptSnippet: manifest.promptSnippet,
      allowedDomains: manifest.runtimePayload.allowedDomains
    };
  }

  // ---------------------------------------------------------------------------
  // 挂载 / 卸载
  // ---------------------------------------------------------------------------

  /** 挂载技能：按分级装配执行器，注册工具 / UI 入口，全部登记 Disposable。 */
  async mount(manifest: SkillManifest): Promise<Disposable> {
    if (this.mounted.has(manifest.id)) {
      await this.unmount(manifest.id);
    }
    const disposables: Disposable[] = [];
    const toolNames: string[] = [];
    const configJson: string = this.configFor(manifest);
    let l1Runner: L1DeclarativeRunner | null = null;
    let l2Client: L2McpClient | null = null;
    let l3Runner: L3SandboxRunner | null = null;
    try {
      if (manifest.tier === 'L1_DECLARATIVE') {
        l1Runner = new L1DeclarativeRunner(manifest, this.deps.secrets, configJson);
        this.registerDeclaredTool(manifest, l1Runner, disposables, toolNames);
      } else if (manifest.tier === 'L2_REMOTE_MCP') {
        const client = new L2McpClient(manifest, this.deps.secrets);
        l2Client = client;
        disposables.push(new FunctionDisposable(() => {
          client.dispose();
        }));
        client.validateEndpoint();
        await client.initialize();
        const remoteTools: McpToolInfo[] = await client.listTools();
        if (remoteTools.length === 0) {
          throw new Error('远程服务没有返回任何工具，请确认 MCP 地址与访问权限。');
        }
        for (const remoteTool of remoteTools) {
          const runner: McpToolRunner = new McpToolRunner(client, remoteTool.name);
          const description: string = remoteTool.description.length > 0
            ? remoteTool.description : `${manifest.name}：${remoteTool.name}`;
          this.addRegisteredTool(manifest, remoteTool.name, description, remoteTool.parametersJson,
            runner, disposables, toolNames);
        }
      } else {
        l3Runner = new L3SandboxRunner(manifest);
        const validationError: string = l3Runner.validate();
        if (validationError.length > 0) {
          throw new Error(validationError);
        }
        this.registerDeclaredTool(manifest, l3Runner, disposables, toolNames);
        if (toolNames.length === 0) {
          throw new Error('脚本技能必须声明可调用工具（toolSchemaJson），否则模型无法调用。');
        }
      }
      // UI 快捷入口（每个技能一个，卸载时随 Disposable 回收）
      const shortcut: UiShortcut = {
        id: `skill:${manifest.id}`,
        label: manifest.name,
        action: 'open_skill',
        skillId: manifest.id
      };
      this.shortcuts.set(shortcut.id, shortcut);
      disposables.push(new FunctionDisposable(() => {
        this.shortcuts.delete(shortcut.id);
      }));
      const mountedSkill: MountedSkill = {
        manifest,
        configJson,
        disposables,
        toolNames,
        l1Runner,
        l2Client,
        l3Runner
      };
      this.mounted.set(manifest.id, mountedSkill);
      this.manifests.set(manifest.id, manifest);
      this.mountErrors.delete(manifest.id);
      this.emit({ name: 'skill_mounted', skillId: manifest.id, detail: `已挂载 ${toolNames.length} 个工具` });
      this.notifyChanged();
      return new FunctionDisposable(() => {
        this.unmount(manifest.id);
      });
    } catch (e) {
      for (let i = disposables.length - 1; i >= 0; i--) {
        try {
          disposables[i].dispose();
        } catch (e2) {
          // 单个回收失败不阻断其余回收
        }
      }
      const err = e as Error;
      this.mountErrors.set(manifest.id, err.message);
      throw new Error(err.message);
    }
  }

  /** 卸载技能：Disposable 逆序回收，工具 / 快捷入口 / 注册表全部移除，零残留。 */
  async unmount(skillId: string): Promise<void> {
    const mountedSkill: MountedSkill | undefined = this.mounted.get(skillId);
    if (mountedSkill === undefined) {
      return;
    }
    const stack: Disposable[] = mountedSkill.disposables;
    for (let i = stack.length - 1; i >= 0; i--) {
      try {
        stack[i].dispose();
      } catch (e) {
        // 单个回收失败不阻断其余回收
      }
    }
    for (const name of mountedSkill.toolNames) {
      this.tools.delete(name);
    }
    // 兜底清理：任何仍标记为该技能的残留工具
    const orphanNames: string[] = [];
    this.tools.forEach((value: RegisteredTool, key: string) => {
      if (value.definition.skillId === skillId) {
        orphanNames.push(key);
      }
    });
    for (const name of orphanNames) {
      this.tools.delete(name);
    }
    this.mounted.delete(skillId);
    this.emit({ name: 'skill_unmounted', skillId, detail: '已卸载并回收全部注册' });
    this.notifyChanged();
  }

  /** 注册 manifest.toolSchemaJson 声明的工具。 */
  private registerDeclaredTool(manifest: SkillManifest, runner: ToolRunner,
    disposables: Disposable[], toolNames: string[]): void {
    const schemaText: string = manifest.toolSchemaJson === undefined ? '' : manifest.toolSchemaJson.trim();
    if (schemaText.length === 0) {
      return;
    }
    const schema = parseRecord(schemaText);
    if (schema === null) {
      return;
    }
    const declaredName: string = getString(schema, 'name', manifest.id).trim();
    const description: string = getString(schema, 'description', manifest.description);
    const parameters = getObject(schema, 'parameters');
    const parametersJson: string = parameters === null
      ? '{"type":"object","properties":{}}' : JSON.stringify(parameters);
    this.addRegisteredTool(manifest, declaredName, description, parametersJson, runner, disposables, toolNames);
  }

  /** 把工具放进注册表（重名时加技能前缀，保证全局唯一）。 */
  private addRegisteredTool(manifest: SkillManifest, declaredName: string, description: string,
    parametersJson: string, runner: ToolRunner, disposables: Disposable[], toolNames: string[]): string {
    const baseName: string = declaredName.length === 0 ? manifest.id : declaredName;
    let finalName: string = baseName;
    if (this.tools.has(finalName)) {
      finalName = `${manifest.id}__${baseName}`;
    }
    let suffix: number = 2;
    while (this.tools.has(finalName) && suffix < 10) {
      finalName = `${manifest.id}__${baseName}_${suffix}`;
      suffix = suffix + 1;
    }
    if (this.tools.has(finalName)) {
      return '';
    }
    const definition: ToolDefinition = {
      name: finalName,
      description,
      parametersJson,
      skillId: manifest.id
    };
    this.tools.set(finalName, { definition, runner });
    toolNames.push(finalName);
    disposables.push(new FunctionDisposable(() => {
      this.tools.delete(finalName);
    }));
    return finalName;
  }

  // ---------------------------------------------------------------------------
  // 启用 / 配置 / 升级 / 回滚 / 删除
  // ---------------------------------------------------------------------------

  /** 启用/禁用：先落盘，再挂载/卸载。挂载失败不抛错（记录 mountError 供 UI 提示）。 */
  async setEnabled(skillId: string, enabled: boolean): Promise<void> {
    const manifest: SkillManifest | undefined = this.manifests.get(skillId);
    if (manifest === undefined) {
      throw new Error(`没有找到这个技能：${skillId}`);
    }
    manifest.enabled = enabled;
    manifest.updatedAt = Date.now();
    await this.persist(manifest);
    this.manifests.set(skillId, manifest);
    if (enabled) {
      try {
        await this.mount(manifest);
      } catch (e) {
        const err = e as Error;
        this.mountErrors.set(skillId, err.message);
        this.notifyChanged();
      }
    } else {
      await this.unmount(skillId);
    }
    this.emit({ name: 'skill_updated', skillId, detail: enabled ? '已启用' : '已停用' });
    this.notifyChanged();
  }

  /** 保存用户配置：类型/范围/枚举校验后落盘，并热更新执行器。 */
  async updateConfig(skillId: string, configJson: string): Promise<UpgradeResult> {
    const manifest: SkillManifest | undefined = this.manifests.get(skillId);
    if (manifest === undefined) {
      return { ok: false, error: `没有找到这个技能：${skillId}`, diffText: '', securityWarnings: [] };
    }
    const manifestJson: string = JSON.stringify(manifest);
    const check = normalizeConfigJson(manifestJson, configJson);
    if (!check.ok) {
      return { ok: false, error: check.error, diffText: '', securityWarnings: [] };
    }
    const saved = JSON.stringify(manifest);
    const updated = JSON.parse(saved) as SkillManifest;
    updated.savedConfigJson = check.configJson;
    updated.updatedAt = Date.now();
    await this.persist(updated);
    this.manifests.set(skillId, updated);
    const mountedSkill: MountedSkill | undefined = this.mounted.get(skillId);
    if (mountedSkill !== undefined) {
      mountedSkill.configJson = check.configJson;
      mountedSkill.manifest = updated;
      if (mountedSkill.l1Runner !== null) {
        mountedSkill.l1Runner.setConfig(check.configJson);
      }
    }
    this.emit({ name: 'skill_updated', skillId, detail: '配置已保存' });
    this.notifyChanged();
    return {
      ok: true,
      diffText: diffManifestJson(saved, JSON.stringify(updated)),
      securityWarnings: [],
      manifest: updated
    };
  }

  /**
   * 原子升级：Schema 校验 → 试跑 → 旧版快照 → 落盘 → 热挂载。
   * 试跑中的"网络/密钥"失败不阻断（记入告警），校验/白名单/沙箱类失败则阻断。
   */
  async atomicUpgrade(manifest: SkillManifest, dryRunInput?: string): Promise<UpgradeResult> {
    const incomingJson: string = JSON.stringify(manifest);
    const oldManifest: SkillManifest | undefined = this.manifests.get(manifest.id);
    const oldJson: string = oldManifest === undefined ? '' : JSON.stringify(oldManifest);
    const normalized = normalizeManifestJson(incomingJson);
    if (!normalized.ok) {
      return {
        ok: false,
        error: normalized.error,
        diffText: diffManifestJson(oldJson, incomingJson),
        securityWarnings: normalized.warnings
      };
    }
    const validation = validateManifestJson(normalized.manifestJson);
    const diffText: string = diffManifestJson(oldJson, normalized.manifestJson);
    if (!validation.ok) {
      return { ok: false, error: validation.error, diffText, securityWarnings: validation.warnings };
    }
    const newManifest = JSON.parse(normalized.manifestJson) as SkillManifest;
    newManifest.updatedAt = Date.now();
    const warnings: string[] = validation.warnings.slice(0);
    const sample: string = dryRunInput !== undefined && dryRunInput.trim().length > 0
      ? dryRunInput.trim() : this.sampleInputFor(newManifest);
    const outcome: DryRunOutcome = await this.runDryRun(newManifest, sample);
    for (const warning of outcome.report.securityWarnings) {
      if (warnings.indexOf(warning) < 0) {
        warnings.push(warning);
      }
    }
    if (!outcome.report.passed) {
      if (outcome.fatal) {
        return {
          ok: false,
          error: `试跑未通过：${outcome.report.error === undefined ? '未知原因' : outcome.report.error}`,
          diffText,
          securityWarnings: warnings
        };
      }
      warnings.push('试跑请求没有成功（可能暂时无网络或未配置密钥），已跳过真实请求，仅完成结构与安全校验。');
    }
    try {
      if (oldManifest !== undefined) {
        const snapshot: SkillSnapshot = {
          skillId: oldManifest.id,
          version: oldManifest.version,
          manifestJson: oldJson,
          savedAt: Date.now()
        };
        await this.deps.skills.saveSkillSnapshot(snapshot);
      }
      await this.persist(newManifest);
      this.manifests.set(newManifest.id, newManifest);
      if (newManifest.enabled) {
        await this.mount(newManifest);
      } else {
        await this.unmount(newManifest.id);
      }
      this.emit({ name: 'skill_updated', skillId: newManifest.id, detail: '已升级并热挂载' });
      this.notifyChanged();
      return { ok: true, diffText, securityWarnings: warnings, manifest: newManifest };
    } catch (e) {
      const err = e as Error;
      // 恢复旧版：技能原本存在则写回旧清单并重新挂载；新建技能则删除
      if (oldManifest !== undefined) {
        try {
          await this.persist(oldManifest);
          this.manifests.set(oldManifest.id, oldManifest);
          if (oldManifest.enabled) {
            await this.mount(oldManifest);
          }
        } catch (e2) {
          // 回滚也失败时保留内存态，由 UI 提示手工处理
        }
      } else {
        try {
          await this.deps.skills.removeSkill(newManifest.id);
          this.manifests.delete(newManifest.id);
        } catch (e3) {
          // 忽略
        }
      }
      this.notifyChanged();
      return {
        ok: false,
        error: `保存技能失败，已恢复旧版：${err.message}`,
        diffText,
        securityWarnings: warnings
      };
    }
  }

  /** 回滚到上一个版本快照（读写都走数据层，禁止只存内存）。 */
  async rollback(skillId: string): Promise<boolean> {
    const snapshot: SkillSnapshot | null = await this.deps.skills.loadPreviousSnapshot(skillId);
    if (snapshot === null) {
      return false;
    }
    const normalized = normalizeManifestJson(snapshot.manifestJson);
    if (!normalized.ok) {
      return false;
    }
    const target = JSON.parse(normalized.manifestJson) as SkillManifest;
    const current: SkillManifest | undefined = this.manifests.get(skillId);
    if (current !== undefined) {
      const reverse: SkillSnapshot = {
        skillId,
        version: current.version,
        manifestJson: JSON.stringify(current),
        savedAt: Date.now()
      };
      await this.deps.skills.saveSkillSnapshot(reverse);
      target.enabled = current.enabled;
    }
    target.updatedAt = Date.now();
    await this.persist(target);
    this.manifests.set(skillId, target);
    if (target.enabled) {
      await this.mount(target);
    } else {
      await this.unmount(skillId);
    }
    this.emit({ name: 'skill_updated', skillId, detail: '已回滚到上一版本' });
    this.notifyChanged();
    return true;
  }

  /** 删除技能（含全部快照），卸载零残留。 */
  async remove(skillId: string): Promise<void> {
    await this.unmount(skillId);
    this.manifests.delete(skillId);
    this.mountErrors.delete(skillId);
    await this.deps.skills.removeSkill(skillId);
    await this.deps.skills.clearSkillSnapshots(skillId);
    this.notifyChanged();
  }

  /** 导入清单 JSON（等价 atomicUpgrade，L1 声明式热添加的主路径）。 */
  async importManifest(manifestJson: string): Promise<UpgradeResult> {
    const normalized = normalizeManifestJson(manifestJson);
    if (!normalized.ok) {
      return { ok: false, error: normalized.error, diffText: '', securityWarnings: normalized.warnings };
    }
    const manifest = JSON.parse(normalized.manifestJson) as SkillManifest;
    return this.atomicUpgrade(manifest);
  }

  /** 导出清单 JSON（供分享 / 局域网编辑）。 */
  exportManifest(skillId: string): string {
    const manifest: SkillManifest | undefined = this.manifests.get(skillId);
    if (manifest === undefined) {
      return '';
    }
    return JSON.stringify(manifest);
  }

  // ---------------------------------------------------------------------------
  // 供模型使用的提示词与工具
  // ---------------------------------------------------------------------------

  /** 启用技能的提示词片段（按 skillId 字典序，保障缓存前缀稳定）。 */
  promptSnippets(): SkillPromptSnippet[] {
    const ids: string[] = [];
    this.manifests.forEach((_value: SkillManifest, key: string) => {
      ids.push(key);
    });
    ids.sort();
    const out: SkillPromptSnippet[] = [];
    for (const id of ids) {
      const manifest: SkillManifest | undefined = this.manifests.get(id);
      if (manifest === undefined || !manifest.enabled) {
        continue;
      }
      const snippet: string = manifest.promptSnippet === undefined ? '' : manifest.promptSnippet.trim();
      if (snippet.length === 0) {
        continue;
      }
      out.push({ skillId: id, name: manifest.name, snippet });
    }
    return out;
  }

  /** 已挂载工具定义（按 skillId + 工具名字典序，保障缓存前缀稳定）。 */
  toolDefinitions(): ToolDefinition[] {
    const out: ToolDefinition[] = [];
    this.tools.forEach((value: RegisteredTool) => {
      out.push(value.definition);
    });
    out.sort((left: ToolDefinition, right: ToolDefinition): number => {
      if (left.skillId !== right.skillId) {
        return left.skillId < right.skillId ? -1 : 1;
      }
      if (left.name === right.name) {
        return 0;
      }
      return left.name < right.name ? -1 : 1;
    });
    return out;
  }

  /** 执行工具调用（ChatRuntime 收到 tool_call 时调用），统一返回中文错误与耗时。 */
  async executeTool(name: string, argumentsJson: string): Promise<ToolExecutionResult> {
    const startedAt: number = Date.now();
    const registered: RegisteredTool | undefined = this.tools.get(name);
    if (registered === undefined) {
      return {
        ok: false,
        content: '',
        elapsedMs: Date.now() - startedAt,
        error: `没有找到名为「${name}」的技能工具，可能对应技能已停用或卸载。`
      };
    }
    let input: string = argumentsJson === null || argumentsJson === undefined ? '' : argumentsJson.trim();
    if (input.length === 0) {
      input = '{}';
    }
    if (parseRecord(input) === null) {
      return {
        ok: false,
        content: '',
        elapsedMs: Date.now() - startedAt,
        error: '工具参数不是合法的 JSON 对象。'
      };
    }
    try {
      const result: ToolExecutionResult = await registered.runner.execute(input);
      this.emit({ name: 'tool_invoked', skillId: registered.definition.skillId, detail: name });
      return result;
    } catch (e) {
      const err = e as Error;
      return {
        ok: false,
        content: '',
        elapsedMs: Date.now() - startedAt,
        error: `工具执行失败：${err.message}`
      };
    }
  }

  // ---------------------------------------------------------------------------
  // 试跑
  // ---------------------------------------------------------------------------

  /** 仅在受控环境试跑草稿（不落盘）。 */
  async dryRun(manifestJson: string, sampleInput: string): Promise<DryRunReport> {
    const normalized = normalizeManifestJson(manifestJson);
    if (!normalized.ok) {
      return { passed: false, latencyMs: 0, sampleOutput: '', securityWarnings: normalized.warnings, error: normalized.error };
    }
    const validation = validateManifestJson(normalized.manifestJson);
    if (!validation.ok) {
      return { passed: false, latencyMs: 0, sampleOutput: '', securityWarnings: validation.warnings, error: validation.error };
    }
    const manifest = JSON.parse(normalized.manifestJson) as SkillManifest;
    let input: string = sampleInput === null || sampleInput === undefined ? '' : sampleInput.trim();
    if (input.length === 0) {
      input = this.sampleInputFor(manifest);
    }
    const outcome: DryRunOutcome = await this.runDryRun(manifest, input);
    return outcome.report;
  }

  /** 分级试跑（内部）。 */
  private async runDryRun(manifest: SkillManifest, sampleInput: string): Promise<DryRunOutcome> {
    const startedAt: number = Date.now();
    const manifestJson: string = JSON.stringify(manifest);
    const warnings: string[] = collectSecurityWarnings(manifestJson);
    if (manifest.tier === 'L3_QUICKJS_SANDBOX') {
      const runner: L3SandboxRunner = new L3SandboxRunner(manifest);
      const report: DryRunReport = await runner.dryRun(sampleInput);
      return { report, fatal: true };
    }
    if (manifest.tier === 'L2_REMOTE_MCP') {
      const client: L2McpClient = new L2McpClient(manifest, this.deps.secrets);
      try {
        client.validateEndpoint();
        await client.initialize();
        const remoteTools: McpToolInfo[] = await client.listTools();
        client.dispose();
        if (remoteTools.length === 0) {
          return {
            report: {
              passed: false,
              latencyMs: Date.now() - startedAt,
              sampleOutput: '',
              securityWarnings: warnings,
              error: '远程服务没有返回任何工具，请检查 MCP 地址与服务端权限。'
            },
            fatal: false
          };
        }
        const names: string[] = [];
        for (const one of remoteTools) {
          names.push(one.name);
        }
        return {
          report: {
            passed: true,
            latencyMs: Date.now() - startedAt,
            sampleOutput: truncateText(`发现 ${remoteTools.length} 个远程工具：${names.join('、')}`, 800),
            securityWarnings: warnings
          },
          fatal: false
        };
      } catch (e) {
        client.dispose();
        const err = e as Error;
        return {
          report: {
            passed: false,
            latencyMs: Date.now() - startedAt,
            sampleOutput: '',
            securityWarnings: warnings,
            error: err.message
          },
          fatal: false
        };
      }
    }
    const template = manifest.runtimePayload.httpTemplate;
    if (template === undefined) {
      return {
        report: {
          passed: true,
          latencyMs: Date.now() - startedAt,
          sampleOutput: '该技能只注入提示词片段，不调用外部工具（结构与安全校验通过）。',
          securityWarnings: warnings
        },
        fatal: false
      };
    }
    const runner: L1DeclarativeRunner = new L1DeclarativeRunner(manifest, this.deps.secrets,
      this.configFor(manifest));
    const result: ToolExecutionResult = await runner.execute(sampleInput);
    if (result.ok) {
      return {
        report: {
          passed: true,
          latencyMs: Date.now() - startedAt,
          sampleOutput: truncateText(result.content, 800),
          securityWarnings: warnings
        },
        fatal: false
      };
    }
    const errorText: string = result.error === undefined ? '试跑失败' : result.error;
    return {
      report: {
        passed: false,
        latencyMs: Date.now() - startedAt,
        sampleOutput: '',
        securityWarnings: warnings,
        error: errorText
      },
      fatal: this.isFatalDryRunError(errorText)
    };
  }

  /** 判断试跑失败是否属于"安全/结构"阻断（必须阻止落盘）。 */
  private isFatalDryRunError(errorText: string): boolean {
    const fatalKeywords: string[] = [
      '不允许访问', '没有配置', '鉴权', '模板', '参数不是', '默认拒绝', '白名单', '不合法', '被禁止'
    ];
    for (const keyword of fatalKeywords) {
      if (errorText.indexOf(keyword) >= 0) {
        return true;
      }
    }
    return false;
  }

  /** 试跑建议输入（按工具参数猜一个安全的示例）。 */
  private sampleInputFor(manifest: SkillManifest): string {
    const tool = parseRecord(manifest.toolSchemaJson === undefined ? '' : manifest.toolSchemaJson);
    const toolName: string = tool === null ? '' : getString(tool, 'name', '').toLowerCase();
    const id: string = manifest.id.toLowerCase();
    if (toolName.indexOf('currency') >= 0 || id.indexOf('fx') >= 0) {
      return '{"from":"USD","to":"CNY","amount":100}';
    }
    if (toolName.indexOf('weather') >= 0 || id.indexOf('weather') >= 0) {
      return '{"latitude":39.9,"longitude":116.4}';
    }
    if (toolName.indexOf('extract') >= 0 || id.indexOf('extract') >= 0) {
      return '{"url":"https://example.com"}';
    }
    if (toolName.length > 0) {
      return '{"query":"DeepSeek V4 发布"}';
    }
    return '{}';
  }

  // ---------------------------------------------------------------------------
  // Hook / 事件 / 快捷入口
  // ---------------------------------------------------------------------------

  /** 注册 Hook（返回 Disposable，卸载/注销后零残留）。 */
  on(event: PluginHookName, handler: (event: PluginHookEvent) => void): Disposable {
    this.seq = this.seq + 1;
    const id: string = `hook_${this.seq}`;
    const entry: HookEntry = { id, handler };
    const list: HookEntry[] | undefined = this.hooks.get(event);
    if (list === undefined) {
      this.hooks.set(event, [entry]);
    } else {
      list.push(entry);
    }
    return new FunctionDisposable(() => {
      const current: HookEntry[] | undefined = this.hooks.get(event);
      if (current === undefined) {
        return;
      }
      const index: number = current.findIndex((one: HookEntry) => one.id === id);
      if (index >= 0) {
        current.splice(index, 1);
      }
      if (current.length === 0) {
        this.hooks.delete(event);
      }
    });
  }

  /** 技能/工具状态变化监听（UI 刷新列表用）。 */
  onChanged(handler: () => void): Disposable {
    this.seq = this.seq + 1;
    const id: string = `change_${this.seq}`;
    const entry: ChangeEntry = { id, handler };
    this.changeHandlers.set(id, entry);
    return new FunctionDisposable(() => {
      this.changeHandlers.delete(id);
    });
  }

  /** 派发 Hook（单个 Hook 异常不影响其余 Hook 与主流程）。 */
  private emit(event: PluginHookEvent): void {
    const list: HookEntry[] | undefined = this.hooks.get(event.name);
    if (list === undefined) {
      return;
    }
    const snapshot: HookEntry[] = list.slice(0);
    for (const entry of snapshot) {
      try {
        entry.handler(event);
      } catch (e) {
        // 忽略单个 Hook 的异常
      }
    }
  }

  /** 通知全部变更监听。 */
  private notifyChanged(): void {
    const entries: ChangeEntry[] = [];
    this.changeHandlers.forEach((value: ChangeEntry) => {
      entries.push(value);
    });
    for (const entry of entries) {
      try {
        entry.handler();
      } catch (e) {
        // 忽略单个监听异常
      }
    }
  }

  /** 当前注册的 UI 快捷入口（按 id 字典序）。 */
  uiShortcuts(): UiShortcut[] {
    const out: UiShortcut[] = [];
    this.shortcuts.forEach((value: UiShortcut) => {
      out.push(value);
    });
    out.sort((left: UiShortcut, right: UiShortcut): number => {
      if (left.id === right.id) {
        return 0;
      }
      return left.id < right.id ? -1 : 1;
    });
    return out;
  }

  // ---------------------------------------------------------------------------
  // 内置技能播种
  // ---------------------------------------------------------------------------

  /** 内置示例技能播种（幂等：已存在则跳过，不覆盖用户改动）。 */
  async seedBuiltins(): Promise<void> {
    const jsons: string[] = builtinSkillJsonList();
    let changed: boolean = false;
    for (const json of jsons) {
      const normalized = normalizeManifestJson(json);
      if (!normalized.ok) {
        continue;
      }
      const manifest = JSON.parse(normalized.manifestJson) as SkillManifest;
      const existing: SkillRecord | null = await this.deps.skills.loadSkill(manifest.id);
      if (existing !== null) {
        if (!this.manifests.has(manifest.id)) {
          const existingNormalized = normalizeManifestJson(existing.manifestJson);
          if (existingNormalized.ok) {
            const loaded = JSON.parse(existingNormalized.manifestJson) as SkillManifest;
            loaded.enabled = existing.enabled;
            this.manifests.set(loaded.id, loaded);
            changed = true;
          }
        }
        continue;
      }
      manifest.updatedAt = Date.now();
      await this.persist(manifest);
      this.manifests.set(manifest.id, manifest);
      changed = true;
      if (this.initialized && manifest.enabled) {
        try {
          await this.mount(manifest);
        } catch (e) {
          const err = e as Error;
          this.mountErrors.set(manifest.id, err.message);
        }
      }
    }
    if (changed) {
      this.notifyChanged();
    }
  }

  // ---------------------------------------------------------------------------
  // 内部工具
  // ---------------------------------------------------------------------------

  /** 计算技能当前生效配置（校验失败时回落到默认值）。 */
  private configFor(manifest: SkillManifest): string {
    const manifestJson: string = JSON.stringify(manifest);
    const saved: string = manifest.savedConfigJson === undefined ? '' : manifest.savedConfigJson;
    const check = normalizeConfigJson(manifestJson, saved);
    if (check.ok) {
      return check.configJson;
    }
    return buildDefaultConfigJson(manifestJson);
  }

  /** 落盘（唯一写路径，禁止只存内存）。 */
  private async persist(manifest: SkillManifest): Promise<void> {
    const record: SkillRecord = {
      skillId: manifest.id,
      version: manifest.version,
      enabled: manifest.enabled,
      manifestJson: JSON.stringify(manifest),
      updatedAt: Date.now()
    };
    await this.deps.skills.saveSkill(record);
  }
}
