// Take.lua test harness. Run from anywhere: node tools/check.js
// 1. Parses the whole file with luaparse (catches syntax errors without luac).
// 2. Carves the pure-Lua blocks (JSON codec, sanitizers, helpers) out of
//    Take.lua and runs behavioral tests against them in a real Lua 5.4 VM
//    (wasmoon) — the only way to test this code without launching REAPER.
// The carve markers are comment lines in Take.lua; if you rename those
// comments, update the markers here.
const fs = require('fs');
const path = require('path');
const luaparse = require('luaparse');
const { LuaFactory } = require('wasmoon');

const SRC_PATH = path.join(__dirname, '..', 'Take.lua');
const src = fs.readFileSync(SRC_PATH, 'utf8');

try {
  luaparse.parse(src, { luaVersion: '5.3' });
  console.log('SYNTAX OK');
} catch (e) {
  console.error('SYNTAX FAIL:', e.message);
  process.exit(1);
}

function carve(startMarker, endMarker) {
  const a = src.indexOf(startMarker);
  if (a < 0) throw new Error('carve start marker not found: ' + startMarker);
  const b = src.indexOf(endMarker, a);
  if (b < 0) throw new Error('carve end marker not found: ' + endMarker);
  return src.slice(a, b);
}
// JSON_NULL/jval/json_decode/json_encode
const jsonBlock = carve('local JSON_NULL', 'local function tmp_path');
// shq/safe_url/safe_filename/fmt_bytes/version_newer
const pureBlock = carve('-- Single-quote a string', '-- Remove a directory');

(async () => {
  const lua = await new LuaFactory().createEngine();
  const harness = jsonBlock + '\n' + pureBlock + `
    local function eq(a, b, label)
      if a ~= b then error(label .. ': got [' .. tostring(a) .. '] want [' .. tostring(b) .. ']', 2) end
    end

    -- ---- JSON decoder ----------------------------------------------------
    -- null object keys are dropped -> reads behave like plain nil
    local o = json_decode('{"a": null, "b": 2, "name": null}')
    eq(o.a, nil, 'null key dropped')
    eq(o.b, 2, 'normal key kept')
    eq((o.name or 'fallback'), 'fallback', 'or-default works on null')
    eq(tostring(o.name or 'stem') .. '.wav', 'stem.wav', 'concat safe on null')

    -- arrays stay dense with JSON_NULL padding
    local arr = json_decode('[1, null, 3]')
    eq(#arr, 3, 'array dense')
    eq(jval(arr[2]), nil, 'jval collapses array null')

    -- surrogate pairs -> proper 4-byte UTF-8 (U+1F525 fire emoji)
    local s = json_decode('{"t":"hot \\\\ud83d\\\\udd25 take"}')
    eq(s.t, 'hot \\240\\159\\148\\165 take', 'emoji surrogate pair')

    -- BMP escape still works (U+00E9 e-acute)
    eq(json_decode('{"t":"\\\\u00e9"}').t, '\\195\\169', 'BMP escape')

    -- unpaired high surrogate does not crash the decoder
    local lone = json_decode('{"t":"x\\\\ud83dy"}')
    assert(type(lone.t) == 'string', 'lone surrogate survives')

    -- nested structures, booleans, numbers
    local nested = json_decode('{"p":{"id":"abc","n":1.5},"list":[{"x":true},{"x":false}]}')
    eq(nested.p.id, 'abc', 'nested obj')
    eq(nested.p.n, 1.5, 'float')
    eq(nested.list[2].x, false, 'bool false kept')

    -- ---- JSON encoder ----------------------------------------------------
    eq(json_encode({body = 'a"b'}), '{"body":"a\\\\"b"}', 'encode escapes quote')
    eq(json_encode({1,2,3}), '[1,2,3]', 'encode array')

    -- ---- safe_url --------------------------------------------------------
    assert(safe_url('https://x.supabase.co/storage/v1/object/sign/a%20b.wav?token=eyJh.bGciOi&expires=3600'), 'presigned ok')
    assert(safe_url('http://localhost:3000/api'), 'plain http ok')
    eq(safe_url('https://x.co/a$(rm -rf ~).wav'), nil, 'reject dollar')
    eq(safe_url('https://x.co/a\\96id\\96.wav'), nil, 'reject backtick')
    eq(safe_url('https://x.co/a\\nb'), nil, 'reject newline')
    eq(safe_url('https://x.co/a b'), nil, 'reject space')
    eq(safe_url("https://x.co/a'b"), nil, 'reject squote')
    eq(safe_url('file:///etc/passwd'), nil, 'reject non-http scheme')
    eq(safe_url(nil), nil, 'reject nil')

    -- ---- safe_filename ---------------------------------------------------
    eq(safe_filename('Kick 01 (final).wav'), 'Kick 01 (final).wav', 'normal name kept')
    eq(safe_filename('x$(curl evil).wav'), 'x_(curl evil).wav', 'dollar scrubbed')
    eq(safe_filename('a\\nb.wav'), 'a_b.wav', 'newline scrubbed')
    eq(safe_filename('..\\\\..\\\\win.ini'), '.._.._win.ini', 'path traversal scrubbed')
    eq(safe_filename(nil), 'file', 'nil -> file')

    -- ---- fmt_bytes -------------------------------------------------------
    eq(fmt_bytes(0), '0 B', 'zero bytes')
    eq(fmt_bytes(512), '512 B', 'bytes')
    eq(fmt_bytes(4096), '4 KB', 'kilobytes')
    eq(fmt_bytes(5 * 1024 * 1024), '5.0 MB', 'megabytes')
    eq(fmt_bytes(13002342), '12.4 MB', 'fractional MB')
    eq(fmt_bytes(2 * 1024 * 1024 * 1024), '2.00 GB', 'gigabytes')
    eq(fmt_bytes(nil), '0 B', 'nil -> 0 B')

    -- ---- version_newer ---------------------------------------------------
    eq(version_newer('0.7.0', '0.6.8'), true, 'minor bump newer')
    eq(version_newer('0.6.8', '0.7.0'), false, 'older not newer')
    eq(version_newer('0.6.8', '0.6.8'), false, 'equal not newer')
    eq(version_newer('0.10.0', '0.9.9'), true, 'numeric not lexicographic')
    eq(version_newer('1.0', '0.9.9'), true, 'major beats longer')
    eq(version_newer('0.7', '0.7.0'), false, 'short form equal')
    eq(version_newer(nil, '1.0'), false, 'nil never newer')
    eq(version_newer('abc', '1.0'), false, 'garbage never newer')

    return 'ALL TESTS PASSED'
  `;
  try {
    console.log(await lua.doString(harness));
  } catch (e) {
    console.error('TEST FAIL:', e.message);
    process.exit(1);
  } finally {
    lua.global.close();
  }
})();
