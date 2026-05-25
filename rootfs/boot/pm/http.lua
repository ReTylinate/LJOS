-- HTTP client for ljpm on LJOS
-- Uses busybox wget (already in /bin/) for downloads.
-- Pure-Lua TCP socket (FFI) is used for plain HTTP GETs.
-- Lives at /boot/pm/http.lua
--
-- Strategy:
--   HTTP  → pure LuaJIT FFI socket (no external tools for simple GETs)
--   HTTPS → busybox wget (busybox TLS not always available; fall back gracefully)
--   Downloads → busybox wget -O (most reliable across environments)

local ffi = require("ffi")
local http = {}

-- ─── FFI Declarations (POSIX sockets for plain HTTP) ─────────────────────────

ffi.cdef[[
  typedef unsigned int  socklen_t;
  typedef int           ssize_t;
  typedef unsigned long size_t;

  struct addrinfo {
    int              ai_flags;
    int              ai_family;
    int              ai_socktype;
    int              ai_protocol;
    socklen_t        ai_addrlen;
    void            *ai_addr;
    char            *ai_canonname;
    struct addrinfo *ai_next;
  };
  int getaddrinfo(const char *node, const char *service,
                  const struct addrinfo *hints, struct addrinfo **res);
  void freeaddrinfo(struct addrinfo *res);
  const char *gai_strerror(int ecode);

  int socket(int domain, int type, int protocol);
  int connect(int sockfd, const void *addr, socklen_t addrlen);
  ssize_t send(int sockfd, const void *buf, size_t len, int flags);
  ssize_t recv(int sockfd, void *buf, size_t len, int flags);
  int close(int fd);

  int *__errno_location(void);
  char *strerror(int errnum);
]]

local C         = ffi.C
local AF_INET   = 2
local SOCK_STREAM = 1

local function _strerror()
  return ffi.string(C.strerror(C.__errno_location()[0]))
end

-- ─── URL Parser ──────────────────────────────────────────────────────────────

function http.parse_url(url)
  local scheme = url:match("^(%a[%w%+%-%.]*)://") or "http"
  local rest   = url:match("^%a[%w%+%-%.]*://(.+)$") or url
  local host, path = rest:match("^([^/]+)(/.*)$")
  if not host then host=rest; path="/" end
  local h, p = host:match("^(.+):(%d+)$")
  local port
  if h then host=h; port=tonumber(p)
  elseif scheme=="https" then port=443
  else port=80 end
  return {scheme=scheme:lower(), host=host, port=port, path=path}
end

-- ─── Plain HTTP GET via FFI socket ───────────────────────────────────────────

