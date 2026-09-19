#pragma once
#include <filesystem>
#include <string>

namespace ModPackImport {
// Copies into a new batch directory; never replaces existing packs. Throws on failure.
size_t Import(const std::filesystem::path& input, const std::filesystem::path& destination);
}
