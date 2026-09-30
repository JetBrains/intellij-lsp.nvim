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

M.version = '263.4702.0'

M.url_template =
  'https://download.jetbrains.com/language-server/intellij-server/{version}/intellij-server-{version}{arch_suffix}.{ext}'

--- The archive extension per OS.
M.ext = { macos = 'sit', linux = 'tar.gz', windows = 'win.zip' }

--- The archive name suffix per architecture.
M.arch_suffix = { aarch64 = '-aarch64', x86_64 = '' }

--- The size of each archive in bytes, keyed by OS and then by architecture. Drives the progress
--- percentage; a wrong value only skews the percentage, the checksum still guards the content.
M.size = {
  macos = { aarch64 = 375711022, x86_64 = 377667719 },
  linux = { aarch64 = 383007338, x86_64 = 383998550 },
  windows = { aarch64 = 358588582, x86_64 = 378972709 },
}

--- The SHA-256 of each archive, lowercase hex, keyed by OS and then by architecture.
M.sha256 = {
  macos = {
    aarch64 = '117a914cbd1c3b8e2d0808429d9a85106ba78d10af34adb34f9daa927e13fbfb',
    x86_64 = '978cc7aacb6896e36513013215919d947a994edfbb4ad15e0c1cafef48730057',
  },
  linux = {
    aarch64 = '6e92f58b60e9d9eec3c2fbcd64fd9641166497b8e94f053a5f4cc14ccef2220e',
    x86_64 = '8fa7964736d42e44952d1fea7a5478a3bc6e80e271039ee62a6db6c40fe95970',
  },
  windows = {
    aarch64 = '93724efd26bec14d890fc9dea223e17ebcb155f3c23d352e5bac22f7c9dc2d80',
    x86_64 = 'e69854033db9de8ea132ff4a8451d33f34abc3d1b90778587fc6040582b990da',
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
