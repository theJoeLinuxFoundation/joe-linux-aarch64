#compdef dave
# zsh completion for dave. dave itself says what can come next
# (`dave complete`), so this stays in step with its commands and options.

local line
local -a described plain
for line in "${(@f)$(dave complete $((CURRENT - 1)) "${words[@]}" 2>/dev/null)}"; do
    case $line in
        :files) _files; return ;;
        :dirs) _files -/; return ;;
        '') ;;
        *$'\t'*) described+=("${${line%%$'\t'*}//:/\\:}:${line#*$'\t'}") ;;
        *) plain+=("$line") ;;
    esac
done
(( $#described )) && _describe dave described
(( $#plain )) && compadd -a plain
return 0
