VISION_SERVICE_NODE_VERSION := $(shell command -v poetry >/dev/null 2>&1 && poetry version -s || echo "0.0.0")
VISION_SERVICE_NODE_SSH_HOST ?= bdev-service-node
PYTHON_FILES_WITHOUT_TESTS := vision/servicenode linux/scripts/start-web.py openapi.py
PYTHON_FILES := $(PYTHON_FILES_WITHOUT_TESTS) tests
STACK_BASE_NAME=stack-service-node
INSTANCE_COUNT ?= 1
DEV_MODE ?= false
SHELL := $(shell which bash)
OPENAPI_FILE_LOCATION ?= ./docs/openapi.json

.PHONY: check-version
check-version:
	@if [ -z "$(VERSION)" ]; then \
		echo "Error: VERSION is not set"; \
		exit 1; \
	fi
	@VERSION_FROM_POETRY=$$(poetry version -s) ; \
	if test "$$VERSION_FROM_POETRY" != "$(VERSION)"; then \
		echo "Version mismatch: expected $(VERSION), got $$VERSION_FROM_POETRY" ; \
		exit 1 ; \
	else \
		echo "Version check passed" ; \
	fi

.PHONY: dist
dist: tar wheel debian

.PHONY: code
code: check format lint sort bandit test

.PHONY: check
check:
	poetry run mypy $(PYTHON_FILES_WITHOUT_TESTS)
	poetry run mypy --explicit-package-bases tests

.PHONY: format
format:
	poetry run yapf --in-place --recursive $(PYTHON_FILES)

.PHONY: format-check
format-check:
	poetry run yapf --diff --recursive $(PYTHON_FILES)

.PHONY: lint
lint:
	poetry run flake8 $(PYTHON_FILES)

.PHONY: sort
sort:
	poetry run isort --force-single-line-imports $(PYTHON_FILES)

.PHONY: sort-check
sort-check:
	poetry run isort --force-single-line-imports $(PYTHON_FILES) --check-only

.PHONY: bandit
bandit:
	poetry run bandit -r $(PYTHON_FILES) --quiet --configfile=.bandit

.PHONY: bandit-check
bandit-check:
	poetry run bandit -r $(PYTHON_FILES) --configfile=.bandit

.PHONY: test
test:
	poetry run python3 -m pytest tests --ignore tests/database/postgres

.PHONY: test-postgres
test-postgres:
	poetry run python3 -m pytest tests/database/postgres

.PHONY: coverage
coverage:
	poetry run python3 -m pytest --cov-report term-missing --cov=vision tests --ignore tests/database/postgres

.PHONY: coverage-postgres
coverage-postgres:
	poetry run python3 -m pytest --cov-report term-missing --cov=vision tests/database/postgres

.PHONY: coverage-all
coverage-all:
	poetry run python3 -m pytest --cov-report term-missing --cov=vision tests

.PHONY: openapi-docs
openapi-docs:
	poetry run python3 -m openapi $(OPENAPI_FILE_LOCATION)

.PHONY: tar
tar: dist/vision_service_node-$(VISION_SERVICE_NODE_VERSION).tar.gz

dist/vision_service_node-$(VISION_SERVICE_NODE_VERSION).tar.gz: vision/ service-node-config.yml service-node-config.env bids.yml alembic.ini vision-service-node.sh vision-service-node-worker.sh
	cp service-node-config.yml vision/service-node-config.yml
	cp service-node-config.env vision/service-node-config.env
	cp bids.yml vision/bids.yml
	cp alembic.ini vision/alembic.ini
	cp vision-service-node.sh vision/vision-service-node.sh
	cp vision-service-node-worker.sh vision/vision-service-node-worker.sh
	chmod 755 vision/vision-service-node.sh
	chmod 755 vision/vision-service-node-worker.sh
	poetry build -f sdist
	rm vision/service-node-config.yml
	rm vision/service-node-config.env
	rm vision/bids.yml
	rm vision/alembic.ini
	rm vision/vision-service-node.sh
	rm vision/vision-service-node-worker.sh

check-poetry-plugin:
	@if poetry self show plugins | grep -q poetry-plugin-freeze; then \
		echo "poetry-plugin-freeze is already added."; \
	else \
		echo "poetry-plugin-freeze is not added. Adding now..."; \
		poetry self add poetry-plugin-freeze; \
	fi

freeze-wheel: check-poetry-plugin
	poetry freeze-wheel

.PHONY: wheel
wheel: dist/vision_service_node-$(VISION_SERVICE_NODE_VERSION)-py3-none-any.whl freeze-wheel

dist/vision_service_node-$(VISION_SERVICE_NODE_VERSION)-py3-none-any.whl: vision/ service-node-config.yml service-node-config.env bids.yml alembic.ini
	cp service-node-config.yml vision/service-node-config.yml
	cp service-node-config.env vision/service-node-config.env
	cp bids.yml vision/bids.yml
	cp alembic.ini vision/alembic.ini
	poetry build -f wheel
	rm vision/service-node-config.yml
	rm vision/service-node-config.env
	rm vision/bids.yml
	rm vision/alembic.ini

