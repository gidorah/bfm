set shell := ["bash", "-euo", "pipefail", "-c"]

mvn := "./mvnw"

default:
    @just --list

test:
    {{ mvn }} -f app/pom.xml test

build:
    {{ mvn }} -f app/pom.xml clean package

package-all:
    {{ mvn }} clean package
