#!/bin/bash
# stage-repo.sh OUT: the repository to publish, made in OUT (which must not
# exist yet). build/repo keeps every release built; OUT has the one each
# recipe's package.zon names, indexed and signed with build/keys/joe.key,
# with the public key beside it as joe.pub. A published repository is such a
# directory, served as it is (joelinux.io/aarch64).
set -euo pipefail

top=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$top/bootstrap/lib.sh"

out=${1:?usage: stage-repo.sh OUT}
repo=$top/build/repo
keys=$top/build/keys
dave=$top/dave/zig-out/bin/dave
[[ ! -e $out ]] || { echo "stage-repo.sh: $out exists" >&2; exit 1; }

field() { # field <recipe dir> <name>: a top-level value from package.zon
    sed -n "s/^ *\.$2 = \"\{0,1\}\([^\",]*\)\"\{0,1\},.*/\1/p" "$1/package.zon" | head -n 1
}

mkdir -p "$out"
count=0
for recipe in "$top"/packages/*/; do
    [[ -e $recipe/package.zon ]] || continue
    name=$(field "$recipe" name)
    file=$repo/$name-$(field "$recipe" version)-r$(field "$recipe" release)-$JOE_ARCH.dave
    [[ -e $file ]] || { echo "stage-repo.sh: $(basename "$file") has not been built" >&2; exit 1; }
    cp --reflink=auto "$file" "$out/"
    count=$((count + 1))
done

"$dave" repo index "$out" --key "$keys/joe.key" >/dev/null
install -m 644 "$keys/joe.pub" "$out/joe.pub"
echo "$count packages in $out"
