#pragma once
#include <algorithm>
#include <filesystem>
#include <map>
#include <string>
#include <vector>

namespace ModCatalog {
// Relative paths distinguish packs with identical stems without storing sandbox identities.
struct Selection {
    std::vector<std::string> enabled;
    std::vector<std::string> disabled;
};
inline Selection Reconcile(const std::map<std::string, std::filesystem::path>& files,
                           const Selection& saved, bool legacy) {
    Selection result;
    auto contains = [](const auto& values, const auto& value) {
        return std::find(values.begin(), values.end(), value) != values.end();
    };
    std::vector<std::string> seen;
    for (const auto& id : saved.enabled) {
        if (contains(seen, id)) continue;
        seen.push_back(id);
        for (const auto& [key, path] : files) {
            if ((legacy ? path.stem().string() == id : key == id) &&
                !contains(result.enabled, key)) {
                result.enabled.push_back(key);
                break; // An ambiguous legacy stem selects only one deterministic pack.
            }
        }
    }
    for (const auto& [key, path] : files) {
        if (contains(result.enabled, key)) continue;
        // Keep existing installations' first migration behavior. Subsequent new packs need opt-in.
        bool ambiguousLegacy = legacy && contains(saved.enabled, path.stem().string());
        if (legacy && !ambiguousLegacy) result.enabled.push_back(key);
        else result.disabled.push_back(key);
    }
    return result;
}
}
