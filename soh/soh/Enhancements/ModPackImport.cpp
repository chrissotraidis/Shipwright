#include "ModPackImport.h"
#include <zip.h>
#ifdef INCLUDE_MPQ_SUPPORT
#include <StormLib.h>
#endif
#include <algorithm>
#include <array>
#include <fstream>
#include <memory>
#include <stdexcept>

namespace ModPackImport {
namespace fs = std::filesystem;
namespace {
constexpr uint64_t MaxBytes = 16ULL * 1024 * 1024 * 1024;
constexpr uint64_t MaxResourceBytes = 256ULL * 1024 * 1024;
constexpr uint64_t MaxEntries = 100000;
using Zip = std::unique_ptr<zip_t, decltype(&zip_discard)>;
std::string Extension(const fs::path& path) {
    auto ext = path.extension().string();
    std::transform(ext.begin(), ext.end(), ext.begin(), [](unsigned char c) { return std::tolower(c); });
    return ext;
}
bool Pack(const fs::path& path) {
    return Extension(path) == ".o2r"
#ifdef INCLUDE_MPQ_SUPPORT
        || Extension(path) == ".otr"
#endif
        ;
}
Zip OpenZip(const fs::path& path) {
    Zip zip(zip_open(path.string().c_str(), ZIP_RDONLY | ZIP_CHECKCONS, nullptr), zip_discard);
    if (!zip || zip_get_num_entries(zip.get(), 0) <= 0 ||
        static_cast<uint64_t>(zip_get_num_entries(zip.get(), 0)) > MaxEntries)
        throw std::runtime_error("Invalid, empty or oversized archive.");
    return zip;
}
void ValidateArchive(const fs::path& path) {
    if (fs::file_size(path) > MaxBytes) throw std::runtime_error("Pack exceeds the 16 GiB import limit.");
    if (Extension(path) == ".o2r") {
        auto zip = OpenZip(path);
        uint64_t total = 0;
        for (zip_int64_t i = 0; i < zip_get_num_entries(zip.get(), 0); ++i) {
            zip_stat_t entry;
            if (zip_stat_index(zip.get(), i, 0, &entry) || !entry.name || !entry.name[0] ||
                entry.encryption_method != ZIP_EM_NONE || entry.size > MaxResourceBytes ||
                entry.size > MaxBytes - total)
                throw std::runtime_error("Encrypted or oversized pack content is unsupported.");
            total += entry.size;
        }
    }
#ifdef INCLUDE_MPQ_SUPPORT
    else if (Extension(path) == ".otr") {
        HANDLE archive = nullptr;
        if (!SFileOpenArchive(path.string().c_str(), 0, MPQ_OPEN_READ_ONLY, &archive))
            throw std::runtime_error("Invalid OTR archive.");
        bool valid = false;
        HANDLE list = nullptr;
        // The selected runtime dereferences (listfile) when opening OTRs.
        // Merely opening an arbitrary MPQ is not sufficient validation.
        if (SFileOpenFileEx(archive, "(listfile)", 0, &list)) {
            DWORD high = 0;
            DWORD size = SFileGetFileSize(list, &high);
            if (!high && size > 0 && size <= MaxResourceBytes) {
                std::array<char, 64 * 1024> buffer;
                uint64_t readTotal = 0;
                DWORD bytes = 0;
                while (SFileReadFile(list, buffer.data(), buffer.size(), &bytes, nullptr)) readTotal += bytes;
                readTotal += bytes;
                valid = readTotal == size;
            }
            SFileCloseFile(list);
        }
        SFILE_FIND_DATA entry;
        HANDLE search = SFileFindFirstFile(archive, "*", &entry, nullptr);
        uint64_t total = 0, entries = 0;
        if (search) {
            do {
                if (++entries > MaxEntries || entry.dwFileSize > MaxResourceBytes ||
                    entry.dwFileSize > MaxBytes - total) { valid = false; break; }
                total += entry.dwFileSize;
            } while (SFileFindNextFile(search, &entry));
            SFileFindClose(search);
        } else valid = false;
        SFileCloseArchive(archive);
        if (!valid) throw std::runtime_error("OTR has no readable file list or exceeds resource limits.");
    }
#endif
    else throw std::runtime_error("Choose a SoH .o2r or .otr pack, or a ZIP containing packs. Extract .7z first.");
}
}
void Validate(const fs::path& input) { ValidateArchive(input); }
size_t Import(const fs::path& input, const fs::path& destination) {
    // The caller chooses an unused destination. Exclusive creation protects existing data.
    if (!fs::create_directory(destination)) throw std::runtime_error("Import destination already exists.");
    try {
        size_t count = 0;
        if (Extension(input) == ".zip") {
            auto zip = OpenZip(input);
            uint64_t total = 0;
            for (zip_int64_t i = 0; i < zip_get_num_entries(zip.get(), 0); ++i) {
                zip_stat_t entry;
                if (zip_stat_index(zip.get(), i, 0, &entry)) throw std::runtime_error("Unreadable ZIP entry.");
                const fs::path relative(entry.name);
                if (relative.empty() || relative.is_absolute() || relative.string().find('\\') != std::string::npos)
                    throw std::runtime_error("Unsafe ZIP entry path.");
                for (const auto& part : relative)
                    if (part == ".." || part == ".") throw std::runtime_error("Unsafe ZIP entry path.");
                if (!Pack(relative)) continue; // Documentation and unrelated files stay outside the app.
                if (entry.encryption_method != ZIP_EM_NONE || entry.size > MaxBytes - total)
                    throw std::runtime_error("Encrypted or oversized ZIP content is unsupported.");
                total += entry.size;
                const auto output = destination / relative;
                fs::create_directories(output.parent_path());
                if (fs::exists(output)) throw std::runtime_error("ZIP contains duplicate pack paths.");
                std::unique_ptr<zip_file_t, decltype(&zip_fclose)> file(zip_fopen_index(zip.get(), i, 0), zip_fclose);
                if (!file) throw std::runtime_error("Cannot read packed archive.");
                std::ofstream stream(output, std::ios::binary);
                std::array<char, 64 * 1024> buffer;
                uint64_t written = 0;
                while (true) {
                    auto bytes = zip_fread(file.get(), buffer.data(), buffer.size());
                    if (bytes < 0) throw std::runtime_error("Corrupt ZIP content.");
                    if (!bytes) break;
                    written += bytes;
                    if (written > entry.size) throw std::runtime_error("ZIP size mismatch.");
                    stream.write(buffer.data(), bytes);
                    if (!stream) throw std::runtime_error("Cannot save pack. Check available storage.");
                }
                stream.close();
                if (!stream || written != entry.size) throw std::runtime_error("Incomplete ZIP content.");
                Validate(output);
                ++count;
            }
        } else {
            Validate(input);
            fs::copy_file(input, destination / input.filename());
            ++count;
        }
        if (!count) throw std::runtime_error("No supported SoH packs found. Extract .7z downloads first.");
        return count;
    } catch (...) {
        std::error_code ignored;
        fs::remove_all(destination, ignored); // Only the exclusively created staging directory.
        throw;
    }
}
}
