file="${args[--file]}"

if [[ $file == *"@"* ]]
then
  file=$(echo "$file" | cut -d "@" -f 2)
fi

filename=$(basename $file)

avro_tools_platform_flag=""
avro_tools_jvm_env_flag=""
if [ "$(uname -m)" = "s390x" ]
then
  # vdesabou/avro-tools has no s390x manifest, run it emulated via QEMU
  avro_tools_platform_flag="--platform linux/amd64"
  # QEMU crashes ("uncaught target signal 11") on JIT-generated AVX/SSE
  # instructions; force the JVM into interpreted mode to avoid it (see
  # connect/CERTIFYING_S390X.md diagnostic table)
  avro_tools_jvm_env_flag="-e JAVA_TOOL_OPTIONS=-Xint"
fi

log "🔖 ${filename}.avro metadata"
docker run --quiet --rm $avro_tools_platform_flag $avro_tools_jvm_env_flag -v ${file}:/tmp/${filename} vdesabou/avro-tools getmeta /tmp/${filename}

log "🔖 ${filename}.avro schema"
docker run --quiet --rm $avro_tools_platform_flag $avro_tools_jvm_env_flag -v ${file}:/tmp/${filename} vdesabou/avro-tools getschema /tmp/${filename}

log "🔖 ${filename}.avro content"
docker run --quiet --rm $avro_tools_platform_flag $avro_tools_jvm_env_flag -v ${file}:/tmp/${filename} vdesabou/avro-tools tojson /tmp/${filename}
