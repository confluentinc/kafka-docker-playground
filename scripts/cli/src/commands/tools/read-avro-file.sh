file="${args[--file]}"

if [[ $file == *"@"* ]]
then
  file=$(echo "$file" | cut -d "@" -f 2)
fi

filename=$(basename $file)

avro_tools_flags=$(avro_tools_run_flags)

log "🔖 ${filename}.avro metadata"
docker run --quiet --rm $avro_tools_flags -v ${file}:/tmp/${filename} vdesabou/avro-tools getmeta /tmp/${filename}

log "🔖 ${filename}.avro schema"
docker run --quiet --rm $avro_tools_flags -v ${file}:/tmp/${filename} vdesabou/avro-tools getschema /tmp/${filename}

log "🔖 ${filename}.avro content"
docker run --quiet --rm $avro_tools_flags -v ${file}:/tmp/${filename} vdesabou/avro-tools tojson /tmp/${filename}
