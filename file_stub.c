/* moondb native 文件后端桥(仅 native target 编译)。
 * MoonBit String 在 native ABI 上是 UTF-16 码元裸指针,Bytes 是字节裸指针;
 * 长度由 MoonBit 侧显式传入。句柄为 int32(窄化的 FILE*)。
 *
 * moonbit_make_bytes_raw 由 native 运行时提供(符号在链接期解析),
 * 返回的指针由 MoonBit GC 接管,这里不释放。 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#if defined(_WIN32)
#include <windows.h>
#endif

extern uint8_t *moonbit_make_bytes_raw(int32_t size);

static FILE *handle_to_file(int64_t h) {
  return (FILE *)(intptr_t)h;
}

/* UTF-16 路径 → 平台路径:Windows 直接宽字符;POSIX 转 UTF-8。 */
#if defined(_WIN32)
static int path_to_native(const uint16_t *src, int32_t units, wchar_t *dst, int cap) {
  if (units <= 0 || units >= cap) {
    return -1;
  }
  for (int32_t i = 0; i < units; i++) {
    dst[i] = (wchar_t)src[i];
  }
  dst[units] = 0;
  return 0;
}
#else
static int utf16_to_utf8(const uint16_t *src, int32_t units, char *dst, int cap) {
  int out = 0;
  for (int32_t i = 0; i < units; i++) {
    uint32_t cp = src[i];
    if (cp >= 0xD800 && cp <= 0xDBFF && i + 1 < units) {
      uint32_t lo = src[i + 1];
      if (lo >= 0xDC00 && lo <= 0xDFFF) {
        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
        i++;
      } else {
        return -1;
      }
    }
    if (cp < 0x80) {
      if (out + 1 >= cap) return -1;
      dst[out++] = (char)cp;
    } else if (cp < 0x800) {
      if (out + 2 >= cap) return -1;
      dst[out++] = (char)(0xC0 | (cp >> 6));
      dst[out++] = (char)(0x80 | (cp & 0x3F));
    } else if (cp < 0x10000) {
      if (out + 3 >= cap) return -1;
      dst[out++] = (char)(0xE0 | (cp >> 12));
      dst[out++] = (char)(0x80 | ((cp >> 6) & 0x3F));
      dst[out++] = (char)(0x80 | (cp & 0x3F));
    } else {
      if (out + 4 >= cap) return -1;
      dst[out++] = (char)(0xF0 | (cp >> 18));
      dst[out++] = (char)(0x80 | ((cp >> 12) & 0x3F));
      dst[out++] = (char)(0x80 | ((cp >> 6) & 0x3F));
      dst[out++] = (char)(0x80 | (cp & 0x3F));
    }
  }
  dst[out] = 0;
  return out;
}

static int path_to_native(const uint16_t *src, int32_t units, char *dst, int cap) {
  return utf16_to_utf8(src, units, dst, cap);
}
#endif

#if defined(_WIN32)
typedef wchar_t path_char_t;
#define MDB_FOPEN_APPEND L"a+b"
#define MDB_FOPEN_WRITE L"wb"
#define MDB_FOPEN_READ L"rb"
static FILE *mdb_fopen(const path_char_t *p, const wchar_t *mode) {
  return _wfopen(p, mode);
}
static int mdb_rename(const path_char_t *from, const path_char_t *to) {
  /* Windows rename 不覆盖已存在文件;merge 的原子替换需要覆盖语义 */
  return MoveFileExW(from, to, MOVEFILE_REPLACE_EXISTING) ? 0 : -1;
}
static int mdb_remove(const path_char_t *p) {
  return _wremove(p);
}
#else
typedef char path_char_t;
#define MDB_FOPEN_APPEND "a+b"
#define MDB_FOPEN_WRITE "wb"
#define MDB_FOPEN_READ "rb"
static FILE *mdb_fopen(const path_char_t *p, const char *mode) {
  return fopen(p, mode);
}
static int mdb_rename(const path_char_t *from, const path_char_t *to) {
  return rename(from, to);
}
static int mdb_remove(const path_char_t *p) {
  return remove(p);
}
#endif

int64_t moondb_file_open(const uint16_t *path, int32_t path_units) {
  path_char_t native[1040];
  if (path_to_native(path, path_units, native, 1024) < 0) {
    return -1;
  }
  /* 追加读写:存在则保留内容,不存在则创建 */
  FILE *f = mdb_fopen(native, MDB_FOPEN_APPEND);
  if (!f) {
    return -1;
  }
  return (int64_t)(intptr_t)f;
}

int64_t moondb_file_append(int64_t h, const uint8_t *data, int32_t data_len) {
  FILE *f = handle_to_file(h);
  if (!f || data_len < 0) {
    return -1;
  }
  if (data_len == 0) {
    return 0;
  }
  size_t wrote = fwrite(data, 1, (size_t)data_len, f);
  fflush(f);
  return wrote == (size_t)data_len ? 0 : -1;
}

