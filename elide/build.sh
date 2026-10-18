#!/usr/bin/env bash
# Builds KSP2 for Elide: the Analysis API relocated onto kotlin-compiler-embeddable's namespaces, and
# KSP compiled against it, so KSP shares the compiler classes Elide already embeds.
#
#   elide/build.sh            build into elide/out/repo/ksp-elide/$VERSION (Maven layout)
#   elide/build.sh publish    also upload that version to maven.elide.dev (asks first)
#
# Elide drives KSP through its API, so the command-line mains (`ksp/cmdline`) and the module's
# `src/main/java` IntelliJ overrides (unrelocated `com.intellij` classes) are not built.
#
# Needs `elide` (or $ELIDE), a JDK 21+ ($JAVA_HOME or PATH), curl, unzip, and rclone for publish.
set -euo pipefail

KOTLIN=2.5.0-Beta1
VERSION=${VERSION:-$KOTLIN-elide.1}
COROUTINES=1.8.0
CAFFEINE=3.3.0
ANNOTATIONS=26.1.0
SERIALIZATION=1.11.0
ASM=9.9

ELIDE=${ELIDE:-elide}
JAVA=${JAVA_HOME:+$JAVA_HOME/bin/}java
JAVAC=${JAVA_HOME:+$JAVA_HOME/bin/}javac
JAR=${JAVA_HOME:+$JAVA_HOME/bin/}jar

ROOT=$(cd "$(dirname "$0")/.." && pwd)
OUT=$ROOT/elide/out
DEPS=$OUT/deps
BUILD=$OUT/build
REPO=$OUT/repo/ksp-elide/$VERSION
CENTRAL=https://repo1.maven.org/maven2
INTELLIJ=https://packages.jetbrains.team/maven/p/ij/intellij-dependencies

AA_ARTIFACTS=(
  analysis-api-for-ide analysis-api-impl-base-for-ide analysis-api-k2-for-ide
  analysis-api-platform-interface-for-ide analysis-api-standalone-for-ide low-level-api-fir-for-ide
  symbol-light-classes-for-ide
)
OPT_INS=org.jetbrains.kotlin.analysis.api.KaImplementationDetail,org.jetbrains.kotlin.analysis.api.KaExperimentalApi,org.jetbrains.kotlin.analysis.api.KaPlatformInterface,org.jetbrains.kotlin.analysis.api.KaNonPublicApi,org.jetbrains.kotlin.analysis.api.KaIdeApi

die() { echo "error: $*" >&2; exit 1; }

# fetch <repo> <group/path> <artifact> <version>: download a jar, checked against the repository's sha1.
fetch() {
  local repo=$1 group=$2 artifact=$3 version=$4
  local dest=$DEPS/$artifact-$version.jar url=$repo/$group/$artifact/$version/$artifact-$version.jar
  if [ ! -f "$dest" ]; then
    curl -fsSL -o "$dest.tmp" "$url" || die "download failed: $url"
    [ "$(curl -fsSL "$url.sha1" | cut -c1-40)" = "$(sha1sum "$dest.tmp" | cut -d' ' -f1)" ] || die "checksum mismatch: $url"
    mv "$dest.tmp" "$dest"
  fi
  echo "$dest"
}

# pom <artifact> <group>: a dependency-free POM; Elide declares each jar it needs.
pom() {
  cat <<POM
<?xml version="1.0" encoding="UTF-8"?>
<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>$2</groupId>
  <artifactId>$1</artifactId>
  <version>$VERSION</version>
  <description>Elide build of KSP2 against Kotlin $KOTLIN (github.com/elide-tools/ksp)</description>
  <licenses><license><name>Apache-2.0</name></license></licenses>
</project>
POM
}

