--- The published `intellij-server` bundles, one per platform.
---
--- JetBrains publishes one archive per OS and CPU architecture. The x86_64 archive carries no
--- architecture suffix; only the aarch64 one does. The extension names the OS: `.sit` for macOS,
--- `.tar.gz` for Linux, `.win.zip` for Windows. Both `.sit` and `.win.zip` are zip archives.
---
--- To move to a new server version, change `version`, replace every `sha256` value with the
--- content of the `.sha256` file that sits next to each archive on the CDN, and update `size` from
--- the `Content-Length` of each archive.

local M = {}

M.version = '263.6379.0'

M.url_template =
  'https://download.jetbrains.com/language-server/intellij-server/{version}/intellij-server-{version}{arch_suffix}.{ext}'

--- The archive extension per OS.
M.ext = { macos = 'sit', linux = 'tar.gz', windows = 'win.zip' }

--- The archive name suffix per architecture.
M.arch_suffix = { aarch64 = '-aarch64', x86_64 = '' }

--- The size of each archive in bytes, keyed by OS and then by architecture. Drives the progress
--- percentage; a wrong value only skews the percentage, the checksum still guards the content.
M.size = {
  macos = { aarch64 = 378400162, x86_64 = 380357704 },
  linux = { aarch64 = 385692577, x86_64 = 386687696 },
  windows = { aarch64 = 361248514, x86_64 = 381634830 },
}

--- The SHA-256 of each archive, lowercase hex, keyed by OS and then by architecture.
M.sha256 = {
  macos = {
    aarch64 = '443157ce085dae947637594ab883692fa7e952ae0c7d0baa6eb917fc91cabdd1',
    x86_64 = 'e5fff8dfa0af523db053bb9cad46529f862116616e1e0d7b2cbaed032eddef15',
  },
  linux = {
    aarch64 = '7b50afa2d6f08cbd9dc39ccd9bf89c03bb37ff256e25243fc229cf8ec10354ea',
    x86_64 = '7529cc733d4a020e1c1369183b2f60e135c85b8f074bbf27d1476a5a7b3839c3',
  },
  windows = {
    aarch64 = 'dd160805fbec807c4c9c414f04b67457ec441fd3e3d70bd1a85c321d4b8efbb2',
    x86_64 = '270d02e08268129022ea5a379ce747f04d91a679213614c597361a7a6d0df41d',
  },
}

--- The bundle for one platform.
--- @param os 'macos'|'linux'|'windows'
--- @param arch 'aarch64'|'x86_64'
--- @return table|nil bundle {url, version, sha256, size}
--- @return string|nil error
function M.bundle(os, arch)
  local ext = M.ext[os]
  local suffix = M.arch_suffix[arch]
  local sha256 = M.sha256[os] and M.sha256[os][arch]
  if not ext or not suffix or not sha256 then
    return nil, ('no intellij-server bundle for %s/%s'):format(tostring(os), tostring(arch))
  end

  local url = M.url_template
    :gsub('{version}', M.version)
    :gsub('{arch_suffix}', suffix)
    :gsub('{ext}', ext)
  return { url = url, version = M.version, sha256 = sha256, size = M.size[os] and M.size[os][arch] }, nil
end

return M
