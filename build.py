"""Build mod_bb_coop: syntax-check scripts, then zip into the game's data folder.

Usage: python build.py [--no-install]
"""
import pathlib
import subprocess
import sys
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent
MOD = ROOT / "mod_bb_coop"
SQ = ROOT / "tools/BBbuilder-main/BBBuilder.Core/tools/sq_taro.exe"
GAME_DATA = pathlib.Path("D:/SteamLibrary/steamapps/common/Battle Brothers/data")
OUT = ROOT / "dist/mod_bb_coop.zip"


def check_squirrel(files):
    result = subprocess.run([str(SQ), *map(str, files)], capture_output=True, text=True)
    errors = [l for l in (result.stdout + result.stderr).splitlines() if "error" in l.lower()]
    if result.returncode == -2 or result.returncode == 4294967294 or errors:
        print("\n".join(errors) or result.stdout + result.stderr)
        return False
    return True


def check_js(files):
    ok = True
    for f in files:
        r = subprocess.run(["node", "--check", str(f)], capture_output=True, text=True)
        if r.returncode != 0:
            print(r.stderr)
            ok = False
    return ok


def main():
    nut = sorted(MOD.rglob("*.nut"))
    js = sorted(MOD.rglob("*.js"))
    print(f"Checking {len(nut)} .nut and {len(js)} .js files")
    if not (check_squirrel(nut) & check_js(js)):
        sys.exit("Build failed")

    OUT.parent.mkdir(exist_ok=True)
    with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED) as z:
        for f in sorted(MOD.rglob("*")):
            if f.is_file():
                z.write(f, f.relative_to(MOD).as_posix())
    print(f"Built {OUT}")

    if "--no-install" not in sys.argv:
        target = GAME_DATA / OUT.name
        target.write_bytes(OUT.read_bytes())
        print(f"Installed {target}")


if __name__ == "__main__":
    main()
