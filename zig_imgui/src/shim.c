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
    ImFontConfig *cfg = ImFontConfig_ImFontConfig();
    // FreeType (build.zig) com o hinting da propria fonte, glifo no pixel inteiro e 1.3x mais encorpado: o mais
    // proximo do texto nativo do Windows entre as variantes comparadas em captura (o stb_truetype borrava os tracos)
    cfg->PixelSnapH = true;
    cfg->RasterizerMultiply = 1.3f;
    ImFont *font = ImFontAtlas_AddFontFromFileTTF(igGetIO_Nil()->Fonts, path, size_pixels, cfg, NULL);
    ImFontConfig_destroy(cfg); // o atlas guarda uma copia
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
