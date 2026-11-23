// Zero-dependency validator for the JSON Schema subset the skills schemas use (docs/skills/schemas/v1; a copy ships in lib/skills/schemas/v1, kept
// byte-identical by tests/skills-schemas.sh). Supported: type, enum, const, pattern, length and range limits, required, properties,
// additionalProperties, items, uniqueItems, anyOf, not, $ref (local and sibling files) and the annotation "x-code" (the stable error code to report
// when that subschema fails). Each failure maps to one stable code (error-codes.json). Reads only the schema directory it is given.
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

export const SUPPORTED = new Set(['$schema', '$id', 'title', '$defs', 'type', 'enum', 'const', 'pattern', 'minLength', 'maxLength', 'minimum', 'maximum', 'minItems', 'maxItems', 'maxProperties', 'uniqueItems', 'required', 'properties', 'additionalProperties', 'items', 'anyOf', 'not', '$ref', 'x-code']);

// A set of schemas read from one directory. -> { load(file), validate(value, schema, ctx), check(name, doc), schemaNames }
export function createSchemaSet(dir) {
  const cache = new Map();
  const load = (file) => { if (!cache.has(file)) cache.set(file, JSON.parse(readFileSync(join(dir, file), 'utf8'))); return cache.get(file); };
  const typeOf = (v) => (v === null ? 'null' : Array.isArray(v) ? 'array' : Number.isInteger(v) ? 'integer' : typeof v);
  const isType = (v, t) => (t === 'number' ? typeof v === 'number' : t === 'integer' ? Number.isInteger(v) : typeOf(v) === t);
  const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);

  function resolve(schema, ctx) {
    if (!schema.$ref) return { schema, ctx };
    const [file, frag] = schema.$ref.split('#');
    const doc = file ? load(file) : ctx.doc;
    let node = doc;
    if (frag) for (const part of frag.split('/').slice(1)) node = node[part];
    return resolve(node, { doc: file ? doc : ctx.doc });
  }

  // returns [{ path, code, message }]
  function validate(value, schema, ctx, path = '$') {
    for (const k of Object.keys(schema)) if (!SUPPORTED.has(k)) throw new Error(`schema keyword not supported by the harness: ${k}`);
    const r = resolve(schema, ctx);
    const s = r.schema; ctx = r.ctx;
    const errs = [];
    const fail = (code, message) => errs.push({ path, code, message });
    if (s.type !== undefined) {
      const types = Array.isArray(s.type) ? s.type : [s.type];
      if (!types.some((t) => isType(value, t))) { fail('skill_schema_type', `expected ${types.join('|')}, got ${typeOf(value)}`); return override(errs, s); }
    }
    if (s.const !== undefined && !same(value, s.const)) fail('skill_schema_value', `must equal ${JSON.stringify(s.const)}`);
    if (s.enum && !s.enum.some((e) => same(e, value))) fail('skill_schema_value', 'not an allowed value');
    if (typeof value === 'string') {
      if (s.pattern && !new RegExp(s.pattern).test(value)) fail('skill_schema_format', `does not match ${s.pattern}`);
      if (s.minLength !== undefined && value.length < s.minLength) fail('skill_schema_limit', 'too short');
      if (s.maxLength !== undefined && value.length > s.maxLength) fail('skill_schema_limit', 'too long');
    }
    if (typeof value === 'number') {
      if (s.minimum !== undefined && value < s.minimum) fail('skill_schema_limit', `below ${s.minimum}`);
      if (s.maximum !== undefined && value > s.maximum) fail('skill_schema_limit', `above ${s.maximum}`);
    }
    if (Array.isArray(value)) {
      if (s.minItems !== undefined && value.length < s.minItems) fail('skill_schema_limit', `fewer than ${s.minItems} items`);
      if (s.maxItems !== undefined && value.length > s.maxItems) fail('skill_schema_limit', `more than ${s.maxItems} items`);
      if (s.uniqueItems && new Set(value.map((v) => JSON.stringify(v))).size !== value.length) fail('skill_schema_duplicate', 'items must be distinct');
      if (s.items) value.forEach((v, i) => errs.push(...validate(v, s.items, ctx, `${path}[${i}]`)));
    }
    if (value !== null && typeof value === 'object' && !Array.isArray(value)) {
      const props = s.properties ?? {};
      for (const k of s.required ?? []) if (!Object.hasOwn(value, k)) errs.push({ path: `${path}.${k}`, code: 'skill_schema_missing_field', message: 'required' });
      if (s.maxProperties !== undefined && Object.keys(value).length > s.maxProperties) fail('skill_schema_limit', `more than ${s.maxProperties} properties`);
      for (const k of Object.keys(value)) {
        if (Object.hasOwn(props, k)) errs.push(...validate(value[k], props[k], ctx, `${path}.${k}`));
        else if (s.additionalProperties === false) errs.push({ path: `${path}.${k}`, code: 'skill_schema_unknown_field', message: 'unknown field' });
        else if (s.additionalProperties && typeof s.additionalProperties === 'object') errs.push(...validate(value[k], s.additionalProperties, ctx, `${path}.${k}`));
      }
    }
    if (s.anyOf) {
      const tries = s.anyOf.map((sub) => validate(value, sub, ctx, path));
      if (!tries.some((t) => t.length === 0)) {
        // report the closest alternative: the one with the fewest failures (a null or wrong-type branch is the farthest)
        const best = tries.reduce((a, b) => (b.length < a.length ? b : a));
        errs.push(...best);
      }
    }
    if (s.not && validate(value, s.not, ctx, path).length === 0) fail('skill_schema_value', 'this field is not allowed');
    return override(errs, s);
  }
  // a failing subschema with x-code reports that code instead of the generic ones it produced
  function override(errs, s) {
    if (!s['x-code'] || errs.length === 0) return errs;
    return errs.map((e) => ({ ...e, code: s['x-code'] }));
  }


  const check = (name, doc) => { const schema = load(`${name}.schema.json`); return validate(doc, schema, { doc: schema }); };
  return { load, validate, check };
}
