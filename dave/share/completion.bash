# bash completion for dave. dave itself says what can come next
# (`dave complete`), so this stays in step with its commands and options.

_dave() {
    local cur=${COMP_WORDS[COMP_CWORD]} line
    local dave=dave
    [[ ${COMP_WORDS[0]} == */* ]] && dave=${COMP_WORDS[0]}
    COMPREPLY=()
    while IFS= read -r line; do
        case $line in
            :files)
                compopt -o filenames 2>/dev/null
                mapfile -t -O "${#COMPREPLY[@]}" COMPREPLY < <(compgen -f -- "$cur")
                ;;
            :dirs)
                compopt -o filenames 2>/dev/null
                mapfile -t -O "${#COMPREPLY[@]}" COMPREPLY < <(compgen -d -- "$cur")
                ;;
            ?*) COMPREPLY+=("${line%%$'\t'*}") ;;
        esac
    done < <("$dave" complete "$COMP_CWORD" "${COMP_WORDS[@]}" 2>/dev/null)
}
complete -F _dave dave
