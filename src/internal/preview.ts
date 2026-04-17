type PreviewOptions = {
  maxLength?: number;
  maxDepth?: number;
  maxObjectKeys?: number;
  maxArrayItems?: number;
  maxStringLength?: number;
};

type ResolvedPreviewOptions = {
  maxLength: number;
  maxDepth: number;
  maxObjectKeys: number;
  maxArrayItems: number;
  maxStringLength: number;
};

type PreviewState = {
  readonly options: ResolvedPreviewOptions;
  readonly parts: string[];
  length: number;
  truncated: boolean;
  ancestors: WeakSet<object>;
};

const DEFAULT_PREVIEW_OPTIONS: ResolvedPreviewOptions = {
  maxLength: 32_000,
  maxDepth: 4,
  maxObjectKeys: 40,
  maxArrayItems: 40,
  maxStringLength: 8_000,
};

const TRUNCATION_SUFFIX = '...[truncated]';

export type { PreviewOptions };

export function formatDebugValue(value: unknown, options: PreviewOptions = {}) {
  const state = createPreviewState(options);
  writeValue(state, value, 0, false);
  return finalizePreviewState(state);
}

export function formatDebugMessage(args: unknown[], options: PreviewOptions = {}) {
  const state = createPreviewState(options);
  for (let index = 0; index < args.length; index += 1) {
    if (index > 0) {
      append(state, ' ');
    }
    writeValue(state, args[index], 0, false);
    if (state.length >= state.options.maxLength) {
      state.truncated = true;
      break;
    }
  }
  return finalizePreviewState(state);
}

function createPreviewState(options: PreviewOptions): PreviewState {
  return {
    options: {
      maxLength: sanitizePositiveInteger(options.maxLength, DEFAULT_PREVIEW_OPTIONS.maxLength),
      maxDepth: sanitizePositiveInteger(options.maxDepth, DEFAULT_PREVIEW_OPTIONS.maxDepth),
      maxObjectKeys: sanitizePositiveInteger(options.maxObjectKeys, DEFAULT_PREVIEW_OPTIONS.maxObjectKeys),
      maxArrayItems: sanitizePositiveInteger(options.maxArrayItems, DEFAULT_PREVIEW_OPTIONS.maxArrayItems),
      maxStringLength: sanitizePositiveInteger(options.maxStringLength, DEFAULT_PREVIEW_OPTIONS.maxStringLength),
    },
    parts: [],
    length: 0,
    truncated: false,
    ancestors: new WeakSet<object>(),
  };
}

function sanitizePositiveInteger(value: number | undefined, fallback: number) {
  if (typeof value !== 'number' || !Number.isFinite(value)) {
    return fallback;
  }
  const nextValue = Math.floor(value);
  return nextValue > 0 ? nextValue : fallback;
}

function finalizePreviewState(state: PreviewState) {
  let result = state.parts.join('');
  if (!state.truncated) {
    return result;
  }
  if (result.length > state.options.maxLength - TRUNCATION_SUFFIX.length) {
    result = result.slice(0, Math.max(0, state.options.maxLength - TRUNCATION_SUFFIX.length));
  }
  return result + TRUNCATION_SUFFIX;
}

function append(state: PreviewState, segment: string) {
  if (!segment || state.length >= state.options.maxLength) {
    if (segment) {
      state.truncated = true;
    }
    return;
  }

  const remaining = state.options.maxLength - state.length;
  if (segment.length <= remaining) {
    state.parts.push(segment);
    state.length += segment.length;
    return;
  }

  state.parts.push(segment.slice(0, remaining));
  state.length = state.options.maxLength;
  state.truncated = true;
}

function writeValue(state: PreviewState, value: unknown, depth: number, nested: boolean) {
  if (state.length >= state.options.maxLength) {
    state.truncated = true;
    return;
  }

  if (value == null) {
    append(state, value === null ? 'null' : 'undefined');
    return;
  }

  switch (typeof value) {
    case 'string':
      writeString(state, value, nested);
      return;
    case 'number':
    case 'boolean':
    case 'bigint':
      append(state, String(value));
      return;
    case 'symbol':
      append(state, String(value));
      return;
    case 'function':
      append(state, value.name ? `[Function ${value.name}]` : '[Function]');
      return;
    case 'object':
      writeObject(state, value as object, depth);
      return;
    default:
      append(state, String(value));
  }
}

function writeString(state: PreviewState, value: string, nested: boolean) {
  let normalized = value;
  if (value.length > state.options.maxStringLength) {
    normalized = value.slice(0, state.options.maxStringLength);
    state.truncated = true;
  }

  if (nested) {
    append(state, JSON.stringify(normalized));
    return;
  }

  append(state, normalized);
}

