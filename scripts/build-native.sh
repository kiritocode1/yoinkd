#!/usr/bin/env bash
set -euo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
native_cache="${IYOINKS_NATIVE_CACHE:-.cache/native-dependencies}"
python3 scripts/prepare-native.py --cache "$native_cache"
mkdir -p build
python3 scripts/check-project.py > build/project-check.json
xtool dev build --configuration release --ipa
python3 scripts/package-python.py --ipa xtool/iYoinks.ipa
doc-python scripts/package-icons.py --ipa xtool/iYoinks.ipa
python3 scripts/check-ipa.py xtool/iYoinks.ipa --output build/release-check.json
