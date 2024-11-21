#!/bin/bash

# Set the Docker image to use for running BATS
DOCKER_IMAGE="bats/bats:latest"

# Get the path of the project root directory
PROJECT_ROOT=$PWD
# or depends on execution path
# PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Run BATS tests in Docker
docker run -it -v "$PROJECT_ROOT:/code" $DOCKER_IMAGE /code/test

# Check if the tests passed
if [ $? -eq 0 ]; then
  echo "All tests passed successfully!"
  exit 0
else
  echo "Some tests failed. Please check the output above for details."
  exit 1
fi
