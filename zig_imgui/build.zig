// Build do MDB2SQL Zig + Dear ImGui (cimgui/GLFW/OpenGL3) + libduckdb (C API)
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // shortcut: only the official Windows x64 libduckdb is pinned in build.zig.zon;
    // add the linux/macos zips as lazy dependencies when those targets are needed
    if (target.result.os.tag != .windows or target.result.cpu.arch != .x86_64)
        @panic("zig_imgui currently builds for x86_64-windows only (pinned Windows x64 libduckdb)");

    // Versao: build.zig.zon e a unica fonte; chega ao codigo (janela Sobre) pelas build options.
    // Numero e data do build: passados pelo scripts\build_w11.ps1; fora dele o Sobre mostra "build dev".
    const console = b.option(bool, "console", "Console subsystem, to see stderr (default: only in Debug)") orelse (optimize == .debug);
    const version = @import("build.zig.zon").version;
    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    options.addOption(bool, "console", console);
    options.addOption([]const u8, "build_number", b.option([]const u8, "build_number", "Build number (git rev-list --count HEAD)") orelse "");
    options.addOption([]const u8, "build_date", b.option([]const u8, "build_date", "Build date (YYYY-MM-DD)") orelse "");
    const mdbtools_version = "1.0.1"; // a mesma de scripts/setup_tools.ps1 (mostrada no Sobre)
    options.addOption([]const u8, "mdbtools_version", mdbtools_version);
    const build_options = options.createModule();

    // Arquivos que vao junto do programa, baixados por scripts\setup_tools.ps1 (sha256 conferido)
    const sqlite_ext = b.path(".tools/duckdb-ext-v2.0.0/sqlite_scanner.duckdb_extension");
    const mdbtools_dir = b.path(".tools/mdbtools-" ++ mdbtools_version);
    const mdbtools_files = [_][]const u8{ "mdb-tables.exe", "mdb-schema.exe", "mdb-export.exe", "COPYING", "COPYING.LIB" };

    // libduckdb pre-compilada: duckdb.h + duckdb.lib (import lib) + duckdb.dll
    const duckdb = b.dependency("libduckdb", .{});
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

    // Logica sem UI (db.zig e o resto de src/ menos main/dialog): usada pelo exe e pelos testes
    const core = b.createModule(.{
        .root_source_file = b.path("src/db.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{ .{ .name = "duckdb_c", .module = duckdb_c }, .{ .name = "build_options", .module = build_options } },
    });
    core.linkSystemLibrary("odbc32", .{});
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

    const exe = b.addExecutable(.{
        .name = "mdb2sql-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "db", .module = core },
                .{ .name = "build_options", .module = build_options },
                .{ .name = "cimgui", .module = cimgui_tc.createModule() },
                .{ .name = "zglfw", .module = zglfw.module("root") },
            },
        }),
    });
    // Sem janela de console ao abrir pelo Explorer; -Dconsole=true para ver o stderr
    exe.subsystem = if (console) .console else .windows;
    exe.root_module.addIncludePath(cimgui.path(""));
    exe.root_module.addCSourceFile(.{ .file = b.path("src/shim.c"), .flags = &.{"-DCIMGUI_NO_EXPORT"} });
    exe.root_module.linkLibrary(imgui_lib);
    exe.root_module.linkLibrary(zglfw.artifact("glfw"));
    exe.root_module.linkSystemLibrary("opengl32", .{});
    // Icone do exe e da janela (mesmo .ico no executavel unico e no instalador)
    const icon_rc: std.Build.Module.RcSourceFile = .{ .file = b.path("assets/mdb2sql.rc"), .include_paths = &.{b.path("assets")} };
    exe.root_module.addWin32ResourceFile(icon_rc);
    b.installArtifact(exe);

    // Pasta do app em zig-out/bin: exe + duckdb.dll + extensao sqlite + mdbtools\ (tudo junto)
    const install = b.getInstallStep();
    install.dependOn(&b.addInstallBinFile(duckdb.path("duckdb.dll"), "duckdb.dll").step);
    install.dependOn(&b.addInstallBinFile(sqlite_ext, "sqlite_scanner.duckdb_extension").step);
    for (mdbtools_files) |f| install.dependOn(&b.addInstallBinFile(mdbtools_dir.path(b, f), b.fmt("mdbtools/{s}", .{f})).step);

    // Executavel unico: a mesma pasta comprimida dentro de um lancador (src/launcher.zig)
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

    const run = b.addRunArtifact(exe);
    run.step.dependOn(install);
    run.addPassthruArgs();
    b.step("run", "Run the GUI").dependOn(&run.step);

    // Testes: o exe de teste roda com cwd numa pasta do cache que tem a duckdb.dll e a extensao sqlite
    const tests = b.addTest(.{ .root_module = core });
    const run_tests = b.addRunArtifact(tests);
    const dll_dir = b.addWriteFiles();
    _ = dll_dir.addCopyFile(duckdb.path("duckdb.dll"), "duckdb.dll");
    _ = dll_dir.addCopyFile(sqlite_ext, "sqlite_scanner.duckdb_extension");
    run_tests.setCwd(dll_dir.getDirectory());
    const pack_tests = b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{ .root_source_file = b.path("src/pack.zig"), .target = target, .optimize = optimize }) }));
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&pack_tests.step);
}
