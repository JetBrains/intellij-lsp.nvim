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

M.version = '263.7084.0'

M.url_template =
  'https://download.jetbrains.com/language-server/intellij-server/{version}/intellij-server-{version}{arch_suffix}.{ext}'

--- The archive extension per OS.
M.ext = { macos = 'sit', linux = 'tar.gz', windows = 'win.zip' }

--- The archive name suffix per architecture.
M.arch_suffix = { aarch64 = '-aarch64', x86_64 = '' }

--- The size of each archive in bytes, keyed by OS and then by architecture. Drives the progress
--- percentage; a wrong value only skews the percentage, the checksum still guards the content.
M.size = {
  macos = { aarch64 = 378499345, x86_64 = 380456870 },
  linux = { aarch64 = 385782431, x86_64 = 386777831 },
  windows = { aarch64 = 361354713, x86_64 = 381741020 },
}

--- The SHA-256 of each archive, lowercase hex, keyed by OS and then by architecture.
M.sha256 = {
  macos = {
    aarch64 = 'ea728da71e3511939b4cb8e4af4aa5e4dda6e0ab7c2bdd1830a5d110bdf2bbec',
    x86_64 = '3b31cd867ce0e361bfc763ba78cf4fa1dcb1a5324b97c817a0ec045532278420',
  },
  linux = {
    aarch64 = 'd5df0980acc4eeb35b1e76227caa62639fcda188649064d17b5b0de1077b38c0',
    x86_64 = '3842f2f457e29e58cd9c37a97482b28255d598a2ff142075753d947206c0b922',
  },
  windows = {
    aarch64 = '2ce197ad10684d55334c5611433c1479ccb574e52d78e41d023e3f2dd0be4704',
    x86_64 = 'd84629cbdd79d58f021a15a75f05018518398906519a0e830df6f8a8d515e286',
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
