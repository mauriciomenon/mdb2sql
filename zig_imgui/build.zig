// Build do MDB2SQL Zig + Dear ImGui (cimgui/GLFW/OpenGL3) + libduckdb (C API). Windows x64 e Linux x64 (Debian).
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const os = target.result.os.tag;
    const windows = os == .windows;

    // shortcut: only the x86_64 libduckdb of Windows and Linux are pinned in build.zig.zon; other systems and
    // architectures need their own zip there (see README-BUILD.txt)
    if (target.result.cpu.arch != .x86_64 or (os != .windows and os != .linux))
        @panic("zig_imgui builds for x86_64-windows and x86_64-linux only (pinned libduckdb)");

    // Versao: build.zig.zon e a unica fonte; chega ao codigo (janela Sobre) pelas build options.
    // Numero e data do build: passados pelos scripts de build; fora deles o Sobre mostra "build dev".
    const console = b.option(bool, "console", "Console subsystem, to see stderr (default: only in Debug)") orelse (optimize == .debug);
    const version = @import("build.zig.zon").version;
    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    options.addOption(bool, "console", console);
    options.addOption([]const u8, "build_number", b.option([]const u8, "build_number", "Build number (git rev-list --count HEAD)") orelse "");
    options.addOption([]const u8, "build_date", b.option([]const u8, "build_date", "Build date (YYYY-MM-DD)") orelse "");
    // commit completo do build (git rev-parse HEAD), na linha de versao do Sobre; vazio = "dev"
    options.addOption([]const u8, "commit", b.option([]const u8, "commit", "Full commit hash (git rev-parse HEAD)") orelse "");
    const mdbtools_version = "1.0.1"; // a mesma dos scripts de ferramentas (mostrada no Sobre)
    options.addOption([]const u8, "mdbtools_version", mdbtools_version);
    // SQLite embutido no sqlite_scanner fixado abaixo (v2.0.0): a versao gravada no arquivo (teste em about.zig)
    options.addOption([]const u8, "sqlite_version", "3.38.1");
    const build_options = options.createModule();

    // Arquivos que vao junto do programa, baixados por scripts/setup_tools.ps1 (Windows) ou
    // scripts/setup_tools_linux.sh (Linux), sha256 conferido. O mdbtools do Linux e compilado do fonte fixado.
    const sqlite_ext = b.path(if (windows) ".tools/duckdb-ext-v2.0.0/sqlite_scanner.duckdb_extension" else ".tools/duckdb-ext-v2.0.0-linux/sqlite_scanner.duckdb_extension");
    const mdbtools_dir = b.path(if (windows) ".tools/mdbtools-" ++ mdbtools_version else ".tools/mdbtools-" ++ mdbtools_version ++ "-linux");
    const mdbtools_files: []const []const u8 = if (windows)
        &.{ "mdb-tables.exe", "mdb-schema.exe", "mdb-export.exe", "COPYING", "COPYING.LIB" }
    else
        &.{ "mdb-tables", "mdb-schema", "mdb-export", "COPYING", "COPYING.LIB" };

    // libduckdb pre-compilada: duckdb.h + biblioteca (Windows: duckdb.lib + duckdb.dll; Linux: libduckdb.so)
    const duckdb = b.lazyDependency(if (windows) "libduckdb" else "libduckdb_linux", .{}) orelse return;
    const duckdb_lib_file = if (windows) "duckdb.dll" else "libduckdb.so";
    const duckdb_tc = b.addTranslateC(.{
        .root_source_file = duckdb.path("duckdb.h"),
        .target = target,
        .optimize = optimize,
    });
    // duckdb_pending_prepared_streaming (marcada obsoleta, mas e a unica que devolve resultado em fluxo na API C 2.0)
    duckdb_tc.defineCMacro("DUCKDB_API_ALLOW_DEPRECATED", "1");
    const duckdb_c = duckdb_tc.createModule();
    duckdb_c.addLibraryPath(duckdb.path(""));
    duckdb_c.linkSystemLibrary("duckdb", .{});

    // Logica sem UI (db.zig e o resto de src/ menos main/dialog/platform): usada pelo exe e pelos testes
    const core = b.createModule(.{
        .root_source_file = b.path("src/db.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{ .{ .name = "duckdb_c", .module = duckdb_c }, .{ .name = "build_options", .module = build_options } },
    });
    if (windows) core.linkSystemLibrary("odbc32", .{}); // leitor ODBC do Access (opcional, so Windows)
    core.addAnonymousImport("LICENSE", .{ .root_source_file = b.path("LICENSE") }); // so o teste da licenca le

    const zglfw = b.dependency("zglfw", .{ .target = target, .optimize = optimize });

    // Dear ImGui + cimgui (API C) + backends GLFW/OpenGL3, compilados dos fontes fixados no zon.
    // cimgui.cpp inclui "./imgui/imgui.h" (submodulo), entao montamos essa arvore no cache.
    const cimgui = b.dependency("cimgui", .{});
    const tree = b.addWriteFiles();
    _ = tree.addCopyDirectory(b.dependency("imgui", .{}).path(""), "imgui", .{ .include_extensions = &.{ ".h", ".cpp" } });
    _ = tree.addCopyFile(cimgui.path("cimgui.h"), "cimgui.h");
    _ = tree.addCopyFile(cimgui.path("cimgui_impl.h"), "cimgui_impl.h");
    _ = tree.addCopyFile(cimgui.path("cimgui.cpp"), "cimgui.cpp");
    _ = tree.addCopyFile(cimgui.path("cimgui_impl.cpp"), "cimgui_impl.cpp");
    const src = tree.getDirectory();

    const imgui_mod = b.createModule(.{ .target = target, .optimize = optimize, .link_libcpp = true });
    imgui_mod.addIncludePath(src);
    imgui_mod.addIncludePath(src.path(b, "imgui"));
    imgui_mod.addIncludePath(src.path(b, "imgui/backends"));
    imgui_mod.addIncludePath(zglfw.path("libs/glfw/include"));
    imgui_mod.addCSourceFiles(.{
        .root = src,
        .files = &.{
            "imgui/imgui.cpp",
            "imgui/imgui_draw.cpp",
            "imgui/imgui_tables.cpp",
            "imgui/imgui_widgets.cpp",
            "imgui/imgui_demo.cpp", // cimgui.cpp referencia ShowDemoWindow
            "imgui/backends/imgui_impl_glfw.cpp",
            "imgui/backends/imgui_impl_opengl3.cpp",
            "cimgui.cpp",
            "cimgui_impl.cpp",
        },
        .flags = &.{
            "-fno-sanitize=undefined",
            "-DIMGUI_IMPL_API=extern \"C\"",
            "-DIMGUI_DISABLE_OBSOLETE_FUNCTIONS=1",
            "-DCIMGUI_NO_EXPORT",
            "-DCIMGUI_USE_GLFW",
            "-DCIMGUI_USE_OPENGL3",
        },
    });
    const imgui_lib = b.addLibrary(.{ .name = "cimgui", .linkage = .static, .root_module = imgui_mod });

    const cimgui_tc = b.addTranslateC(.{ .root_source_file = cimgui.path("cimgui.h"), .target = target, .optimize = optimize });
    cimgui_tc.defineCMacro("CIMGUI_DEFINE_ENUMS_AND_STRUCTS", null);
    cimgui_tc.defineCMacro("CIMGUI_NO_EXPORT", null);

    // Linux: sem informacao de depuracao no binario do pacote (caminhos de quem compilou ficariam la)
    const strip = b.option(bool, "strip", "Strip debug info from the executable (Linux release packages)");
    const exe = b.addExecutable(.{
        .name = "mdb2sql-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
            .imports = &.{
                .{ .name = "db", .module = core },
                .{ .name = "build_options", .module = build_options },
                .{ .name = "cimgui", .module = cimgui_tc.createModule() },
                .{ .name = "zglfw", .module = zglfw.module("root") },
            },
        }),
    });
    exe.root_module.addIncludePath(cimgui.path(""));
    exe.root_module.addCSourceFile(.{ .file = b.path("src/shim.c"), .flags = &.{"-DCIMGUI_NO_EXPORT"} });
    exe.root_module.linkLibrary(imgui_lib);
    exe.root_module.linkLibrary(zglfw.artifact("glfw"));
    const icon_rc: std.Build.Module.RcSourceFile = .{ .file = b.path("assets/mdb2sql.rc"), .include_paths = &.{b.path("assets")} };
    if (windows) {
        // Sem janela de console ao abrir pelo Explorer; -Dconsole=true para ver o stderr
        exe.subsystem = if (console) .console else .windows;
        exe.root_module.linkSystemLibrary("opengl32", .{});
        // Icone do exe e da janela (mesmo .ico no executavel unico e no instalador)
        exe.root_module.addWin32ResourceFile(icon_rc);
    } else {
        // libduckdb.so fica na pasta do programa: o executavel procura ao lado dele ($ORIGIN)
        exe.root_module.addRPathSpecial("$ORIGIN");
    }
    b.installArtifact(exe);

    // Pasta do app em zig-out/bin: exe + libduckdb + extensao sqlite + mdbtools/ (tudo junto)
    const install = b.getInstallStep();
    install.dependOn(&b.addInstallBinFile(duckdb.path(duckdb_lib_file), duckdb_lib_file).step);
    install.dependOn(&b.addInstallBinFile(sqlite_ext, "sqlite_scanner.duckdb_extension").step);
    for (mdbtools_files) |f| install.dependOn(&b.addInstallBinFile(mdbtools_dir.path(b, f), b.fmt("mdbtools/{s}", .{f})).step);

    // Executavel unico (so Windows): a mesma pasta comprimida dentro de um lancador (src/launcher.zig)
    if (windows) {
        const pack = b.addExecutable(.{
            .name = "pack",
            .root_module = b.createModule(.{ .root_source_file = b.path("src/pack.zig"), .target = b.graph.host, .optimize = .ReleaseFast }),
        });
        const payload = b.addWriteFiles();
        var payload_src: std.ArrayList(u8) = .empty;
        payload_src.print(b.allocator, "pub const version = \"{s}\";\npub const files = [_]struct {{ name: []const u8, data: []const u8 }}{{\n", .{version}) catch @panic("OOM");
        const Item = struct { []const u8, std.Build.LazyPath };
        var items: std.ArrayList(Item) = .empty;
        items.appendSlice(b.allocator, &.{
            .{ "mdb2sql-zig.exe", exe.getEmittedBin() },
            .{ "duckdb.dll", duckdb.path("duckdb.dll") },
            .{ "sqlite_scanner.duckdb_extension", sqlite_ext },
        }) catch @panic("OOM");
        for (mdbtools_files) |f| items.append(b.allocator, .{ b.fmt("mdbtools\\{s}", .{f}), mdbtools_dir.path(b, f) }) catch @panic("OOM");
        for (items.items, 0..) |item, i| {
            const run_pack = b.addRunArtifact(pack);
            run_pack.addFileArg(item[1]);
            const gz = run_pack.addOutputFileArg(b.fmt("{d}.gz", .{i}));
            _ = payload.addCopyFile(gz, b.fmt("{d}.gz", .{i}));
            payload_src.print(b.allocator, "    .{{ .name = \"{f}\", .data = @embedFile(\"{d}.gz\") }},\n", .{ std.zig.fmtString(item[0]), i }) catch @panic("OOM");
        }
        payload_src.appendSlice(b.allocator, "};\n") catch @panic("OOM");
        const payload_zig = payload.add("payload.zig", payload_src.items);
        const onefile = b.addExecutable(.{
            .name = "mdb2sql-zig-onefile",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/launcher.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{.{ .name = "payload", .module = b.createModule(.{ .root_source_file = payload_zig }) }},
            }),
        });
        onefile.subsystem = .windows;
        onefile.root_module.addWin32ResourceFile(icon_rc);
        b.step("onefile", "Single-file exe (zig-out/onefile/)").dependOn(&b.addInstallArtifact(onefile, .{ .dest_dir = .{ .override = .{ .custom = "onefile" } } }).step);
    }

    const run = b.addRunArtifact(exe);
    run.step.dependOn(install);
    run.addPassthruArgs();
    b.step("run", "Run the GUI").dependOn(&run.step);

    // Testes: o exe de teste roda com cwd numa pasta do cache que tem a libduckdb, a extensao sqlite, o .mdb
    // versionado (testdata/) e o mdbtools
    const tests = b.addTest(.{ .root_module = core });
    const run_tests = b.addRunArtifact(tests);
    const dll_dir = b.addWriteFiles();
    _ = dll_dir.addCopyFile(duckdb.path(duckdb_lib_file), duckdb_lib_file);
    _ = dll_dir.addCopyFile(sqlite_ext, "sqlite_scanner.duckdb_extension");
    run_tests.setCwd(dll_dir.getDirectory());
    // Linux: o carregador nao procura no cwd sozinho; "." no LD_LIBRARY_PATH e a pasta do teste (cwd, com a .so)
    if (!windows) run_tests.setEnvironmentVariable("LD_LIBRARY_PATH", ".");
    // o .mdb versionado e o mdbtools vao para a mesma pasta (os testes os acham pelo nome)
    _ = dll_dir.addCopyFile(b.path("testdata/mdb2sql_test.mdb"), "mdb2sql_test.mdb");
    for (mdbtools_files) |f| _ = dll_dir.addCopyFile(mdbtools_dir.path(b, f), b.fmt("mdbtools/{s}", .{f}));
    run_tests.has_side_effects = true; // le variaveis de ambiente do teste real (MDB2SQL_TEST_*)
    const pack_tests = b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/pack.zig"), .target = target, .optimize = optimize }) }));
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&pack_tests.step);
}