int64_t moondb_file_size(int64_t h) {
  FILE *f = handle_to_file(h);
  if (!f) {
    return -1;
  }
  long cur = ftell(f);
  if (cur < 0) {
    return -1;
  }
  if (fseek(f, 0, SEEK_END) != 0) {
    return -1;
  }
  long end = ftell(f);
  if (fseek(f, cur, SEEK_SET) != 0) {
    return -1;
  }
  return (int32_t)end;
}

/* 读全部内容:len 为预期大小;返回 moonbit bytes(失败返回 NULL)。 */
uint8_t *moondb_file_read_all(int64_t h, int32_t len) {
  FILE *f = handle_to_file(h);
  if (!f || len <= 0) {
    return NULL;
  }
  if (fseek(f, 0, SEEK_SET) != 0) {
    return NULL;
  }
  uint8_t *buf = moonbit_make_bytes_raw(len);
  if (!buf) {
    return NULL;
  }
  size_t got = fread(buf, 1, (size_t)len, f);
  if (got != (size_t)len) {
    return NULL;
  }
  /* 恢复追加位置:读不影响写游标,但保持清晰 */
  fseek(f, 0, SEEK_END);
  return buf;
}

int64_t moondb_file_truncate(int64_t h, int32_t keep_bytes) {
  FILE *f = handle_to_file(h);
  if (!f || keep_bytes < 0) {
    return -1;
  }
  fflush(f);
#if defined(_WIN32)
  if (_chsize_s(fileno(f), (int64_t)keep_bytes) != 0) {
    return -1;
  }
#else
  if (ftruncate(fileno(f), (off_t)keep_bytes) != 0) {
    return -1;
  }
#endif
  return 0;
}

/* 原子替换:写临时文件(路径 + ".tmp")→ rename 覆盖 → 重开句柄。
 * 任一时刻磁盘上是完整的旧日志或完整的新日志。返回新句柄。 */
int64_t moondb_file_replace_all(
    int64_t h,
    const uint8_t *data,
    int32_t data_len,
    const uint16_t *path,
    int32_t path_units) {
  if (!handle_to_file(h) || path_units <= 0 || path_units >= 1000 || data_len < 0) {
    return -1;
  }
  path_char_t native[1024];
  path_char_t tmp[1040];
  if (path_to_native(path, path_units, native, 1024) < 0) {
    return -1;
  }
  int base = 0;
  while (native[base] != 0) {
    base++;
  }
  for (int i = 0; i < base; i++) {
    tmp[i] = native[i];
  }
#if defined(_WIN32)
  tmp[base] = L'.';
  tmp[base + 1] = L't';
  tmp[base + 2] = L'm';
  tmp[base + 3] = L'p';
  tmp[base + 4] = 0;
#else
  tmp[base] = '.';
  tmp[base + 1] = 't';
  tmp[base + 2] = 'm';
  tmp[base + 3] = 'p';
  tmp[base + 4] = 0;
#endif
  FILE *out = mdb_fopen(tmp, MDB_FOPEN_WRITE);
  if (!out) {
    return -1;
  }
  if (data_len > 0) {
    size_t wrote = fwrite(data, 1, (size_t)data_len, out);
    if (wrote != (size_t)data_len) {
      fclose(out);
      mdb_remove(tmp);
      return -1;
    }
  }
  if (fflush(out) != 0) {
    fclose(out);
    mdb_remove(tmp);
    return -1;
  }
  fclose(out);
  /* 先关旧句柄:Windows 上打开中的文件无法被 rename 覆盖(共享冲突) */
  fclose(handle_to_file(h));
  if (mdb_rename(tmp, native) != 0) {
    mdb_remove(tmp);
    /* rename 失败:重开原文件保持句柄语义(内容未变,数据安全) */
    FILE *back = mdb_fopen(native, MDB_FOPEN_APPEND);
    if (!back) {
      return -1;
    }
    return (int64_t)(intptr_t)back;
  }
  FILE *fresh = mdb_fopen(native, MDB_FOPEN_APPEND);
  if (!fresh) {
    return -1;
  }
  return (int64_t)(intptr_t)fresh;
}

void moondb_file_sync(int64_t h) {
  FILE *f = handle_to_file(h);
  if (f) {
    fflush(f);
  }
}

void moondb_file_close(int64_t h) {
  FILE *f = handle_to_file(h);
  if (f) {
    fclose(f);
  }
}

/* 测试辅助:删除文件(尽力而为)。 */
int32_t moondb_test_remove(const uint16_t *path, int32_t path_units) {
  path_char_t native[1040];
  if (path_to_native(path, path_units, native, 1024) < 0) {
    return -1;
  }
  return mdb_remove(native);
}
