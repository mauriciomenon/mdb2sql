// Build do MDB2SQL Zig + Dear ImGui (cimgui/GLFW/OpenGL3) + libduckdb (C API)
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // shortcut: only the official Windows x64 libduckdb is pinned in build.zig.zon;
    // add the linux/macos zips as lazy dependencies when those targets are needed
    if (target.result.os.tag != .windows or target.result.cpu.arch != .x86_64)
        @panic("zig_imgui currently builds for x86_64-windows only (pinned Windows x64 libduckdb)");

    // libduckdb pre-compilada: duckdb.h + duckdb.lib (import lib) + duckdb.dll
    const duckdb = b.dependency("libduckdb", .{});
    const duckdb_c = b.addTranslateC(.{
        .root_source_file = duckdb.path("duckdb.h"),
        .target = target,
        .optimize = optimize,
    }).createModule();
    duckdb_c.addLibraryPath(duckdb.path(""));
    duckdb_c.linkSystemLibrary("duckdb", .{});

    // Logica sem UI (db.zig + query.zig): usada pelo exe e pelos testes
    const core = b.createModule(.{
        .root_source_file = b.path("src/db.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "duckdb_c", .module = duckdb_c }},
    });

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
                .{ .name = "cimgui", .module = cimgui_tc.createModule() },
                .{ .name = "zglfw", .module = zglfw.module("root") },
            },
        }),
    });
    exe.root_module.addIncludePath(cimgui.path(""));
    exe.root_module.addCSourceFile(.{ .file = b.path("src/shim.c"), .flags = &.{"-DCIMGUI_NO_EXPORT"} });
    exe.root_module.linkLibrary(imgui_lib);
    exe.root_module.linkLibrary(zglfw.artifact("glfw"));
    exe.root_module.linkSystemLibrary("opengl32", .{});
    b.installArtifact(exe);
    // duckdb.dll vai ao lado do exe (zig-out/bin)
    b.getInstallStep().dependOn(&b.addInstallBinFile(duckdb.path("duckdb.dll"), "duckdb.dll").step);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    run.addPassthruArgs();
    b.step("run", "Run the GUI").dependOn(&run.step);

    // Testes: o exe de teste roda com cwd numa pasta do cache que tem a duckdb.dll
    const tests = b.addTest(.{ .root_module = core });
    const run_tests = b.addRunArtifact(tests);
    const dll_dir = b.addWriteFiles();
    _ = dll_dir.addCopyFile(duckdb.path("duckdb.dll"), "duckdb.dll");
    run_tests.setCwd(dll_dir.getDirectory());
    b.step("test", "Run unit tests").dependOn(&run_tests.step);
}
