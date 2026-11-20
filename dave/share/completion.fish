# fish completion for dave. dave itself says what can come next
# (`dave complete`), so this stays in step with its commands and options.

function __dave_complete
    set -l before (commandline -xpc)
    set -l current (commandline -ct)
    for line in (dave complete (count $before) $before $current 2>/dev/null)
        switch $line
            case :files
                __fish_complete_path $current
            case :dirs
                __fish_complete_directories $current
            case '*'
                echo $line
        end
    end
end

complete -c dave -f -a '(__dave_complete)'
