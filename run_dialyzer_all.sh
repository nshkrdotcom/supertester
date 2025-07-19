#!/bin/bash

# Script to run dialyzer in all Elixir projects
echo "Running dialyzer in all Elixir projects..."

projects=(
    "apex"
    "apex_ui"
    "arsenal"
    "arsenal_plug"
    "cluster_test"
    "sandbox"
)

for project in "${projects[@]}"; do
    echo ""
    echo "========================================"
    echo "Running dialyzer in $project"
    echo "========================================"
    
    if [ -d "../$project" ]; then
        (cd "../$project" && mix deps.get && mix dialyzer) || echo "Failed to run dialyzer in $project"
    else
        echo "Directory ../$project not found"
    fi
done

echo ""
echo "========================================"
echo "Dialyzer check complete for all projects"
echo "========================================"