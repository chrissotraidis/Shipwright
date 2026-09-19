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
constexpr zip_int64_t MaxEntries = 100000;
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
        zip_get_num_entries(zip.get(), 0) > MaxEntries)
        throw std::runtime_error("Invalid, empty or oversized archive.");
    return zip;
}
void Validate(const fs::path& path) {
    if (fs::file_size(path) > MaxBytes) throw std::runtime_error("Pack exceeds the 16 GiB import limit.");
    if (Extension(path) == ".o2r") {
        auto zip = OpenZip(path);
        uint64_t total = 0;
        for (zip_int64_t i = 0; i < zip_get_num_entries(zip.get(), 0); ++i) {
            zip_stat_t entry;
            if (zip_stat_index(zip.get(), i, 0, &entry) || entry.encryption_method != ZIP_EM_NONE ||
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
        SFileCloseArchive(archive);
    }
#endif
    else throw std::runtime_error("Choose a SoH .o2r or .otr pack, or a ZIP containing packs. Extract .7z first.");
}
}
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
