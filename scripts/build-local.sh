#!/bin/bash
set -euo pipefail

# Local build using only Apple's Command Line Tools; Debug stays the default.
configuration="${1:-Debug}"
if [[ $# -gt 1 || ( "$configuration" != Debug && "$configuration" != Release ) ]]; then
    printf 'Usage: %s [Debug|Release]\n' "$0" >&2
    exit 2
fi
if [[ "$configuration" == Release ]]; then
    swift_flags=(-O -whole-module-optimization -g)
else
    swift_flags=(-D DEBUG -g -Onone)
fi
# Select a persistent identity explicitly when available. Never silently fall
# back to ad-hoc signing if the requested identity fails.
signing_identity="${MACMIC_SIGN_IDENTITY:--}"
project_root="$(cd "$(dirname "$0")/.." && pwd)"
config_file="$project_root/Config/App.xcconfig"
config_value() {
    awk -F ' = ' -v key="$1" '$1 == key { print $2; exit }' "$config_file"
}

product_name="$(config_value PRODUCT_NAME)"
bundle_id="$(config_value PRODUCT_BUNDLE_IDENTIFIER)"
deployment_target="$(config_value MACOSX_DEPLOYMENT_TARGET)"
architecture="$(config_value ARCHS)"
build_dir="$project_root/.local/build/$configuration"
final_app="$build_dir/$product_name.app"
mkdir -p "$build_dir"
staging_dir="$(mktemp -d "$build_dir/.build.XXXXXX")"
app_path="$staging_dir/$product_name.app"
cleanup() {
    # If promotion failed after moving the old app, restore that known-good build.
    if [[ ! -e "$final_app" && -d "$staging_dir/previous.app" ]]; then
        mv "$staging_dir/previous.app" "$final_app"
    fi
    rm -rf "$staging_dir"
}
trap cleanup EXIT
# Keep compiler side products inside the local staging directory.
cd "$staging_dir"
sdk_path="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p "$app_path/Contents/MacOS" "$project_root/.local/build/ModuleCache"
compiler_output="$app_path/Contents/MacOS/$product_name"
if [[ "$configuration" == Release ]]; then
    # Keep the object until dsymutil has copied its debug information.
    swift_flags+=(-emit-object)
    compiler_output="$staging_dir/$product_name.o"
fi

xcrun --sdk macosx swiftc \
    -parse-as-library \
    -swift-version 6 \
    -strict-concurrency=complete \
    -target "$architecture-apple-macos$deployment_target" \
    -sdk "$sdk_path" \
    -module-cache-path "$project_root/.local/build/ModuleCache" \
    -module-name "$product_name" \
    "${swift_flags[@]}" \
    "$project_root"/MacMicApp/*.swift \
    -o "$compiler_output"
if [[ "$configuration" == Release ]]; then
    xcrun --sdk macosx swiftc -target "$architecture-apple-macos$deployment_target" \
        -sdk "$sdk_path" -g "$compiler_output" -o "$app_path/Contents/MacOS/$product_name"
fi
cp "$project_root/Config/Info.plist" "$app_path/Contents/Info.plist"
plist="$app_path/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $product_name" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName $product_name" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_id" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(config_value MARKETING_VERSION)" "$plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(config_value CURRENT_PROJECT_VERSION)" "$plist"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $deployment_target" "$plist"

icon_resources="$project_root/Resources/CompiledIcon"
if [[ -d "$icon_resources" ]]; then
    python3 "$project_root/scripts/icon-cloud/icon-resources.py" install \
        "$project_root/MacMicApp/AppIcon.icon" "$icon_resources" "$app_path"
else
    printf 'Native icon not installed: import the GitHub Actions artifact into Resources/CompiledIcon.\n'
fi

codesign --force --sign "$signing_identity" --options runtime \
    --entitlements "$project_root/Config/MacMicApp.entitlements" "$app_path"
codesign --verify --strict --verbose=2 "$app_path"
if [[ "$configuration" == Release ]]; then
    xcrun dsymutil "$app_path/Contents/MacOS/$product_name" -o "$staging_dir/$product_name.app.dSYM"
fi
# Publish only after compilation, resources and signature verification succeed.
if [[ -e "$final_app" ]]; then mv "$final_app" "$staging_dir/previous.app"; fi
mv "$app_path" "$final_app"
if [[ "$configuration" == Release ]]; then
    rm -rf "$build_dir/$product_name.app.dSYM"
    mv "$staging_dir/$product_name.app.dSYM" "$build_dir/$product_name.app.dSYM"
fi
printf 'Built (%s): %s\n' "$configuration" "$final_app"
if [[ "$signing_identity" == - ]]; then
    printf 'Signing: ad-hoc. Camera permission may need renewal after a changed build.\n'
fi
