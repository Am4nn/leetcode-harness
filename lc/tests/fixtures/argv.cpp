#include <cstdio>
// Writes argv[2..] to the file named by argv[1], one per line.
int main(int argc, char** argv) {
    std::FILE* f = std::fopen(argv[1], "wb");
    for (int i = 2; i < argc; i++) std::fprintf(f, "%s\n", argv[i]);
    std::fclose(f);
}
