// TEST: a C++ file for run.sh to time the compilation of; it is never run

#include <nlohmann/json.hpp>

#include <algorithm>
#include <iostream>
#include <map>
#include <regex>
#include <sstream>
#include <string>
#include <vector>

using json = nlohmann::json;

struct Entry {
    std::string name;
    int id;
    std::vector<double> values;
    std::map<std::string, std::string> tags;
};
NLOHMANN_DEFINE_TYPE_NON_INTRUSIVE(Entry, name, id, values, tags)

int main(int argc, char **argv) {
    std::regex re(argc > 1 ? argv[1] : "([a-z]+)-(\\d+)");
    std::vector<Entry> entries;
    for (std::string line; std::getline(std::cin, line);) {
        auto e = json::parse(line).get<Entry>();
        std::smatch m;
        if (std::regex_search(e.name, m, re))
            e.tags[m[1]] = m[2];
        entries.push_back(std::move(e));
    }
    std::sort(entries.begin(), entries.end(),
              [](const Entry &a, const Entry &b) { return a.id < b.id; });
    std::ostringstream os;
    os << json(entries).dump(2);
    std::cout << os.str() << '\n';
}
