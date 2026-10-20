.PHONY: help preview preview-docker

# The Capycal repo the book comes from
CAPYCAL ?= $(firstword $(wildcard ../capycal ../calcal))
PORT ?= 8000

help: ## Show the targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-16s %s\n", $$1, $$2}'

preview: ## Serve the site with the book under /docs on http://localhost:8000 (needs python3, curl)
	scripts/preview.sh "$(CAPYCAL)" $(PORT)

preview-docker: ## The same in a container, only needs Docker
	docker run --rm -it -p $(PORT):$(PORT) \
		-v "$(CURDIR)":/site -v "$(abspath $(CAPYCAL))":/capycal:ro \
		python:3.13-alpine sh -c 'apk add --no-cache curl >/dev/null && /site/scripts/preview.sh /capycal $(PORT)'
