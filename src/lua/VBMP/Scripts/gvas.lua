-- Minimal GVAS (UE SaveGame file) splicer: swap whole top-level properties between two saves
-- without understanding their contents.
--
-- Format (verified on LimaSaveGame.sav, UE 5.7.4, 2026-11-05; research/phase3-07-worldsync.md):
--   header: "GVAS", int32 SaveGameFileVersion (3), int32 UE4 ver, int32 UE5 ver, engine version
--     (u16 major, u16 minor, u16 patch, u32 changelist, FString branch), int32 custom-version
--     format, int32 count + count * (16-byte guid + int32), FString save class, uint8 (0)
--   then top-level property tags until the name "None":
--     FString name, type name tree (FString name + int32 child count, children recursively),
--     int32 value size, uint8 flags (1: int32 array index follows, 2: 16-byte guid follows;
--     0x10 = bool value for BoolProperty, which has size 0), then `size` value bytes
--   then whatever follows "None" (kept from the base file)
-- FString: int32 n; n > 0: n bytes incl. NUL (latin-1); n < 0: -n UTF-16 code units incl. NUL.

local M = {}

local function fstr(b, p)
    local n = string.unpack("<i4", b, p)
    p = p + 4
    if n == 0 then return "", p end
    if n > 0 then return b:sub(p, p + n - 2), p + n end
    return "?utf16", p - 2 * n
end

local function typename(b, p)
    local _
    _, p = fstr(b, p)
    local kids = string.unpack("<i4", b, p)
    p = p + 4
    for _ = 1, kids do p = typename(b, p) end
    return p
end

-- Returns { propsStart, props = { { name, from, to } }, noneAt } or nil, err.
function M.parse(b)
    if type(b) ~= "string" or b:sub(1, 4) ~= "GVAS" then return nil, "not GVAS" end
    local ok, res = pcall(function()
        local p = 5
        local ver = string.unpack("<i4", b, p); p = p + 4
        p = p + 4                                   -- UE4 package version
        if ver >= 3 then p = p + 4 end              -- UE5 package version
        p = p + 2 + 2 + 2 + 4                       -- engine version numbers
        local _; _, p = fstr(b, p)                  -- branch
        p = p + 4                                   -- custom version format
        local n = string.unpack("<i4", b, p); p = p + 4 + n * 20
        _, p = fstr(b, p)                           -- save game class
        p = p + 1                                   -- uint8 (0)
        local r = { propsStart = p, props = {} }
        while true do
            local from = p
            local name
            name, p = fstr(b, p)
            if name == "None" then r.noneAt = from; return r end
            p = typename(b, p)
            local size = string.unpack("<i4", b, p); p = p + 4
            local flags = string.unpack("<B", b, p); p = p + 1
            if flags & 1 ~= 0 then p = p + 4 end
            if flags & 2 ~= 0 then p = p + 16 end
            p = p + size
            if p > #b + 1 then error("property " .. name .. " runs past the end") end
            table.insert(r.props, { name = name, from = from, to = p - 1 })
        end
    end)
    if not ok then return nil, tostring(res) end
    return res
end

-- base with every property named in `names` (a set) replaced by donor's (or removed when the
-- donor has none - default values are not written). Returns bytes, kept, taken or nil, err.
function M.splice(base, donor, names)
    local pb, e1 = M.parse(base)
    if not pb then return nil, "base: " .. e1 end
    local pd, e2 = M.parse(donor)
    if not pd then return nil, "donor: " .. e2 end
    local out = { base:sub(1, pb.propsStart - 1) }
    local kept, taken = 0, 0
    for _, pr in ipairs(pb.props) do
        if not names[pr.name] then table.insert(out, base:sub(pr.from, pr.to)); kept = kept + 1 end
    end
    for _, pr in ipairs(pd.props) do
        if names[pr.name] then table.insert(out, donor:sub(pr.from, pr.to)); taken = taken + 1 end
    end
    table.insert(out, base:sub(pb.noneAt))
    return table.concat(out), kept, taken
end

return M
