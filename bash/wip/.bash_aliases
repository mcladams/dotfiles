find_index () 
{ 
    local -n array_ref=$1;
    local search_val=$2;
    for i in "${!array_ref[@]}";
    do
        if [[ "${array_ref[$i]}" == "$search_val" ]]; then
            echo "$i";
            return 0;
        fi;
    done;
    return 1
}
