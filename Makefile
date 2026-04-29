# Calypso — orchestration
#
# Targets:
#   bootstrap    build everything (workspace build + frontend bundle)
#   build        spago build at workspace root
#   bundle       bundle the frontend to public/bundle.js
#   start        start backend (3060) and frontend (3061) in the background
#   stop         kill services running on the configured ports
#   status       show port occupancy
#   clean        remove build artefacts

BACKEND_PORT  ?= 3060
FRONTEND_PORT ?= 3061

.PHONY: help bootstrap build bundle start stop status clean

help:
	@echo "Calypso"
	@echo ""
	@echo "  make bootstrap     Build workspace + bundle frontend"
	@echo "  make build         spago build (workspace)"
	@echo "  make bundle        Bundle frontend to public/bundle.js"
	@echo "  make start         Run backend + frontend"
	@echo "  make stop          Stop both"
	@echo "  make status        Show port occupancy"
	@echo "  make clean         Remove build artefacts"
	@echo ""
	@echo "  Ports: backend=$(BACKEND_PORT) frontend=$(FRONTEND_PORT)"

bootstrap: build bundle
	@echo "Bootstrap complete."

build:
	spago build -p calypso-shared
	spago build -p calypso-server
	spago build -p calypso-frontend

bundle:
	spago bundle -p calypso-frontend

start: bootstrap
	@echo "Starting backend on :$(BACKEND_PORT) and frontend on :$(FRONTEND_PORT)"
	@BACKEND_PORT=$(BACKEND_PORT) node server/run.js > /tmp/calypso-backend.log 2>&1 &
	@npx http-server frontend/public -p $(FRONTEND_PORT) -c-1 --cors > /tmp/calypso-frontend.log 2>&1 &
	@sleep 1
	@echo "Backend log:  /tmp/calypso-backend.log"
	@echo "Frontend log: /tmp/calypso-frontend.log"
	@echo "Open http://localhost:$(FRONTEND_PORT)"

stop:
	-@lsof -ti :$(BACKEND_PORT)  | xargs -r kill 2>/dev/null || true
	-@lsof -ti :$(FRONTEND_PORT) | xargs -r kill 2>/dev/null || true
	@echo "Stopped."

status:
	@echo "backend  ($(BACKEND_PORT)):      $$(lsof -ti :$(BACKEND_PORT)  2>/dev/null || echo '(not running)')"
	@echo "frontend ($(FRONTEND_PORT)):      $$(lsof -ti :$(FRONTEND_PORT) 2>/dev/null || echo '(not running)')"

clean:
	rm -rf output .spago frontend/public/bundle.js
