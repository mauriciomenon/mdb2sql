// Acesso a campos de structs do ImGui que o translate-c do Zig nao consegue traduzir
// (ImGuiIO e ImGuiListClipper apontam para ImGuiContext, que vira opaco por ter bitfields).
#define CIMGUI_DEFINE_ENUMS_AND_STRUCTS
#include "cimgui.h"

void shim_io_setup(void) {
    ImGuiIO *io = igGetIO_Nil();
    io->IniFilename = NULL; // nao grava imgui.ini no diretorio atual
    io->ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;
}

void shim_add_font(const char *path, float size_pixels) {
    ImFontAtlas_AddFontFromFileTTF(igGetIO_Nil()->Fonts, path, size_pixels, NULL, NULL);
}

void shim_clipper_range(const ImGuiListClipper *clipper, int *start, int *end) {
    *start = clipper->DisplayStart;
    *end = clipper->DisplayEnd;
}