.PHONY: debian-build-deps
debian-build-deps:
	mk-build-deps --install --tool "apt-get --no-install-recommends -y" debian/control --remove

.PHONY: debian-full
debian-full:
	mkdir -p dist
	sed 's/VERSION_PLACEHOLDER/$(VISION_SERVICE_NODE_VERSION)/' configurator/DEBIAN/control.template > configurator/DEBIAN/control
	dpkg-deb --build configurator dist/vision-service-node-full_$(VISION_SERVICE_NODE_VERSION)_all.deb
	rm configurator/DEBIAN/control

.PHONY: debian
debian:
	$(eval debian_package := vision-service-node_$(VISION_SERVICE_NODE_VERSION)_*.deb)
	@if ! conda --version; then \
		echo "Conda not found. Please install conda."; \
		exit 1; \
	fi; \
	dpkg-buildpackage -uc -us -g
	mkdir -p dist
	ARCHITECTURE=$$(dpkg --print-architecture); \
	mv ../$(debian_package) dist/vision-service-node_$(VISION_SERVICE_NODE_VERSION)_$${ARCHITECTURE}.deb

.PHONY: debian-all
debian-all: debian debian-full

.PHONY: docker-debian-build
docker-debian-build:
	docker buildx build -t vision-service-node-build -f Dockerfile --target build-deb . --load $(ARGS);
	CONTAINER_ID=$$(docker create vision-service-node-build); \
    docker cp $${CONTAINER_ID}:/app/dist/ .; \
    docker rm $${CONTAINER_ID}

.PHONY: signer-key
signer-key:
	@if ! command -v ssh-keygen &> /dev/null; then \
        echo "ssh-keygen not found. Please install OpenSSH."; \
        exit 1; \
    fi; \
	if [ -t 0 ]; then \
        read -p "Enter path for signer key (default: ./signer_key.pem): " SIGNER_KEY_FILE; \
        echo "Enter passphrase for signer key (leave empty for no passphrase):"; \
        read -s SIGNER_KEY; echo; \
    fi; \
	if [ -z "$$SIGNER_KEY_FILE" ]; then \
		SIGNER_KEY_FILE="$$(pwd)/signer_key.pem"; \
	fi; \
	if [ -z "$$SIGNER_KEY" ]; then \
		SIGNER_KEY=""; \
	fi; \
    if ssh-keygen -t ed25519 -m PEM -f "$$SIGNER_KEY_FILE" -N "$$SIGNER_KEY"; then \
        echo "SSH key generated successfully at $$SIGNER_KEY_FILE"; \
    else \
        echo "Failed to generate SSH key"; \
        exit 1; \
    fi

.PHONY: remote-install
remote-install: debian-all
	$(eval deb_file := vision-service-node*_$(VISION_SERVICE_NODE_VERSION)_*.deb)
	scp dist/$(deb_file) $(VISION_SERVICE_NODE_SSH_HOST):
ifdef DEV_VISION_COMMON
	scp -r $(DEV_VISION_COMMON) $(VISION_SERVICE_NODE_SSH_HOST):
	ssh -t $(VISION_SERVICE_NODE_SSH_HOST) "\
		sudo systemctl stop vision-service-node-celery;\
		sudo systemctl stop vision-service-node-server;\
		sudo apt install -y ./$(deb_file);\
		sudo rm -rf /opt/vision/vision-service-node/lib/python3.*/site-packages/vision/common/;\
		sudo cp -r common/ /opt/vision/vision-service-node/lib/python3.*/site-packages/vision/;\
		sudo systemctl start vision-service-node-server;\
		sudo systemctl start vision-service-node-celery;\
		rm -rf common;\
		rm $(deb_file)"
else
	ssh -t $(VISION_SERVICE_NODE_SSH_HOST) "\
		sudo systemctl stop vision-service-node-celery;\
		sudo systemctl stop vision-service-node-server;\
		sudo apt install -y ./$(deb_file);\
		sudo systemctl start vision-service-node-server;\
		sudo systemctl start vision-service-node-celery;\
		rm $(deb_file)"
endif

.PHONY: local-common
local-common:
ifndef DEV_VISION_COMMON
	$(error Please define DEV_VISION_COMMON variable)
endif
	$(eval PYTHON_VERSION := $(shell poetry run python --version | awk '{print $$2}' | cut -d. -f1,2))
	$(eval CURRENT_COMMON := $(shell poetry env list --full-path | grep -v "^\*" | head -1 | awk '{print $$1}')/lib/python$(PYTHON_VERSION)/site-packages/vision/common)
	@if [ -d "$(CURRENT_COMMON)" ]; then \
		rm -rf "$(CURRENT_COMMON)"; \
		ln -s "$(DEV_VISION_COMMON)" "$(CURRENT_COMMON)"; \
	else \
		echo "Directory $(CURRENT_COMMON) does not exist"; \
	fi

