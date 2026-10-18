#!/bin/bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
transport_venv="${BUNGBUNGI_AUDIO_VENV:-$repo_dir/.local/audio-transport-venv}"
transport_python="${BUNGBUNGI_AUDIO_PYTHON:-python3}"
transport_dist="$repo_dir/.local/audio-transport-dist"
transport_build="$repo_dir/.local/audio-transport-build"

if [[ ! -x "$transport_venv/bin/python" ]]; then
    "$transport_python" -m venv "$transport_venv"
fi

"$transport_venv/bin/python" -m pip install --disable-pip-version-check -r "$repo_dir/scripts/audio-transport-requirements.txt"
mkdir -p "$transport_dist" "$transport_build"
"$transport_venv/bin/python" -m PyInstaller \
    --noconfirm --clean --onedir --name BungBungiAudio \
    --distpath "$transport_dist" --workpath "$transport_build/work" --specpath "$transport_build" \
    --collect-all aiortc --collect-all av \
    --hidden-import aioice --hidden-import pylibsrtp \
    "$repo_dir/scripts/codex_audio_transport.py"

"$transport_venv/bin/python" - "$transport_dist/BungBungiAudio" <<'PY'
import importlib.metadata as metadata
from pathlib import Path
import shutil
import sys
import sysconfig
from packaging.requirements import Requirement

destination = Path(sys.argv[1])
licenses = destination / "Licenses"
licenses.mkdir(exist_ok=True)
visited = set()
notices = []

def collect(name, dependencies=True):
    distribution = metadata.distribution(name)
    key = distribution.metadata["Name"].lower().replace("_", "-")
    if key in visited:
        return
    visited.add(key)
    target = licenses / (key + "-" + distribution.version)
    target.mkdir(exist_ok=True)
    for item in distribution.files or []:
        if "license" in item.name.lower() or "copying" in item.name.lower() or item.name == "AUTHORS":
            source = distribution.locate_file(item)
            if source.is_file():
                shutil.copy2(source, target / item.name)
    notices.append(distribution.metadata["Name"] + " " + distribution.version)
    if dependencies:
        for value in distribution.requires or []:
            requirement = Requirement(value)
            if requirement.marker is None or requirement.marker.evaluate():
                collect(requirement.name)

collect("aiortc")
collect("pyinstaller", dependencies=False)  # Includes the bootloader exception.
python_license = Path(sysconfig.get_path("stdlib")) / "LICENSE.txt"
if not python_license.is_file():
    raise SystemExit("Python runtime license was not found")
shutil.copy2(python_license, licenses / "Python-LICENSE.txt")
notices.append("Python " + sys.version.split()[0])
(destination / "THIRD_PARTY_NOTICES.txt").write_text(
    "Bundled runtime components. License texts are in the Licenses directory.\n\n"
    + "\n".join(sorted(notices)) + "\n", encoding="utf-8")
PY

printf '%s\n' "$transport_dist/BungBungiAudio/BungBungiAudio"
