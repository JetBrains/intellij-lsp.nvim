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

M.version = '271.2085.0'

M.url_template =
  'https://download.jetbrains.com/language-server/intellij-server/{version}/intellij-server-{version}{arch_suffix}.{ext}'

--- The archive extension per OS.
M.ext = { macos = 'sit', linux = 'tar.gz', windows = 'win.zip' }

--- The archive name suffix per architecture.
M.arch_suffix = { aarch64 = '-aarch64', x86_64 = '' }

--- The size of each archive in bytes, keyed by OS and then by architecture. Drives the progress
--- percentage; a wrong value only skews the percentage, the checksum still guards the content.
M.size = {
  macos = { aarch64 = 385899733, x86_64 = 387873566 },
  linux = { aarch64 = 394206359, x86_64 = 395255755 },
  windows = { aarch64 = 368571128, x86_64 = 389022064 },
}

--- The SHA-256 of each archive, lowercase hex, keyed by OS and then by architecture.
M.sha256 = {
  macos = {
    aarch64 = '0b8022627f20cdbe52508afbd5dcb3a6e18afc170fb84d8f70d92ad87b815a78',
    x86_64 = '860e9ab04b99640790112a96de7f7df024b28bf3d6b573e5102a1a627b8e4a8e',
  },
  linux = {
    aarch64 = 'ba6d0831043c197edede20518e3137974bc53838ef6601e71c23ff785070fc34',
    x86_64 = 'fb4fbac78a5043ce568e8b93ec57a1c40c4ba8136db68139d8813d7de3a4f7e4',
  },
  windows = {
    aarch64 = 'b8cab4d3e30849440fe4d318c352981012ffb9b3895b2ceda1f73e430407274f',
    x86_64 = '9ab4ecd982a8abdfaa1fff1bcdd4246db2d071653168c78555a5869271ee3f9f',
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
