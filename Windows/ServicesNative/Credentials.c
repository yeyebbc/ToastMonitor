#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <wincred.h>
#include <wincrypt.h>
#include <stdlib.h>
#include <wchar.h>
#include <string.h>
#include "WindowsServicesNative.h"

// Every value stays inside Credential Manager. Random generation names let a write
// commit atomically by replacing only the small root manifest after all chunks exist.
#define MAX_SECRET_BYTES (1024u * 1024u)
typedef struct {
    unsigned char magic[8];
    DWORD length;
    unsigned char generation[16];
} CredentialManifest;
static const unsigned char manifest_magic[8] = {'T','M','C','R',1,0,0,0};
static SRWLOCK credential_lock = SRWLOCK_INIT;

static wchar_t *target_name(const wchar_t *account, const CredentialManifest *manifest, DWORD index) {
    size_t n = wcslen(account);
    if (n > CRED_MAX_GENERIC_TARGET_NAME_LENGTH - 64) return NULL;
    size_t capacity = n + 64;
    wchar_t *target = calloc(capacity, sizeof(wchar_t));
    if (!target) return NULL;
    wcscpy_s(target, capacity, L"ToastMonitor/");
    wcscat_s(target, capacity, account);
    if (manifest) {
        wchar_t suffix[48];
        wchar_t *cursor = suffix;
        *cursor++ = L'/';
        for (int i = 0; i < 16; i++) {
            static const wchar_t hex[] = L"0123456789abcdef";
            *cursor++ = hex[manifest->generation[i] >> 4];
            *cursor++ = hex[manifest->generation[i] & 15];
        }
        swprintf_s(cursor, 15, L"/%lu", (unsigned long)index);
        wcscat_s(target, capacity, suffix);
    }
    return target;
}
static DWORD write_blob(const wchar_t *target, const unsigned char *data, DWORD length) {
    CREDENTIALW credential = {0};
    credential.Type = CRED_TYPE_GENERIC;
    credential.TargetName = (wchar_t *)target;
    credential.UserName = L"ToastMonitor";
    credential.CredentialBlob = (LPBYTE)data;
    credential.CredentialBlobSize = length;
    credential.Persist = CRED_PERSIST_LOCAL_MACHINE;
    return CredWriteW(&credential, 0) ? ERROR_SUCCESS : GetLastError();
}
static DWORD read_manifest(const wchar_t *target, CredentialManifest *manifest, int *missing) {
    *missing = 0;
    PCREDENTIALW value = NULL;
    if (!CredReadW(target, CRED_TYPE_GENERIC, 0, &value)) {
        DWORD error = GetLastError();
        if (error == ERROR_NOT_FOUND) *missing = 1;
        return error;
    }
    DWORD result = ERROR_INVALID_DATA;
    if (value->CredentialBlobSize == sizeof(*manifest)) {
        memcpy(manifest, value->CredentialBlob, sizeof(*manifest));
        if (!memcmp(manifest->magic, manifest_magic, sizeof(manifest_magic)) && manifest->length <= MAX_SECRET_BYTES)
            result = ERROR_SUCCESS;
    }
    CredFree(value);
    return result;
}
static DWORD chunk_count(const CredentialManifest *manifest) {
    return (manifest->length + CRED_MAX_CREDENTIAL_BLOB_SIZE - 1) / CRED_MAX_CREDENTIAL_BLOB_SIZE;
}
static DWORD remove_chunks(const wchar_t *account, const CredentialManifest *manifest, DWORD count) {
    DWORD result = ERROR_SUCCESS;
    for (DWORD i = 0; i < count; i++) {
        wchar_t *target = target_name(account, manifest, i);
        if (!target) return ERROR_NOT_ENOUGH_MEMORY;
        if (!CredDeleteW(target, CRED_TYPE_GENERIC, 0)) {
            DWORD error = GetLastError();
            if (error != ERROR_NOT_FOUND) result = error;
        }
        free(target);
    }
    return result;
}
uint32_t tm_credential_read(const wchar_t *account, unsigned char **data, uint32_t *length, int *missing) {
    *data = NULL; *length = 0; *missing = 0;
    wchar_t *root = target_name(account, NULL, 0);
    if (!root) return ERROR_INVALID_PARAMETER;
    AcquireSRWLockShared(&credential_lock);
    CredentialManifest manifest;
    DWORD result = read_manifest(root, &manifest, missing);
    unsigned char *bytes = NULL;
    if (result != ERROR_SUCCESS) goto done;
    bytes = malloc(manifest.length ? manifest.length : 1);
    if (!bytes) { result = ERROR_NOT_ENOUGH_MEMORY; goto done; }
    DWORD offset = 0;
    for (DWORD i = 0; i < chunk_count(&manifest); i++) {
        wchar_t *target = target_name(account, &manifest, i);
        if (!target) { result = ERROR_NOT_ENOUGH_MEMORY; goto done; }
        PCREDENTIALW value = NULL;
        BOOL ok = CredReadW(target, CRED_TYPE_GENERIC, 0, &value);
        result = ok ? ERROR_SUCCESS : GetLastError();
        free(target);
        if (!ok) {
            if (result == ERROR_NOT_FOUND) result = ERROR_INVALID_DATA;
            goto done;
        }
        DWORD expected = min(manifest.length - offset, CRED_MAX_CREDENTIAL_BLOB_SIZE);
        if (value->CredentialBlobSize != expected) { CredFree(value); result = ERROR_INVALID_DATA; goto done; }
        memcpy(bytes + offset, value->CredentialBlob, expected);
        offset += expected;
        CredFree(value);
    }
    *data = bytes; *length = manifest.length; bytes = NULL;
done:
    if (bytes) { SecureZeroMemory(bytes, manifest.length); free(bytes); }
    ReleaseSRWLockShared(&credential_lock);
    free(root);
    return result;
}
uint32_t tm_credential_write(const wchar_t *account, const unsigned char *data, uint32_t length) {
    if (length > MAX_SECRET_BYTES) return ERROR_BAD_LENGTH;
    wchar_t *root = target_name(account, NULL, 0);
    if (!root) return ERROR_INVALID_PARAMETER;
    AcquireSRWLockExclusive(&credential_lock);
    CredentialManifest old;
    int missing = 0;
    DWORD previous = read_manifest(root, &old, &missing);
    DWORD result = previous;
    if (previous != ERROR_SUCCESS && previous != ERROR_NOT_FOUND) goto done;
    CredentialManifest manifest = {0};
    memcpy(manifest.magic, manifest_magic, sizeof(manifest_magic));
    manifest.length = length;
    HCRYPTPROV provider;
    if (!CryptAcquireContextW(&provider, NULL, NULL, PROV_RSA_FULL, CRYPT_VERIFYCONTEXT)) { result = GetLastError(); goto done; }
    BOOL random_ok = CryptGenRandom(provider, sizeof(manifest.generation), manifest.generation);
    result = random_ok ? ERROR_SUCCESS : GetLastError();
    CryptReleaseContext(provider, 0);
    if (!random_ok) goto done;
    DWORD count = chunk_count(&manifest), written = 0, offset = 0;
    for (; written < count; written++) {
        wchar_t *target = target_name(account, &manifest, written);
        if (!target) { result = ERROR_NOT_ENOUGH_MEMORY; break; }
        DWORD size = min(length - offset, CRED_MAX_CREDENTIAL_BLOB_SIZE);
        result = write_blob(target, data + offset, size);
        free(target);
        if (result != ERROR_SUCCESS) break;
        offset += size;
    }
    if (result == ERROR_SUCCESS) result = write_blob(root, (const unsigned char *)&manifest, sizeof(manifest));
    if (result != ERROR_SUCCESS) remove_chunks(account, &manifest, written);
    else if (previous == ERROR_SUCCESS) remove_chunks(account, &old, chunk_count(&old));
done:
    ReleaseSRWLockExclusive(&credential_lock);
    free(root);
    return result;
}
uint32_t tm_credential_delete(const wchar_t *account) {
    wchar_t *root = target_name(account, NULL, 0);
    if (!root) return ERROR_INVALID_PARAMETER;
    AcquireSRWLockExclusive(&credential_lock);
    CredentialManifest manifest;
    int missing = 0;
    DWORD result = read_manifest(root, &manifest, &missing);
    if (result == ERROR_SUCCESS) {
        result = remove_chunks(account, &manifest, chunk_count(&manifest));
        if (result == ERROR_SUCCESS && !CredDeleteW(root, CRED_TYPE_GENERIC, 0)) result = GetLastError();
    }
    ReleaseSRWLockExclusive(&credential_lock);
    free(root);
    return result;
}
void tm_credential_free(unsigned char *data, uint32_t length) {
    if (data) { SecureZeroMemory(data, length); free(data); }
}
