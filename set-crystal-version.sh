#!/bin/bash
set -e

version=$1

if [[ ! $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
then
  echo "Use: $0 <semver>"
  exit 1
fi

files=(
  Dockerfile
  Dockerfile.rpm
  deb.Dockerfile
  tar.Dockerfile
  spec/Dockerfile
  .github/workflows/ci.yml
  .github/workflows/packages.yml
  .github/workflows/rpm.yml
)

suffix='pre-'${version}
for file in ${files[@]}
do
  sed -i'.bak' 's/84codes\/crystal:[^-]*/84codes\/crystal:'${version}'/' ${file}
  # sed on BSD systems require a backup extension, so we're deleting the backup afterwards
  rm -f ${file}.bak
done
sed -i'.bak' 's/crystal: .*$/crystal: '${version}'/' shard.yml
rm -f shard.yml.bak
