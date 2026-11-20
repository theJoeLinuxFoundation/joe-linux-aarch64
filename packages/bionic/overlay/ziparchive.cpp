// libziparchive, as far as bionic's dynamic linker uses it, for a system
// without APKs: no file is a zip archive, so a library path of the form
// "archive.zip!/lib.so" is not found, as on Android when the archive is not
// a zip file. See the libziparchive module in Android.bp.

#include <ziparchive/zip_archive.h>

// kInvalidFile in libziparchive's zip_error.h.
static constexpr int32_t kNotAZipFile = -3;

int32_t OpenArchiveFd(const int, const char*, ZipArchiveHandle* handle, bool) {
  *handle = nullptr;
  return kNotAZipFile;
}

void CloseArchive(ZipArchiveHandle) {}

int32_t FindEntry(const ZipArchiveHandle, const std::string_view, ZipEntry*) {
  return kNotAZipFile;
}

int32_t FindEntry(const ZipArchiveHandle, const std::string_view, ZipEntry64*) {
  return kNotAZipFile;
}