.PHONY: install
install: dist/vision_service_node-$(VISION_SERVICE_NODE_VERSION)-py3-none-any.whl
	poetry run python -m pip install dist/vision_service_node-$(VISION_SERVICE_NODE_VERSION)-py3-none-any.whl

.PHONY: uninstall
uninstall:
	poetry run python3 -m pip uninstall -y vision-service-node

.PHONY: clean
clean:
	rm -r -f build/
	rm -r -f dist/
	rm -r -f vision_service_node.egg-info/

check-swarm-init:
	@if [ "$$(docker info --format '{{.Swarm.LocalNodeState}}')" != "active" ]; then \
        echo "Docker is not part of a swarm. Initializing..."; \
        docker swarm init; \
    else \
        echo "Docker is already part of a swarm."; \
    fi

docker-build:
	@if [ "$$NO_BUILD" != "true" ]; then \
		docker buildx bake -f docker-compose.yml --load $(ARGS); \
	fi

.PHONY: docker
docker: check-swarm-init docker-build
	@for i in $$(seq 1 $(INSTANCE_COUNT)); do \
        ( \
        export STACK_NAME="${STACK_BASE_NAME}-${STACK_IDENTIFIER}-$$i"; \
        export INSTANCE=$$i; \
        echo "Deploying stack $$STACK_NAME"; \
        if [ "$(DEV_MODE)" = "true" ]; then \
            echo "Running in development mode"; \
            export ARGS="$(ARGS) --watch"; \
            docker compose -f docker-compose.yml -f docker-compose.override.yml -p $$STACK_NAME $$EXTRA_COMPOSE up $$ARGS & \
            COMPOSE_PID=$$!; \
            trap 'echo "Caught INT, killing background processes..."; kill $$COMPOSE_PID; exit 1' INT; \
        else \
            export ARGS="--detach --wait $(ARGS)"; \
            docker compose -f docker-compose.yml -f docker-compose.override.yml -p $$STACK_NAME $$EXTRA_COMPOSE up $$ARGS; \
        fi; \
        trap 'exit 1' INT; \
        echo "Stack $$STACK_NAME deployed"; \
        if [ "$(DEV_MODE)" = "true" ]; then \
            wait $$COMPOSE_PID; \
        fi; \
        ) & \
    done; \
    trap 'echo "Caught INT, killing all background processes..."; kill 0; exit 1' INT; \
    wait
    # We need to use compose because swarm goes absolutely crazy on MacOS when using cross architecture
    # And can't pull the correct images
    #docker stack deploy -c docker-compose.yml -c docker-compose.override.yml $$STACK_NAME --with-registry-auth --detach=false $(ARGS) & \

.PHONY: docker-remove
docker-remove:
	@STACK_NAME="${STACK_BASE_NAME}"; \
    if [ -n "$(STACK_IDENTIFIER)" ]; then \
        STACK_NAME="$$STACK_NAME-$(STACK_IDENTIFIER)"; \
        echo "Removing the stack with identifier $(STACK_IDENTIFIER)"; \
    else \
        echo "** Removing all stacks **"; \
    fi; \
    for stack in $$(docker stack ls --format "{{.Name}}" | awk "/^$$STACK_NAME/ {print}"); do \
        ( \
        echo "Removing stack $$stack"; \
        docker stack rm $$stack --detach=false; \
        echo "Removing volumes for stack $$stack"; \
        docker volume ls --format "{{.Name}}" | awk '/^$$stack/ {print}' | xargs -r docker volume rm \
        ) & \
    done;  \
    for compose_stack in $$(docker compose ls --filter "name=$$STACK_NAME" --format json | jq -r '.[].Name' | awk "/^$$STACK_NAME/ {print}"); do \
        ( \
        echo "Removing Docker Compose stack $$compose_stack"; \
        docker compose -p $$compose_stack down -v \
        ) & \
    done; \
	wait

.PHONY: docker-logs
docker-logs:
	@for stack in $$(docker stack ls --format "{{.Name}}" | awk '/^${STACK_BASE_NAME}-${STACK_IDENTIFIER}/ {print}'); do \
        echo "Showing logs for stack $$stack"; \
        for service in $$(docker stack services --format "{{.Name}}" $$stack); do \
            echo "Logs for service $$service in stack $$stack"; \
            docker service logs --no-task-ids $$service; \
        done; \
    done

docker-prod: check-swarm-init
	docker compose -f docker-compose.yml -f docker-compose.prod.yml up --force-recreate $(ARGS)

docker-prod-down: check-swarm-init
	docker compose -f docker-compose.yml -f docker-compose.prod.yml down -v $(ARGS)
