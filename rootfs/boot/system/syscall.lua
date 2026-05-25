-- Linux Syscall FFI bindings for LJOS
-- Lives at /boot/system/syscall.lua

local ffi = require("ffi")

ffi.cdef[[
    typedef int32_t  pid_t;
    typedef uint32_t mode_t;
    typedef long     off_t;
    typedef uint64_t dev_t;
    typedef uint64_t ino_t;
    typedef uint64_t nlink_t;
    typedef uint32_t uid_t;
    typedef uint32_t gid_t;

    struct stat {
        dev_t     st_dev;
        ino_t     st_ino;
        mode_t    st_mode;
        nlink_t   st_nlink;
        uid_t     st_uid;
        gid_t     st_gid;
        dev_t     st_rdev;
        off_t     st_size;
        long      st_blksize;
        long      st_blocks;
        long      st_atime;
        long      st_atime_nsec;
        long      st_mtime;
        long      st_mtime_nsec;
        long      st_ctime;
        long      st_ctime_nsec;
    };

    int fork(void);
    int execvp(const char *file, char *const argv[]);
    int execv(const char *path, char *const argv[]);
    pid_t waitpid(pid_t pid, int *wstatus, int options);
    
    int chdir(const char *path);
    char *getcwd(char *buf, size_t size);
    
    int open(const char *pathname, int flags, ...);
    int close(int fd);
    ssize_t read(int fd, void *buf, size_t count);
    ssize_t write(int fd, const void *buf, size_t count);
    
    int mkdir(const char *pathname, mode_t mode);
    int rmdir(const char *pathname);
    int unlink(const char *pathname);
    int rename(const char *oldpath, const char *newpath);
    
    int mount(const char *source, const char *target,
              const char *filesystemtype, unsigned long mountflags,
              const void *data);
    int umount(const char *target);

    int pipe(int pipefd[2]);
    int dup2(int oldfd, int newfd);

    int ioctl(int fd, unsigned long request, ...);
    void *mmap(void *addr, size_t length, int prot, int flags, int fd, off_t offset);
    int munmap(void *addr, size_t length);
    
    int setenv(const char *name, const char *value, int overwrite);
    
    struct linux_dirent64 {
        uint64_t        d_ino;
        int64_t         d_off;
        unsigned short  d_reclen;
        unsigned char   d_type;
        char            d_name[];
    };
    int getdents64(unsigned int fd, struct linux_dirent64 *dirp, unsigned int count);

    int reboot(int magic, int magic2, int cmd, void *arg);
    
    pid_t getpid(void);

    typedef struct DIR DIR;
    struct dirent {
        uint64_t        d_ino;
        int64_t         d_off;
        unsigned short  d_reclen;
        unsigned char   d_type;
        char            d_name[256];
    };
    DIR *opendir(const char *name);
    struct dirent *readdir(DIR *dirp);
    int closedir(DIR *dirp);

    typedef void (*sighandler_t)(int);
    sighandler_t signal(int signum, sighandler_t handler);
    int kill(pid_t pid, int sig);

    int *__errno_location(void);
    char *strerror(int errnum);
]]

local C = ffi.C
local M = {}

M.PROT_READ  = 0x1
M.PROT_WRITE = 0x2
M.MAP_SHARED = 0x01

function M.errno()
    return C.__errno_location()[0]
end

function M.strerror(err)
    err = err or M.errno()
    return ffi.string(C.strerror(err))
end

-- Wrap functions to handle errors more "Lua-ishly"
local function wrap(name)
    local fn = C[name]
    M[name] = function(...)
        local ret = fn(...)
        if ret == -1 then
            return nil, M.strerror()
        end
        return ret
    end
end

for _, name in ipairs({
    "fork", "chdir", "open", "close", "read", "write", 
    "mkdir", "rmdir", "unlink", "rename", "mount", "umount",
    "pipe", "dup2", "waitpid", "ioctl", "munmap", "reboot", "getpid"
}) do
    wrap(name)
end

-- Special case for mmap
function M.mmap(addr, length, prot, flags, fd, offset)
    local res = C.mmap(addr, length, prot, flags, fd, offset)
    if res == ffi.cast("void*", -1) then
        return nil, M.strerror()
    end
    return res
end

-- Special case for getcwd
function M.getcwd()
    local buf = ffi.new("char[4096]")
    local res = C.getcwd(buf, 4096)
    if res == nil then return nil, M.strerror() end
    return ffi.string(res)
end

-- Special case for execvp (needs array of strings)
function M.execvp(file, args)
    local n = #args
    local argv = ffi.new("char*[?]", n + 1)
    for i = 1, n do
        argv[i-1] = ffi.cast("char*", args[i])
    end
    argv[n] = nil
    C.execvp(file, argv)
    -- If we are here, exec failed
    return nil, M.strerror()
end

return M
