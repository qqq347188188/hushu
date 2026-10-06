#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
把 Hoshu 的 layout/ 目录打包成合规的 Debian (.deb) 包。
纯 Python 标准库实现，Windows / macOS / Linux 均可运行，无需 Theos / dpkg。

用法：
    python build_deb.py [layout_dir] [output_dir]

默认：
    layout_dir = ./Hoshu-main/layout
    output_dir = .

输出文件名取自 layout/DEBIAN/control 的 Package_Version_Architecture.deb。

重要说明：
    .deb 真正可用必须包含编译好的 Hoshu.app。请先在 macOS + Xcode 用
    Theos 或 xcodebuild 编译出 Hoshu.app，放到 layout/Applications/Hoshu.app，
    再运行本脚本重新打包。当前若 layout 下除 DEBIAN 外没有任何文件，
    生成的 .deb 的 data.tar 为空（合法骨架包），装上不会有应用图标。
"""

import os
import io
import sys
import time
import tarfile
import hashlib


def read_control(layout):
    """解析 DEBIAN/control，返回字段字典。"""
    p = os.path.join(layout, "DEBIAN", "control")
    fields = {}
    with open(p, "r", encoding="utf-8") as f:
        for line in f:
            if line.strip() == "" or line.startswith(" "):
                continue
            if ":" in line:
                k, v = line.split(":", 1)
                fields[k.strip()] = v.strip()
    return fields


def iter_layout_entries(layout):
    """遍历 layout 下除 DEBIAN 外的所有条目，yield (abspath, arcname)。"""
    for root, dirs, files in os.walk(layout):
        rel_root = os.path.relpath(root, layout)
        if rel_root == "DEBIAN":
            continue
        # 在根层直接剔除 DEBIAN，既不进入也不把它作为目录条目写入 data.tar
        if rel_root == ".":
            dirs[:] = [d for d in dirs if d != "DEBIAN"]
        for name in files:
            abspath = os.path.join(root, name)
            arcname = os.path.relpath(abspath, layout).replace(os.sep, "/")
            yield abspath, arcname
        for d in dirs:
            abspath = os.path.join(root, d)
            arcname = os.path.relpath(abspath, layout).replace(os.sep, "/") + "/"
            yield abspath, arcname


def build_data_tar(layout):
    """构建 data.tar.gz，保留权限/属主/符号链接；返回 (bytes, md5sums)。"""
    buf = io.BytesIO()
    md5s = []
    with tarfile.open(fileobj=buf, mode="w:gz") as t:
        for abspath, arcname in iter_layout_entries(layout):
            ti = t.gettarinfo(name=abspath, arcname=arcname)
            ti.uid = ti.gid = 0
            ti.uname = ti.gname = "root"
            if ti.isreg():
                with open(abspath, "rb") as f:
                    data = f.read()
                t.addfile(ti, io.BytesIO(data))
                md5s.append((hashlib.md5(data).hexdigest(), "./" + arcname))
            else:
                t.addfile(ti)
    return buf.getvalue(), md5s


def build_control_tar(layout, md5s):
    """构建 control.tar.gz，含 control 与可选的 md5sums（权限 0644，属主 root）。"""
    buf = io.BytesIO()
    with tarfile.open(fileobj=buf, mode="w:gz") as t:
        with open(os.path.join(layout, "DEBIAN", "control"), "rb") as f:
            cd = f.read()
        ci = tarfile.TarInfo("control")
        ci.size = len(cd)
        ci.mode = 0o644
        ci.uid = ci.gid = 0
        ci.uname = ci.gname = "root"
        ci.mtime = int(time.time())
        t.addfile(ci, io.BytesIO(cd))

        if md5s:
            ms = "".join(f"{m}  {p}\n" for m, p in md5s).encode("utf-8")
            mi = tarfile.TarInfo("md5sums")
            mi.size = len(ms)
            mi.mode = 0o644
            mi.uid = mi.gid = 0
            mi.uname = mi.gname = "root"
            mi.mtime = int(time.time())
            t.addfile(mi, io.BytesIO(ms))
    return buf.getvalue()


def build_ar(members):
    """把 (name, data) 列表打包成 ar 归档（deb 容器）。"""
    out = bytearray(b"!<arch>\n")
    for name, data in members:
        size = len(data)
        nm = name.encode("utf-8")
        if len(nm) > 16:
            raise ValueError(f"ar 成员名过长: {name}")
        name_field = nm + (b" " * (16 - len(nm)))
        mode = 0o100644  # 普通文件
        header = (
            name_field
            + f"{int(time.time()):<12}".encode("ascii")   # mtime 12
            + b"0     "                                    # uid 6
            + b"0     "                                    # gid 6
            + f"{mode:<8o}".encode("ascii")                # mode 8 (八进制)
            + f"{size:<10}".encode("ascii")                # size 10
            + b"`\n"                                       # 结尾 ` + 换行
        )
        out += header + data
        if size & 1:
            out += b"\n"
    return bytes(out)


def main():
    layout = sys.argv[1] if len(sys.argv) > 1 else os.path.join("Hoshu-main", "layout")
    outdir = sys.argv[2] if len(sys.argv) > 2 else "."
    layout = os.path.abspath(layout)
    if not os.path.isdir(os.path.join(layout, "DEBIAN")):
        print("错误：找不到 layout/DEBIAN 目录，请检查路径。")
        sys.exit(1)

    fields = read_control(layout)
    pkg = fields.get("Package", "package")
    ver = fields.get("Version", "1.0.0")
    arch = fields.get("Architecture", "iphoneos-arm")
    out_name = f"{pkg}_{ver}_{arch}.deb"

    data_tar, md5s = build_data_tar(layout)
    control_tar = build_control_tar(layout, md5s)
    debian_binary = b"2.0\n"

    deb = build_ar([
        ("debian-binary", debian_binary),
        ("control.tar.gz", control_tar),
        ("data.tar.gz", data_tar),
    ])

    os.makedirs(outdir, exist_ok=True)
    out_path = os.path.join(outdir, out_name)
    with open(out_path, "wb") as f:
        f.write(deb)

    print(f"已生成: {out_path}")
    print(f"  大小: {len(deb)} 字节")
    print(f"  data 文件数: {len(md5s)}")
    if len(md5s) == 0:
        print("  [警告] data.tar 为空：layout 下还没有编译好的 Hoshu.app。")
        print("     请在 macOS + Xcode 编译出 Hoshu.app 并放到")
        print("     layout/Applications/Hoshu.app 后，重跑本脚本即可得完整包。")


if __name__ == "__main__":
    main()
