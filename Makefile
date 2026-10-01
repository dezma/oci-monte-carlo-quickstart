SHELL := /usr/bin/env bash

.PHONY: test fmt validate helm-lint runtime-bundle orm package

test:
	python3 -m pytest -q

fmt:
	terraform -chdir=terraform fmt -recursive

validate:
	terraform -chdir=terraform init -backend=false
	terraform -chdir=terraform validate

helm-lint:
	helm lint helm/monte-carlo

runtime-bundle:
	./provisioning/build-runtime-bundle.sh

orm:
	./provisioning/build-orm.sh

package:
	./provisioning/package.sh
