// Faithful JS port of the Swift JSONValue.apply(_:) algorithm in
// BallparkMatchups/API/JSONValue.swift. Same control flow, same error points.

class PatchError extends Error {}

const unescape = t => t.replace(/~1/g, '/').replace(/~0/g, '~');

function pointerTokens(raw) {
  if (raw === '') return [];
  if (!raw.startsWith('/')) throw new PatchError('malformedPointer ' + raw);
  return raw.slice(1).split('/').map(unescape);
}

function emptyContainer(nextToken) {
  return /^(0|[1-9][0-9]*)$/.test(nextToken) ? [] : {};
}

function valueAt(root, tokens) {
  let node = root;
  for (const t of tokens) {
    if (Array.isArray(node)) {
      const i = Number(t);
      if (!Number.isInteger(i) || i < 0 || i >= node.length) return undefined;
      node = node[i];
    } else if (node !== null && typeof node === 'object') {
      if (!(t in node)) return undefined;
      node = node[t];
    } else return undefined;
  }
  return node;
}

// Mirrors `JSONValue.grow` — pads with explicit nulls up to `index`.
// JavaScript holes stringify as null anyway, so the reference's `arr[9] = v`
// and this produce identical JSON.
const MAX_ARRAY_GAP = 10000;
function grow(arr, index, fullPath) {
  if (index <= arr.length) return;
  if (index - arr.length > MAX_ARRAY_GAP)
    throw new PatchError(`arrayIndexOutOfBounds ${fullPath} idx=${index} count=${arr.length}`);
  while (arr.length < index) arr.push(null);
}

// Mirrors `descend` — returns the parent container, creating missing intermediates.
function descend(root, path, nextTokenAfterPath, fullPath) {
  let node = root;
  for (let k = 0; k < path.length; k++) {
    const token = path[k];
    const childShapeHint = (k + 1 < path.length) ? path[k + 1] : nextTokenAfterPath;
    if (Array.isArray(node)) {
      const i = Number(token);
      if (!Number.isInteger(i) || i < 0)
        throw new PatchError(`arrayIndexOutOfBounds ${fullPath} idx=${token} count=${node.length}`);
      grow(node, i, fullPath);
      if (i === node.length) node.push(emptyContainer(childShapeHint));
      else if (node[i] === null) node[i] = emptyContainer(childShapeHint);  // a hole
      node = node[i];
    } else if (node !== null && typeof node === 'object') {
      if (node[token] === undefined || node[token] === null) node[token] = emptyContainer(childShapeHint);
      node = node[token];
    } else {
      throw new PatchError('notTraversable ' + fullPath);
    }
  }
  return node;
}

function setValue(root, tokens, newValue, fullPath) {
  if (tokens.length === 0) throw new PatchError('emptyPath');
  const leaf = tokens[tokens.length - 1];
  const parent = descend(root, tokens.slice(0, -1), leaf, fullPath);
  if (Array.isArray(parent)) {
    const i = Number(leaf);
    if (!Number.isInteger(i)) throw new PatchError('notTraversable ' + fullPath);
    if (i < 0)
      throw new PatchError(`arrayIndexOutOfBounds ${fullPath} idx=${i} count=${parent.length}`);
    // MLB's reference assigns (`root[accessor] = value`) for every write,
    // in bounds or past the end, letting JavaScript grow the array with holes.
    grow(parent, i, fullPath);
    if (i < parent.length) parent[i] = newValue; else parent.push(newValue);
  } else if (parent !== null && typeof parent === 'object') {
    parent[leaf] = newValue;
  } else throw new PatchError('notTraversable ' + fullPath);
}

function removeValue(root, tokens, fullPath) {
  if (tokens.length === 0) throw new PatchError('emptyPath');
  if (valueAt(root, tokens) === undefined) return;   // already absent — no-op, as in Swift
  const leaf = tokens[tokens.length - 1];
  const parent = valueAt(root, tokens.slice(0, -1));
  if (Array.isArray(parent)) parent.splice(Number(leaf), 1);
  else delete parent[leaf];
}

function applyOne(root, op) {
  const pt = pointerTokens(op.path);
  switch (op.op) {
    case 'test': {
      const actual = valueAt(root, pt);
      if (JSON.stringify(actual) !== JSON.stringify(op.value))
        throw new PatchError('testFailed ' + op.path);
      return;
    }
    case 'add':
    case 'replace': {
      if (!('value' in op)) throw new PatchError('missingValue ' + op.path);
      setValue(root, pt, op.value, op.path);
      return;
    }
    case 'remove':
      removeValue(root, pt, op.path);
      return;
    case 'copy': {
      if (op.from === undefined) throw new PatchError('missingFrom ' + op.path);
      const copied = valueAt(root, pointerTokens(op.from));
      if (copied === undefined) throw new PatchError('pathNotFound ' + op.from);
      setValue(root, pt, JSON.parse(JSON.stringify(copied)), op.path);
      return;
    }
    case 'move': {
      if (op.from === undefined) throw new PatchError('missingFrom ' + op.path);
      const moved = valueAt(root, pointerTokens(op.from));
      if (moved === undefined) throw new PatchError('pathNotFound ' + op.from);
      // Atomic like Swift's move: work on a copy and keep it only if both steps succeed.
      const working = JSON.parse(JSON.stringify(root));
      removeValue(working, pointerTokens(op.from), op.from);
      setValue(working, pt, moved, op.path);
      for (const key of Object.keys(root)) delete root[key];
      Object.assign(root, working);
      return;
    }
    default:
      throw new PatchError('unsupportedOperation ' + op.op);
  }
}

function apply(root, ops) {
  for (const op of ops) applyOne(root, op);
}

module.exports = { apply, applyOne, PatchError, pointerTokens, valueAt };
