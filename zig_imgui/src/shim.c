// Acesso a campos de structs do ImGui que o translate-c do Zig nao consegue traduzir
// (ImGuiIO e ImGuiListClipper apontam para ImGuiContext, que vira opaco por ter bitfields).
#define CIMGUI_DEFINE_ENUMS_AND_STRUCTS
#include "cimgui.h"

void shim_io_setup(void) {
    ImGuiIO *io = igGetIO_Nil();
    io->IniFilename = NULL; // nao grava imgui.ini no diretorio atual
    io->ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;
}

// --capture: sem mouse nenhum (nem o real) e tela do tamanho do quadro que vai para o PNG
void shim_capture_setup(void) {
    igGetIO_Nil()->ConfigFlags |= ImGuiConfigFlags_NoMouse;
}

void shim_capture_frame(float w, float h) {
    ImGuiIO *io = igGetIO_Nil();
    io->DisplaySize.x = w;
    io->DisplaySize.y = h;
    io->DisplayFramebufferScale.x = 1;
    io->DisplayFramebufferScale.y = 1;
}

ImFont *shim_add_font(const char *path, float size_pixels) {
    return ImFontAtlas_AddFontFromFileTTF(igGetIO_Nil()->Fonts, path, size_pixels, NULL, NULL);
}

// Caracteres que a fonte da interface nao tem vem de outra fonte, juntada a ela (MergeMode): a Segoe UI nao tem a
// estrela U+2605 das favoritas nem as setas U+25B6/U+25C0 das paginas, a Segoe UI Symbol tem. So os caracteres de
// `ranges` (pares inicio-fim terminados em 0, memoria de quem chama, que dura o programa todo) vem da outra fonte.
ImFont *shim_merge_glyphs(const char *path, float size_pixels, const ImWchar *ranges) {
    ImFontConfig *cfg = ImFontConfig_ImFontConfig();
    cfg->MergeMode = true;
    cfg->GlyphRanges = ranges;
    ImFont *font = ImFontAtlas_AddFontFromFileTTF(igGetIO_Nil()->Fonts, path, size_pixels, cfg, NULL);
    ImFontConfig_destroy(cfg);
    return font;
}

void shim_clipper_range(const ImGuiListClipper *clipper, int *start, int *end) {
    *start = clipper->DisplayStart;
    *end = clipper->DisplayEnd;
}

// --capture: tecla simulada (o teste do Esc na pergunta de saida)
void shim_key(int key, bool down) {
    ImGuiIO_AddKeyEvent(igGetIO_Nil(), (ImGuiKey)key, down);
}
