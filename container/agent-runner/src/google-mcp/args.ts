/** Small argument validators so tool handlers fail with clear messages. */

export function optStr(args: Record<string, unknown>, key: string): string | undefined {
  const v = args[key];
  if (v === undefined || v === null || v === '') return undefined;
  if (typeof v !== 'string') throw new Error(`"${key}" must be a string`);
  return v;
}

export function reqStr(args: Record<string, unknown>, key: string): string {
  const v = optStr(args, key);
  if (v === undefined) throw new Error(`"${key}" is required`);
  return v;
}

export function optInt(args: Record<string, unknown>, key: string, def: number, min: number, max: number): number {
  const v = args[key];
  if (v === undefined || v === null) return def;
  if (typeof v !== 'number' || !Number.isInteger(v)) throw new Error(`"${key}" must be an integer`);
  return Math.min(max, Math.max(min, v));
}

export function optStrArray(args: Record<string, unknown>, key: string): string[] | undefined {
  const v = args[key];
  if (v === undefined || v === null) return undefined;
  if (!Array.isArray(v) || v.some((x) => typeof x !== 'string')) throw new Error(`"${key}" must be an array of strings`);
  return v as string[];
}

/** Path-segment encode an id so it can't smuggle "/" or "?" into a URL. */
export function seg(id: string): string {
  return encodeURIComponent(id);
}
