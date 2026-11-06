#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <aclapi.h>
#include <stdlib.h>
#include <wchar.h>
#include "StorageSupport.h"

/* An explicit protected ACL prevents broad inherited grants on both new and
   existing stores. Directory ACEs also protect SQLite's WAL/journal children. */
static int private_security(SECURITY_DESCRIPTOR *descriptor, PACL *acl) {
    HANDLE token = NULL;
    DWORD bytes = 0;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return 0;
    GetTokenInformation(token, TokenUser, NULL, 0, &bytes);
    TOKEN_USER *user = (TOKEN_USER *)malloc(bytes);
    if (!user) { CloseHandle(token); return 0; }
    int ok = GetTokenInformation(token, TokenUser, user, bytes, &bytes);
    if (ok) {
        EXPLICIT_ACCESSW access = {0};
        access.grfAccessPermissions = FILE_ALL_ACCESS;
        access.grfAccessMode = SET_ACCESS;
        access.grfInheritance = SUB_CONTAINERS_AND_OBJECTS_INHERIT;
        access.Trustee.TrusteeForm = TRUSTEE_IS_SID;
        access.Trustee.TrusteeType = TRUSTEE_IS_USER;
        access.Trustee.ptstrName = (LPWSTR)user->User.Sid;
        ok = SetEntriesInAclW(1, &access, NULL, acl) == ERROR_SUCCESS;
        if (ok) ok = InitializeSecurityDescriptor(descriptor, SECURITY_DESCRIPTOR_REVISION)
            && SetSecurityDescriptorDacl(descriptor, TRUE, *acl, FALSE)
            && SetSecurityDescriptorControl(descriptor, SE_DACL_PROTECTED, SE_DACL_PROTECTED);
    }
    free(user);
    CloseHandle(token);
    return ok;
}

int tm_protect_path(const wchar_t *path, int directory) {
    (void)directory;
    SECURITY_DESCRIPTOR descriptor;
    PACL acl = NULL;
    if (!private_security(&descriptor, &acl)) { if (acl) LocalFree(acl); return 0; }
    DWORD result = SetNamedSecurityInfoW((LPWSTR)path, SE_FILE_OBJECT,
        DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
        NULL, NULL, acl, NULL);
    LocalFree(acl);
    return result == ERROR_SUCCESS;
}

int tm_create_private_directory(const wchar_t *path) {
    SECURITY_DESCRIPTOR descriptor;
    PACL acl = NULL;
    if (!private_security(&descriptor, &acl)) { if (acl) LocalFree(acl); return 0; }
    SECURITY_ATTRIBUTES attributes = {sizeof(attributes), &descriptor, FALSE};
    int ok = CreateDirectoryW(path, &attributes);
    DWORD error = GetLastError();
    LocalFree(acl);
    if (!ok && error != ERROR_ALREADY_EXISTS) return 0;
    DWORD flags = GetFileAttributesW(path);
    return flags != INVALID_FILE_ATTRIBUTES && (flags & FILE_ATTRIBUTE_DIRECTORY)
        && tm_protect_path(path, 1);
}

int tm_reserve_private_file(const wchar_t *path) {
    SECURITY_DESCRIPTOR descriptor;
    PACL acl = NULL;
    if (!private_security(&descriptor, &acl)) { if (acl) LocalFree(acl); return 0; }
    SECURITY_ATTRIBUTES attributes = {sizeof(attributes), &descriptor, FALSE};
    HANDLE file = CreateFileW(path, GENERIC_READ | GENERIC_WRITE, 0, &attributes,
        CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL);
    LocalFree(acl);
    if (file == INVALID_HANDLE_VALUE) return 0;
    return CloseHandle(file) != 0;
}

static HANDLE open_metadata(const wchar_t *path) {
    return CreateFileW(path, FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, NULL);
}

int tm_file_info(const wchar_t *path, int64_t *size, int64_t *mtime, int64_t *identity) {
    HANDLE file = open_metadata(path);
    if (file == INVALID_HANDLE_VALUE) return 0;
    BY_HANDLE_FILE_INFORMATION info;
    int ok = GetFileInformationByHandle(file, &info);
    CloseHandle(file);
    if (!ok) return 0;
    *size = (int64_t)(((uint64_t)info.nFileSizeHigh << 32) | info.nFileSizeLow);
    /* 100ns ticks since 1601 -> nanoseconds since Unix epoch. */
    uint64_t ticks = ((uint64_t)info.ftLastWriteTime.dwHighDateTime << 32)
        | info.ftLastWriteTime.dwLowDateTime;
    *mtime = (int64_t)(ticks - 116444736000000000ULL) * 100;
    uint64_t index = ((uint64_t)info.nFileIndexHigh << 32) | info.nFileIndexLow;
    /* Persist a stable 64-bit identity including the volume. */
    *identity = (int64_t)(index ^ ((uint64_t)info.dwVolumeSerialNumber * 0x9e3779b97f4a7c15ULL));
    return 1;
}

int tm_same_file(const wchar_t *left, const wchar_t *right) {
    HANDLE a = open_metadata(left), b = open_metadata(right);
    BY_HANDLE_FILE_INFORMATION ia, ib;
    int same = a != INVALID_HANDLE_VALUE && b != INVALID_HANDLE_VALUE
        && GetFileInformationByHandle(a, &ia) && GetFileInformationByHandle(b, &ib)
        && ia.dwVolumeSerialNumber == ib.dwVolumeSerialNumber
        && ia.nFileIndexHigh == ib.nFileIndexHigh && ia.nFileIndexLow == ib.nFileIndexLow;
    if (a != INVALID_HANDLE_VALUE) CloseHandle(a);
    if (b != INVALID_HANDLE_VALUE) CloseHandle(b);
    return same;
}

int tm_replace_file(const wchar_t *source, const wchar_t *destination) {
    /* Same-volume rename only: no copy/delete fallback or exposed partial file.
       MoveFileEx replaces existing files atomically, including a racing creator. */
    return MoveFileExW(source, destination, MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != 0;
}

void tm_kill_process(uint32_t pid) {
    HANDLE process = OpenProcess(PROCESS_TERMINATE, FALSE, pid);
    if (process) { TerminateProcess(process, 1); CloseHandle(process); }
}
