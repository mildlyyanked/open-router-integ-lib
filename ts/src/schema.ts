import type { JsonSchema } from "./types.js";

/**
 * Validates a value against the JSON Schema subset used for structured
 * outputs. Returns human-readable errors (empty = valid); they are written
 * to be fed back to the model in the repair loop.
 */
export function validate(value: unknown, schema: JsonSchema, path = "$"): string[] {
  const errors: string[] = [];
  check(value, schema, path, errors);
  return errors;
}

function typeOk(v: unknown, t: string): boolean {
  switch (t) {
    case "object": return typeof v === "object" && v !== null && !Array.isArray(v);
    case "array": return Array.isArray(v);
    case "string": return typeof v === "string";
    case "boolean": return typeof v === "boolean";
    case "null": return v === null;
    case "number": return typeof v === "number" && Number.isFinite(v);
    case "integer": return typeof v === "number" && Number.isInteger(v);
  }
  return false;
}

function check(v: unknown, s: JsonSchema, path: string, errors: string[]): void {
  if (s.type !== undefined) {
    const types = Array.isArray(s.type) ? s.type : [s.type];
    if (!types.some((t) => typeOk(v, t))) {
      errors.push(`${path}: expected type ${types.join("/")}`);
      return;
    }
  }
  if (s.enum && !s.enum.some((o) => o === v)) {
    errors.push(`${path}: value ${JSON.stringify(v)} is not one of ${JSON.stringify(s.enum)}`);
  }
  if (Array.isArray(v)) {
    if (s.minItems !== undefined && v.length < s.minItems) errors.push(`${path}: needs at least ${s.minItems} items`);
    if (s.maxItems !== undefined && v.length > s.maxItems) errors.push(`${path}: allows at most ${s.maxItems} items`);
    if (s.items) v.forEach((x, i) => check(x, s.items as JsonSchema, `${path}[${i}]`, errors));
  } else if (typeof v === "object" && v !== null) {
    const o = v as Record<string, unknown>;
    const props = s.properties ?? {};
    for (const r of s.required ?? []) if (!(r in o)) errors.push(`${path}: missing required field '${r}'`);
    if (s.additionalProperties === false) {
      for (const k of Object.keys(o)) if (!(k in props)) errors.push(`${path}: unexpected field '${k}'`);
    }
    for (const [k, sub] of Object.entries(props)) if (k in o) check(o[k], sub, `${path}.${k}`, errors);
  } else if (typeof v === "string") {
    if (s.minLength !== undefined && v.length < s.minLength) errors.push(`${path}: shorter than ${s.minLength} characters`);
    if (s.maxLength !== undefined && v.length > s.maxLength) errors.push(`${path}: longer than ${s.maxLength} characters`);
  } else if (typeof v === "number") {
    if (s.minimum !== undefined && v < s.minimum) errors.push(`${path}: below minimum ${s.minimum}`);
    if (s.maximum !== undefined && v > s.maximum) errors.push(`${path}: above maximum ${s.maximum}`);
  }
}

/** Strict structured-output modes reject string length keywords: strip them for the wire (local validation still enforces them). */
export function wireSchema<T>(v: T): T {
  if (Array.isArray(v)) return v.map((x) => wireSchema(x)) as T;
  if (v && typeof v === "object") {
    const out: Record<string, unknown> = {};
    for (const [k, x] of Object.entries(v)) if (k !== "minLength" && k !== "maxLength") out[k] = wireSchema(x);
    return out as T;
  }
  return v;
}