local function tcp_get(host, port, path, timeout)
  timeout = timeout or 30

  -- Resolve + connect
  local hints = ffi.new("struct addrinfo")
  hints.ai_family   = AF_INET
  hints.ai_socktype = SOCK_STREAM
  local res = ffi.new("struct addrinfo*[1]")
  local rc = C.getaddrinfo(host, tostring(port), hints, res)
  if rc ~= 0 then
    return nil, "DNS: "..ffi.string(C.gai_strerror(rc))
  end
  local ai = res[0]

  local sock = C.socket(AF_INET, SOCK_STREAM, 0)
  if sock < 0 then C.freeaddrinfo(ai); return nil, "socket: ".._strerror() end

  if C.connect(sock, ai.ai_addr, ai.ai_addrlen) ~= 0 then
    C.close(sock); C.freeaddrinfo(ai)
    return nil, "connect "..host..":"..port..": ".._strerror()
  end
  C.freeaddrinfo(ai)

  -- Send request
  local req = string.format(
    "GET %s HTTP/1.1\r\nHost: %s\r\nUser-Agent: ljpm/1.0\r\nConnection: close\r\nAccept: */*\r\n\r\n",
    path, host
  )
  local ptr, sent = ffi.cast("const void*", req), 0
  while sent < #req do
    local n = C.send(sock, req:sub(sent+1), #req-sent, 0)
    if n <= 0 then C.close(sock); return nil, "send: ".._strerror() end
    sent = sent + n
  end

  -- Receive response
  local buf   = ffi.new("char[65536]")
  local chunks = {}
  while true do
    local n = C.recv(sock, buf, 65536, 0)
    if n <= 0 then break end
    chunks[#chunks+1] = ffi.string(buf, n)
  end
  C.close(sock)

  local raw = table.concat(chunks)

  -- Parse headers
  local hend = raw:find("\r\n\r\n", 1, true)
  if not hend then return nil, "Malformed HTTP response" end
  local hdr_block = raw:sub(1, hend-1)
  local body      = raw:sub(hend+4)

  local status = tonumber(hdr_block:match("^HTTP/%S+ (%d+)"))
  local headers = {}
  for line in hdr_block:gmatch("\r\n([^\r\n]+)") do
    local k,v = line:match("^([^:]+):%s*(.+)$")
    if k then headers[k:lower()] = v end
  end

  -- Decode chunked transfer
  if (headers["transfer-encoding"] or ""):lower():find("chunked") then
    local out, pos = {}, 1
    while pos <= #body do
      local nl = body:find("\r\n", pos, true)
      if not nl then break end
      local chunk_sz = tonumber(body:sub(pos, nl-1):match("^%s*(%x+)"), 16)
      if not chunk_sz or chunk_sz == 0 then break end
      pos = nl + 2
      out[#out+1] = body:sub(pos, pos+chunk_sz-1)
      pos = pos + chunk_sz + 2
    end
    body = table.concat(out)
  end

  return {status=status, headers=headers, body=body}
end

-- ─── Wget-based fetcher (for HTTPS or as fallback) ───────────────────────────

local function wget_get(url, out_file)
  local cmd
  if out_file then
    cmd = string.format("wget -q -O %s %s 2>/dev/null", fs_quote(out_file), fs_quote(url))
  else
    cmd = string.format("wget -q -O - %s 2>/dev/null", fs_quote(url))
  end
  local p = io.popen(cmd, "r")
  if not p then return nil, "Cannot run wget" end
  local out = p:read("*a")
  local ok = p:close()
  -- ok is exit code in Lua 5.1/LuaJIT, or true/nil, "exit", code in 5.2+
  local exit_ok = (ok == true or ok == 0)

  if not exit_ok then
    return nil, "wget failed with exit code " .. tostring(ok or "unknown")
  end

  if out_file then
    return {status=200, body="", headers={}}
  end
  return {status=200, body=out, headers={}}
end

-- Shell-safe quoting (local to this module, no fs dep needed here)
function fs_quote(path)
  return "'" .. tostring(path):gsub("'","'\\''") .. "'"
end

-- ─── Public API ──────────────────────────────────────────────────────────────

-- Fetch a URL, returns {status, headers, body} or nil, err
-- Follows up to 5 redirects automatically.
function http.get(url, opts)
  opts = opts or {}
  local max_redir = opts.max_redirects or 5

  for _ = 0, max_redir do
    local u = http.parse_url(url)

    local resp, err
    if u.scheme == "https" then
      -- HTTPS: use wget
      resp, err = wget_get(url)
    else
      resp, err = tcp_get(u.host, u.port, u.path, opts.timeout)
    end

    if not resp then return nil, err end

    -- Follow redirect
    if resp.status >= 300 and resp.status < 400 then
      local loc = resp.headers["location"]
      if not loc then return nil, "Redirect with no Location" end
      if loc:sub(1,1) == "/" then
        loc = u.scheme.."://"..u.host..":"..u.port..loc
      elseif not loc:match("^%a+://") then
        loc = u.scheme.."://"..u.host..":"..u.port.."/"..loc
      end
      url = loc
    else
      return resp
    end
  end
  return nil, "Too many redirects"
end

-- Download a URL directly to a file path.
function http.download(url, dest_path, progress_cb)
  local u = http.parse_url(url)
  -- Try wget with --show-progress first
  local cmd = string.format(
    "wget -q --show-progress -O %s %s 2>/dev/null",
    fs_quote(dest_path), fs_quote(url)
  )
  local ok = os.execute(cmd)
  
  if ok ~= 0 then
    -- Try without --show-progress (Busybox wget often doesn't have it)
    cmd = string.format(
      "wget -q -O %s %s 2>/dev/null",
      fs_quote(dest_path), fs_quote(url)
    )
    ok = os.execute(cmd)
  end

  if ok == 0 then
    return true
  end

  -- wget failed or not available? try HTTP GET (only for plain HTTP)
  if u.scheme == "http" then
    local resp, err = http.get(url)
    if not resp then return false, err end
    if resp.status ~= 200 then return false, "HTTP "..resp.status end
    -- Write body to file
    local f, ferr = io.open(dest_path, "wb")
    if not f then return false, "Cannot write "..dest_path..": "..(ferr or "") end
    f:write(resp.body)
    f:close()
    return true
  end

  return false, "Download failed (wget exit code "..tostring(ok)..")"
end

return http
