#ifndef TM_STORAGE_SUPPORT_H
#define TM_STORAGE_SUPPORT_H
#include <stdint.h>
#include <wchar.h>
int tm_file_info(const wchar_t *path, int64_t *size, int64_t *mtime, int64_t *identity);
int tm_same_file(const wchar_t *left, const wchar_t *right);
int tm_protect_path(const wchar_t *path, int directory);
int tm_create_private_directory(const wchar_t *path);
int tm_reserve_private_file(const wchar_t *path);
int tm_replace_file(const wchar_t *source, const wchar_t *destination);
void tm_kill_process(uint32_t pid);
#endif
