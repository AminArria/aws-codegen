#!/bin/bash

for file in /Users/onno.vos/src/github/aws-sdk-go-v2/codegen/sdk-codegen/aws-models/*
do
  string=$(grep -B 1 "\"type\": \"service\"," $file | grep -Eo "com.amazonaws.*")
  part1=${string#com.amazonaws.}
  part1=${part1%%#*}
  part2=${string##*#}
  part2=${part2%%\": {*}  # Remove trailing '": {'
  echo "|> String.replace(~r[^$part1$], \"$part2\")"
done