# install <jar> <group> <artifact>: add a jar and its POM to the local repository, with checksums.
install() {
  local jar=$1 group=$2 artifact=$3
  local dir=$REPO/${group//.//}/$artifact/$VERSION
  mkdir -p "$dir"
  cp "$jar" "$dir/$artifact-$VERSION.jar"
  pom "$artifact" "$group" > "$dir/$artifact-$VERSION.pom"
  for f in "$dir/$artifact-$VERSION.jar" "$dir/$artifact-$VERSION.pom"; do
    sha1sum "$f" | cut -d' ' -f1 > "$f.sha1"
    sha256sum "$f" | cut -d' ' -f1 > "$f.sha256"
  done
}

kotlinc() { "$ELIDE" kotlinc -- -Xskip-prerelease-check "$@"; }

build() {
  rm -rf "$BUILD" "$REPO"
  mkdir -p "$DEPS" "$BUILD" "$REPO"

  local emb stdlib reflect coroutines caffeine annotations serialization serialization_json asm asm_commons common_ide aa=()
  emb=$(fetch $CENTRAL org/jetbrains/kotlin kotlin-compiler-embeddable $KOTLIN)
  stdlib=$(fetch $CENTRAL org/jetbrains/kotlin kotlin-stdlib $KOTLIN)
  reflect=$(fetch $CENTRAL org/jetbrains/kotlin kotlin-reflect $KOTLIN)
  coroutines=$(fetch $CENTRAL org/jetbrains/kotlinx kotlinx-coroutines-core-jvm $COROUTINES)
  caffeine=$(fetch $CENTRAL com/github/ben-manes/caffeine caffeine $CAFFEINE)
  annotations=$(fetch $CENTRAL org/jetbrains annotations $ANNOTATIONS)
  serialization=$(fetch $CENTRAL org/jetbrains/kotlinx kotlinx-serialization-core-jvm $SERIALIZATION)
  serialization_json=$(fetch $CENTRAL org/jetbrains/kotlinx kotlinx-serialization-json-jvm $SERIALIZATION)
  asm=$(fetch $CENTRAL org/ow2/asm asm $ASM)
  asm_commons=$(fetch $CENTRAL org/ow2/asm asm-commons $ASM)
  common_ide=$(fetch $INTELLIJ org/jetbrains/kotlin kotlin-compiler-common-for-ide $KOTLIN)
  for a in "${AA_ARTIFACTS[@]}"; do aa+=("$(fetch $INTELLIJ org/jetbrains/kotlin "$a" $KOTLIN)"); done

  # The decompiler and its internals ship in kotlin-compiler-common-for-ide but not in embeddable.
  local extracted=$BUILD/extracted
  mkdir -p "$extracted"
  unzip -Z1 "$common_ide" | grep -E '^org/jetbrains/kotlin/analysis/(decompiler|internal)/.*\.class$' \
    | grep -vxF -f <(unzip -Z1 "$emb") > "$BUILD/extracted.txt" || true
  [ -s "$BUILD/extracted.txt" ] || die "no decompiler classes found in $common_ide"
  (cd "$extracted" && xargs -a "$BUILD/extracted.txt" unzip -q -o "$common_ide")
  "$JAR" --create --date=2010-01-01T00:00:00Z --file "$BUILD/extracted.jar" -C "$extracted" .

  # Interfaces the Analysis API references that embeddable leaves out.
  "$JAVAC" -d "$BUILD/shim" $(find "$ROOT/elide/shim" -name '*.java')
  "$JAR" --create --date=2010-01-01T00:00:00Z --file "$BUILD/shim.jar" -C "$BUILD/shim" .

  "$JAVAC" -d "$BUILD/relocate" -cp "$asm:$asm_commons" "$ROOT/elide/Relocate.java"
  "$JAVA" -cp "$BUILD/relocate:$asm:$asm_commons" Relocate "$BUILD/analysis-api.jar" \
    "${aa[@]}" "$BUILD/extracted.jar" "$BUILD/shim.jar"

  local libs="$emb:$stdlib:$reflect:$coroutines:$caffeine:$annotations:$serialization:$serialization_json"
  kotlinc -d "$BUILD/api.jar" -module-name symbol-processing-api -cp "$stdlib" "$ROOT/api/src/main/kotlin"
  kotlinc -d "$BUILD/common.jar" -module-name symbol-processing-common-deps -cp "$BUILD/api.jar:$libs" \
    "$ROOT/common-util/src/main/kotlin" "$ROOT/common-deps/src/main/kotlin"
  kotlinc -d "$BUILD/aa.jar" -module-name symbol-processing-aa -opt-in="$OPT_INS" \
    -cp "$BUILD/api.jar:$BUILD/common.jar:$BUILD/analysis-api.jar:$libs" \
    $(find "$ROOT/kotlin-analysis-api/src/main/kotlin" -name '*.kt' -not -path '*/ksp/cmdline/*' | sort)

  install "$BUILD/api.jar" com.google.devtools.ksp symbol-processing-api
  install "$BUILD/common.jar" com.google.devtools.ksp symbol-processing-common-deps
  install "$BUILD/aa.jar" com.google.devtools.ksp symbol-processing-aa
  install "$BUILD/analysis-api.jar" dev.elide.ksp kotlin-analysis-api-embeddable
  echo "built: $REPO"
}

publish() {
  local dest="elide:elide-maven/ksp-elide/$VERSION"
  if rclone lsf "$dest" 2>/dev/null | grep -q .; then die "$dest already exists; versions are immutable, pick a new one"; fi
  read -r -p "Upload $REPO ($(du -sh "$REPO" | cut -f1)) to $dest? [y/N] " answer
  [ "$answer" = y ] || die "aborted"
  rclone copy "$REPO" "$dest/" --transfers 16 --checksum
  rclone check "$REPO" "$dest/" --one-way
  echo "published: https://maven.elide.dev/ksp-elide/$VERSION"
}

build
[ "${1:-}" = publish ] && publish
exit 0
