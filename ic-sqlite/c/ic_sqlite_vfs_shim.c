#include "ic_sqlite_vfs_shim.h"

#include <stddef.h>
#include <string.h>

/* Every function below is exported by Nim with {.exportc, cdecl.}. */
#define IC_WEAK __attribute__((weak))
extern int nim_icvfs_open(const char *, int, uint32_t *, int *) IC_WEAK;
extern int nim_icvfs_close(uint32_t) IC_WEAK;
extern int nim_icvfs_read(uint32_t, void *, int, sqlite3_int64) IC_WEAK;
extern int nim_icvfs_write(uint32_t, const void *, int, sqlite3_int64) IC_WEAK;
extern int nim_icvfs_truncate(uint32_t, sqlite3_int64) IC_WEAK;
extern int nim_icvfs_file_size(uint32_t, sqlite3_int64 *) IC_WEAK;
extern int nim_icvfs_lock(uint32_t, int) IC_WEAK;
extern int nim_icvfs_unlock(uint32_t, int) IC_WEAK;
extern int nim_icvfs_check_reserved_lock(uint32_t, int *) IC_WEAK;
extern int nim_icvfs_randomness(void *, int) IC_WEAK;
extern int nim_icvfs_current_time(double *) IC_WEAK;
extern int nim_icvfs_last_error(char *, int) IC_WEAK;

static int ic_xClose(sqlite3_file *file) {
  IcFile *f = (IcFile *)file;
  int rc = nim_icvfs_close(f->handle_id);
  f->handle_id = 0;
  f->base.pMethods = NULL;
  return rc;
}
static int ic_xRead(sqlite3_file *file, void *buf, int amount, sqlite3_int64 off) {
  return nim_icvfs_read(((IcFile *)file)->handle_id, buf, amount, off);
}
static int ic_xWrite(sqlite3_file *file, const void *buf, int amount, sqlite3_int64 off) {
  return nim_icvfs_write(((IcFile *)file)->handle_id, buf, amount, off);
}
static int ic_xTruncate(sqlite3_file *file, sqlite3_int64 size) {
  return nim_icvfs_truncate(((IcFile *)file)->handle_id, size);
}
static int ic_xSync(sqlite3_file *file, int flags) {
  (void)file; (void)flags;
  return SQLITE_OK; /* Durable publish is performed after COMMIT by Nim. */
}
static int ic_xFileSize(sqlite3_file *file, sqlite3_int64 *size) {
  return nim_icvfs_file_size(((IcFile *)file)->handle_id, size);
}
static int ic_xLock(sqlite3_file *file, int lock) {
  return nim_icvfs_lock(((IcFile *)file)->handle_id, lock);
}
static int ic_xUnlock(sqlite3_file *file, int lock) {
  return nim_icvfs_unlock(((IcFile *)file)->handle_id, lock);
}
static int ic_xCheckReservedLock(sqlite3_file *file, int *reserved) {
  return nim_icvfs_check_reserved_lock(((IcFile *)file)->handle_id, reserved);
}
static int ic_xFileControl(sqlite3_file *file, int op, void *arg) {
  (void)file; (void)op; (void)arg;
  return SQLITE_NOTFOUND;
}
static int ic_xSectorSize(sqlite3_file *file) {
  (void)file;
  return 4096;
}
static int ic_xDeviceCharacteristics(sqlite3_file *file) {
  (void)file;
  return 0;
}

static const sqlite3_io_methods IC_IO_METHODS = {
  1, ic_xClose, ic_xRead, ic_xWrite, ic_xTruncate, ic_xSync, ic_xFileSize,
  ic_xLock, ic_xUnlock, ic_xCheckReservedLock, ic_xFileControl,
  ic_xSectorSize, ic_xDeviceCharacteristics,
  NULL, NULL, NULL, NULL, NULL, NULL
};

static int ic_xOpen(sqlite3_vfs *vfs, const char *name, sqlite3_file *file,
                    int flags, int *out_flags) {
  IcFile *f = (IcFile *)file;
  uint32_t handle_id = 0;
  int rc;
  (void)vfs;
  memset(f, 0, sizeof(*f));
  rc = nim_icvfs_open(name, flags, &handle_id, out_flags);
  if (rc == SQLITE_OK) {
    f->handle_id = handle_id;
    f->base.pMethods = &IC_IO_METHODS;
  }
  return rc;
}
static int ic_xDelete(sqlite3_vfs *vfs, const char *name, int sync_dir) {
  (void)vfs; (void)name; (void)sync_dir;
  return SQLITE_OK; /* Main DB deletion is intentionally not exposed. */
}
static int ic_xAccess(sqlite3_vfs *vfs, const char *name, int flags, int *out) {
  (void)vfs; (void)name; (void)flags;
  *out = 0;
  return SQLITE_OK;
}
static int ic_xFullPathname(sqlite3_vfs *vfs, const char *name, int n_out, char *out) {
  size_t len;
  (void)vfs;
  if (name == NULL) name = "";
  len = strlen(name);
  if (len + 1 > (size_t)n_out) return SQLITE_CANTOPEN;
  memcpy(out, name, len + 1);
  return SQLITE_OK;
}
static void *ic_xDlOpen(sqlite3_vfs *vfs, const char *name) {
  (void)vfs; (void)name; return NULL;
}
static void ic_xDlError(sqlite3_vfs *vfs, int n, char *out) {
  (void)vfs; if (n > 0) out[0] = '\0';
}
static void (*ic_xDlSym(sqlite3_vfs *vfs, void *h, const char *sym))(void) {
  (void)vfs; (void)h; (void)sym; return NULL;
}
static void ic_xDlClose(sqlite3_vfs *vfs, void *h) { (void)vfs; (void)h; }
static int ic_xRandomness(sqlite3_vfs *vfs, int n, char *out) {
  (void)vfs; return nim_icvfs_randomness(out, n);
}
static int ic_xSleep(sqlite3_vfs *vfs, int microseconds) {
  (void)vfs; return microseconds;
}
static int ic_xCurrentTime(sqlite3_vfs *vfs, double *time) {
  (void)vfs; return nim_icvfs_current_time(time);
}
static int ic_xGetLastError(sqlite3_vfs *vfs, int n, char *out) {
  (void)vfs; return nim_icvfs_last_error(out, n);
}

sqlite3_vfs IC_VFS = {
  1, sizeof(IcFile), 1024, NULL, "icstable", NULL,
  ic_xOpen, ic_xDelete, ic_xAccess, ic_xFullPathname,
  ic_xDlOpen, ic_xDlError, ic_xDlSym, ic_xDlClose,
  ic_xRandomness, ic_xSleep, ic_xCurrentTime, ic_xGetLastError,
  NULL, NULL, NULL, NULL
};

int ic_sqlite_register_vfs(void) { return sqlite3_vfs_register(&IC_VFS, 1); }
int sqlite3_os_init(void) { return ic_sqlite_register_vfs(); }
int sqlite3_os_end(void) { return SQLITE_OK; }
