container="${args[--container]}"
command="${args[--command]}"
root="${args[--root]}"
shell="${args[--shell]}"

if [[ -n "$root" ]]
then
  log "Executing command as root in container $container with $shell"
  docker exec -i --privileged --user root $container $shell -c "$command"
else
  log "Executing command in container $container with $shell"
  docker exec -i $container $shell -c "$command"
fi