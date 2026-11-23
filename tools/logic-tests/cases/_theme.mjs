/**
 * v3.7 颜色基线：code/math 12 个新增令牌的两套精确值。
 *
 * 供 90–97 静态门禁复用，避免每个文件重复维护 24 条色值断言。
 * 注意：v3.7 去重后 base/dark 各 **64** 键（不是 65）。
 */

export const BASE_CODE_MATH = {
  code_header_bg: '#F6F8FA',
  code_bg: '#F3F4F7',
  code_text: '#111318',
  code_type: '#8250DF',
  code_function: '#6639BA',
  code_macro: '#953800',
  code_comment: '#6E7781',
  code_number: '#0550AE',
  code_plain: '#1F2328',
  code_string: '#0A3069',
  code_keyword: '#CF222E',
  math_inline: '#0B4A8F'
};

export const DARK_CODE_MATH = {
  code_header_bg: '#141821',
  code_bg: '#12151B',
  code_text: '#E6EDF3',
  code_type: '#E5C07B',
  code_function: '#61AFEF',
  code_macro: '#56B6C2',
  code_comment: '#5C6370',
  code_number: '#D19A66',
  code_plain: '#ABB2BF',
  code_string: '#98C379',
  code_keyword: '#C678DD',
  math_inline: '#8AB4F8'
};

/** 断言 12 个 code/math 键在 base/dark 中的精确值（键必须存在）。 */
export function verifyCodeMathColors(assert, baseJson, darkJson) {
  const bv = Object.fromEntries(baseJson.color.map((c) => [c.name, String(c.value).toUpperCase()]));
  const dv = Object.fromEntries(darkJson.color.map((c) => [c.name, String(c.value).toUpperCase()]));
  for (const key of Object.keys(BASE_CODE_MATH)) {
    assert.ok(bv[key] !== undefined, `base 缺少 v3.7 色键 ${key}`);
    assert.ok(dv[key] !== undefined, `dark 缺少 v3.7 色键 ${key}`);
    assert.equal(bv[key], BASE_CODE_MATH[key], `base ${key}（v3.7 代码/公式色）`);
    assert.equal(dv[key], DARK_CODE_MATH[key], `dark ${key}（v3.7 代码/公式色）`);
  }
}
