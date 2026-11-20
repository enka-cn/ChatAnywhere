/**
 * 域名与 URL 工具（packages/core_plugin/util/DomainUtil.ets）
 *
 * 安全红线相关（Blueprint §1.4 / DEV_GUIDE §5）：插件只能访问 allowedDomains，
 * 默认拒绝、禁止通配符、子域名按后缀匹配。这些纯函数是白名单校验的地基。
 */
import { test, assert, skip, summarize } from './_harness.mjs';
import { tryImport, missingReason } from './_paths.mjs';

const P = 'packages/core_plugin/src/main/ets/util/DomainUtil.ts';
const m = await tryImport(P);

if (!m) {
  skip('域名与 URL 工具（全部用例）', missingReason(P));
  summarize();
} else {
  test('extractHost：scheme/端口/路径/查询/锚点/用户信息全部剥离并小写', () => {
    assert.equal(m.extractHost('https://Example.COM:8443/a?b=1#c'), 'example.com');
    assert.equal(m.extractHost('http://user:pass@api.example.com/path'), 'api.example.com');
    assert.equal(m.extractHost('example.com/path'), 'example.com');
    assert.equal(m.extractHost(''), '');
    assert.equal(m.extractHost(null), '');
  });

  test('extractHost：IPv6 字面量保留方括号', () => {
    assert.equal(m.extractHost('http://[::1]:8080/path'), '[::1]');
  });

  test('normalizeHost：去 scheme/路径/端口/尾部点并小写', () => {
    assert.equal(m.normalizeHost('  HTTPS://Example.COM.:443/path '), 'example.com');
    assert.equal(m.normalizeHost('example.com'), 'example.com');
    assert.equal(m.normalizeHost(''), '');
  });

  test('isValidDomainPattern：合法域名 / localhost / IPv4 通过，通配符与非法字符拒绝', () => {
    assert.equal(m.isValidDomainPattern('example.com'), true);
    assert.equal(m.isValidDomainPattern('api.example.co.uk'), true);
    assert.equal(m.isValidDomainPattern('localhost'), true);
    assert.equal(m.isValidDomainPattern('127.0.0.1'), true);
    assert.equal(m.isValidDomainPattern('*.example.com'), false);
    assert.equal(m.isValidDomainPattern('bad_domain.com'), false);
    assert.equal(m.isValidDomainPattern(''), false);
  });

  test('isDomainAllowed：精确命中与子域名后缀命中', () => {
    assert.equal(m.isDomainAllowed('example.com', ['example.com']), true);
    assert.equal(m.isDomainAllowed('api.example.com', ['example.com']), true);
    assert.equal(m.isDomainAllowed('notexample.com', ['example.com']), false);
    assert.equal(m.isDomainAllowed('example.com.evil.com', ['example.com']), false);
  });

  test('isDomainAllowed：大小写不敏感、空 host/空白名单一律拒绝', () => {
    assert.equal(m.isDomainAllowed('API.Example.com', ['example.com']), true);
    assert.equal(m.isDomainAllowed('', ['example.com']), false);
    assert.equal(m.isDomainAllowed('example.com', []), false);
    assert.equal(m.isDomainAllowed('example.com', ['']), false);
  });

  test('isSecureOrLocalUrl：https 通过；http 仅本地回环通过', () => {
    assert.equal(m.isSecureOrLocalUrl('https://example.com'), true);
    assert.equal(m.isSecureOrLocalUrl('http://localhost:8080'), true);
    assert.equal(m.isSecureOrLocalUrl('http://127.0.0.1/x'), true);
    assert.equal(m.isSecureOrLocalUrl('http://example.com'), false);
    assert.equal(m.isSecureOrLocalUrl('ftp://example.com'), false);
    assert.equal(m.isSecureOrLocalUrl(''), false);
  });

  test('hostFromUrlTemplate：静态 URL 返回 host；scheme/host 段含占位符均返回空串（不可静态判定）', () => {
    assert.equal(m.hostFromUrlTemplate('https://api.example.com/v1/{{input.city}}'), 'api.example.com');
    assert.equal(m.hostFromUrlTemplate('https://{{input.host}}/v1'), '');
    assert.equal(m.hostFromUrlTemplate('{{input.scheme}}://api.example.com'), '');
  });

  test('安全性质：无法静态判定的 host 一律无法通过 allowedDomains 白名单（默认拒绝）', () => {
    const host = m.hostFromUrlTemplate('https://{{input.host}}/v1');
    assert.equal(host, '', 'host 占位符模板必须返回空串，交给调用方按无法静态校验处理');
    assert.equal(m.isDomainAllowed(host, ['example.com', 'api.example.com']), false);
    // 即便有人把占位符原样当 host 传进来，也不会命中白名单 / 不是合法域名
    assert.equal(m.isDomainAllowed('{{input.host}}', ['example.com']), false);
    assert.equal(m.isValidDomainPattern('{{input.host}}'), false);
  });

  test('findInvalidDomain：返回第一个非法项，全合法返回空串', () => {
    assert.equal(m.findInvalidDomain(['example.com', 'api.example.com']), '');
    assert.equal(m.findInvalidDomain(['example.com', '*.bad.com']), '*.bad.com');
    assert.equal(m.findInvalidDomain([]), '');
  });

  test('toIncludeSiteSyntax / toExcludeSiteSyntax：组装 site: / -site: 片段', () => {
    assert.equal(m.toIncludeSiteSyntax(['github.com', 'b.com']), ' site:github.com OR site:b.com');
    assert.equal(m.toExcludeSiteSyntax(['x.com', 'y.com']), ' -site:x.com -site:y.com');
    assert.equal(m.toIncludeSiteSyntax([]), '');
    assert.equal(m.toExcludeSiteSyntax([]), '');
  });

  summarize();
}