function writeObject(state: PreviewState, value: object, depth: number) {
  if (state.ancestors.has(value)) {
    append(state, '[Circular]');
    return;
  }

  if (value instanceof Date) {
    append(state, Number.isNaN(value.getTime()) ? 'Invalid Date' : value.toISOString());
    return;
  }

  if (value instanceof RegExp) {
    append(state, String(value));
    return;
  }

  if (value instanceof Error) {
    writeError(state, value, depth);
    return;
  }

  if (value instanceof Map) {
    writeMap(state, value, depth);
    return;
  }

  if (value instanceof Set) {
    writeSet(state, value, depth);
    return;
  }

  if (Array.isArray(value)) {
    writeArray(state, value, depth);
    return;
  }

  writePlainObject(state, value, depth);
}

function writeError(state: PreviewState, value: Error, depth: number) {
  if (depth >= state.options.maxDepth) {
    append(state, `[${value.name || 'Error'}]`);
    return;
  }

  state.ancestors.add(value);
  append(state, '{');
  append(state, '"name":');
  writeString(state, value.name || 'Error', true);

  if (value.message) {
    append(state, ',"message":');
    writeString(state, value.message, true);
  }

  if (value.stack) {
    append(state, ',"stack":');
    writeString(state, value.stack, true);
  }

  const keys = Object.keys(value).filter((key) => key !== 'name' && key !== 'message' && key !== 'stack');
  writeObjectEntries(state, value as unknown as Record<string, unknown>, keys, depth, true);
  append(state, '}');
  state.ancestors.delete(value);
}

function writeArray(state: PreviewState, value: unknown[], depth: number) {
  if (depth >= state.options.maxDepth) {
    append(state, `[Array(${value.length})]`);
    return;
  }

  state.ancestors.add(value);
  append(state, '[');
  const itemCount = Math.min(value.length, state.options.maxArrayItems);
  for (let index = 0; index < itemCount; index += 1) {
    if (index > 0) {
      append(state, ',');
    }
    writeValue(state, value[index], depth + 1, true);
    if (state.length >= state.options.maxLength) {
      break;
    }
  }
  if (value.length > itemCount) {
    append(state, `,${value.length - itemCount} more`);
    state.truncated = true;
  }
  append(state, ']');
  state.ancestors.delete(value);
}

function writeMap(state: PreviewState, value: Map<unknown, unknown>, depth: number) {
  if (depth >= state.options.maxDepth) {
    append(state, `[Map(${value.size})]`);
    return;
  }

  state.ancestors.add(value);
  append(state, `Map(${value.size}){`);
  let index = 0;
  for (const [key, mapValue] of value) {
    if (index >= state.options.maxObjectKeys) {
      append(state, `,${value.size - index} more`);
      state.truncated = true;
      break;
    }
    if (index > 0) {
      append(state, ',');
    }
    writeValue(state, key, depth + 1, true);
    append(state, '=>');
    writeValue(state, mapValue, depth + 1, true);
    index += 1;
    if (state.length >= state.options.maxLength) {
      break;
    }
  }
  append(state, '}');
  state.ancestors.delete(value);
}

function writeSet(state: PreviewState, value: Set<unknown>, depth: number) {
  if (depth >= state.options.maxDepth) {
    append(state, `[Set(${value.size})]`);
    return;
  }

  state.ancestors.add(value);
  append(state, `Set(${value.size})[`);
  let index = 0;
  for (const item of value) {
    if (index >= state.options.maxArrayItems) {
      append(state, `,${value.size - index} more`);
      state.truncated = true;
      break;
    }
    if (index > 0) {
      append(state, ',');
    }
    writeValue(state, item, depth + 1, true);
    index += 1;
    if (state.length >= state.options.maxLength) {
      break;
    }
  }
  append(state, ']');
  state.ancestors.delete(value);
}

function writePlainObject(state: PreviewState, value: object, depth: number) {
  const constructorName = value.constructor?.name;
  const shouldPrefixConstructor = constructorName && constructorName !== 'Object';

  if (depth >= state.options.maxDepth) {
    append(state, shouldPrefixConstructor ? `[${constructorName}]` : '[Object]');
    return;
  }

  state.ancestors.add(value);
  if (shouldPrefixConstructor) {
    append(state, `${constructorName}`);
  }
  append(state, '{');
  writeObjectEntries(state, value as Record<string, unknown>, Object.keys(value), depth, false);
  append(state, '}');
  state.ancestors.delete(value);
}

function writeObjectEntries(
  state: PreviewState,
  value: Record<string, unknown>,
  keys: string[],
  depth: number,
  hasLeadingEntry: boolean
) {
  const keyCount = Math.min(keys.length, state.options.maxObjectKeys);
  let wroteEntry = hasLeadingEntry;

  for (let index = 0; index < keyCount; index += 1) {
    const key = keys[index];
    if (wroteEntry) {
      append(state, ',');
    }
    append(state, JSON.stringify(key));
    append(state, ':');
    writeValue(state, value[key], depth + 1, true);
    wroteEntry = true;
    if (state.length >= state.options.maxLength) {
      break;
    }
  }

  if (keys.length > keyCount) {
    append(state, `${wroteEntry ? ',' : ''}${keys.length - keyCount} more`);
    state.truncated = true;
  }
}
